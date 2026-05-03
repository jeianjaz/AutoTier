"""
AutoTier — Self-Healing Remediation Lambda
===========================================

Triggered by SNS when the CloudWatch alarm `alb-unhealthy-hosts` transitions
to ALARM. The function:

  1. Parses the SNS → CloudWatch alarm JSON payload.
  2. Extracts the TargetGroup ARN from the alarm dimensions.
  3. Calls DescribeTargetHealth to find which instance(s) are "unhealthy".
  4. Terminates each unhealthy instance via the ASG API
     (ShouldDecrementDesiredCapacity=False so the fleet stays at desired).
  5. The ASG launches a replacement; when it passes /health the alarm
     returns to OK.

Idempotency: if the instance was already terminated (ASG's own health check
beat us, or a duplicate SNS delivery), the API call returns gracefully and
we log "already handled".

Environment variables (set by Terraform):
  TARGET_GROUP_ARN  — the ALB target group to query for unhealthy targets.

IAM permissions required (scoped in lambda.tf):
  - elasticloadbalancingv2:DescribeTargetHealth
  - autoscaling:TerminateInstanceInAutoScalingGroup
  - autoscaling:DescribeAutoScalingInstances
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

elbv2 = boto3.client("elbv2")
autoscaling = boto3.client("autoscaling")

TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]


def lambda_handler(event, context):
    """Entry point — invoked by SNS."""
    logger.info("Received event: %s", json.dumps(event, default=str))

    for record in event.get("Records", []):
        sns_message = record.get("Sns", {}).get("Message", "{}")
        alarm = json.loads(sns_message)

        # Only act on ALARM state (ignore OK / INSUFFICIENT_DATA)
        new_state = alarm.get("NewStateValue", "")
        alarm_name = alarm.get("AlarmName", "unknown")

        if new_state != "ALARM":
            logger.info(
                "Alarm '%s' transitioned to %s — no action needed.",
                alarm_name,
                new_state,
            )
            continue

        logger.info(
            "Alarm '%s' is in ALARM state. Querying target health...",
            alarm_name,
        )

        # ── Step 1: find unhealthy targets ──────────────────────────────
        try:
            resp = elbv2.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN)
        except Exception:
            logger.exception("Failed to describe target health.")
            raise

        unhealthy_ids = [
            t["Target"]["Id"]
            for t in resp.get("TargetHealthDescriptions", [])
            if t.get("TargetHealth", {}).get("State") == "unhealthy"
        ]

        if not unhealthy_ids:
            logger.info(
                "No unhealthy targets found in target group. "
                "The ASG or a prior invocation may have already handled this."
            )
            continue

        logger.info("Unhealthy instance(s): %s", unhealthy_ids)

        # ── Step 2: terminate each unhealthy instance via the ASG API ───
        for instance_id in unhealthy_ids:
            terminate_via_asg(instance_id)

    return {"statusCode": 200, "body": "Remediation complete."}


def terminate_via_asg(instance_id: str) -> None:
    """Terminate a single instance through the ASG API.

    Uses TerminateInstanceInAutoScalingGroup instead of ec2:TerminateInstances
    because:
      - It tells the ASG "this was intentional, please replace it".
      - ShouldDecrementDesiredCapacity=False keeps desired count stable.
      - The ASG lifecycle hooks and cooldowns stay in control.
    """
    # First verify the instance actually belongs to an ASG
    try:
        asg_resp = autoscaling.describe_auto_scaling_instances(
            InstanceIds=[instance_id]
        )
        asg_instances = asg_resp.get("AutoScalingInstances", [])

        if not asg_instances:
            logger.warning(
                "Instance %s is not part of any ASG. Skipping termination "
                "(may have already been terminated).",
                instance_id,
            )
            return

        asg_name = asg_instances[0]["AutoScalingGroupName"]
        logger.info(
            "Instance %s belongs to ASG '%s'. Terminating...",
            instance_id,
            asg_name,
        )
    except Exception:
        logger.exception(
            "Failed to describe ASG membership for %s.", instance_id
        )
        raise

    # Terminate — the ASG will immediately launch a replacement
    try:
        autoscaling.terminate_instance_in_auto_scaling_group(
            InstanceId=instance_id,
            ShouldDecrementDesiredCapacity=False,
        )
        logger.info(
            "Successfully requested termination of %s in ASG '%s'. "
            "ASG will launch a replacement.",
            instance_id,
            asg_name,
        )
    except autoscaling.exceptions.ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code == "ValidationError" and "not found" in str(e).lower():
            logger.info(
                "Instance %s already terminated (ValidationError). "
                "No action needed.",
                instance_id,
            )
        else:
            logger.exception("Failed to terminate %s.", instance_id)
            raise
    except Exception:
        logger.exception("Failed to terminate %s.", instance_id)
        raise
