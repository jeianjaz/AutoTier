#!/usr/bin/env python3
"""
AutoTier — Infrastructure Status Dashboard
============================================

One-command health check for the entire stack. Shows:
  - ASG instance states and AZ distribution
  - ALB target group health
  - CloudWatch alarm states
  - ALB public URL

Usage:
  python scripts/status.py --region ap-southeast-1

Real-world value:
  This is the first command an on-call engineer runs during an incident.
  "Is anything broken right now?" — answered in 2 seconds.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

try:
    import boto3
except ImportError:
    print("ERROR: boto3 not installed. Run: pip install -r scripts/requirements.txt")
    sys.exit(1)


def get_terraform_outputs(tf_dir: str) -> dict:
    """Run `terraform output -json` and return parsed dict."""
    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=tf_dir,
            capture_output=True,
            text=True,
            check=True,
        )
        raw = json.loads(result.stdout)
        return {k: v["value"] for k, v in raw.items()}
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        print(f"ERROR: Could not read Terraform outputs: {e}")
        sys.exit(1)


def print_section(title: str):
    """Print a section header."""
    print(f"\n{'─' * 60}")
    print(f"  {title}")
    print(f"{'─' * 60}")


def show_asg_status(asg_client, asg_name: str):
    """Display ASG instance states and AZ distribution."""
    print_section("AUTO SCALING GROUP")

    resp = asg_client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    if not resp["AutoScalingGroups"]:
        print("  ❌ ASG not found")
        return

    asg = resp["AutoScalingGroups"][0]
    print(f"  Name:     {asg['AutoScalingGroupName']}")
    print(f"  Desired:  {asg['DesiredCapacity']}  |  Min: {asg['MinSize']}  |  Max: {asg['MaxSize']}")
    print(f"  Health:   {asg['HealthCheckType']}  |  Grace: {asg['HealthCheckGracePeriod']}s")

    instances = asg.get("Instances", [])
    if not instances:
        print("  ⚠️  No instances in ASG")
        return

    print(f"\n  {'Instance ID':<22} {'State':<14} {'Health':<10} {'AZ'}")
    print(f"  {'─' * 22} {'─' * 14} {'─' * 10} {'─' * 20}")
    for inst in instances:
        health_icon = "✅" if inst["HealthStatus"] == "Healthy" else "❌"
        print(f"  {inst['InstanceId']:<22} {inst['LifecycleState']:<14} {health_icon} {inst['HealthStatus']:<7} {inst['AvailabilityZone']}")


def show_target_health(elbv2_client, tg_arn: str):
    """Display ALB target group health."""
    print_section("ALB TARGET GROUP HEALTH")

    resp = elbv2_client.describe_target_health(TargetGroupArn=tg_arn)
    targets = resp["TargetHealthDescriptions"]

    if not targets:
        print("  ⚠️  No targets registered")
        return

    healthy = sum(1 for t in targets if t["TargetHealth"]["State"] == "healthy")
    total = len(targets)
    status = "✅ ALL HEALTHY" if healthy == total else f"⚠️  {healthy}/{total} HEALTHY"
    print(f"  Status: {status}")

    print(f"\n  {'Instance ID':<22} {'State':<12} {'Reason'}")
    print(f"  {'─' * 22} {'─' * 12} {'─' * 30}")
    for t in targets:
        state = t["TargetHealth"]["State"]
        reason = t["TargetHealth"].get("Reason", "—")
        icon = {"healthy": "✅", "unhealthy": "❌", "draining": "⏳", "initial": "🔄"}.get(state, "❓")
        print(f"  {t['Target']['Id']:<22} {icon} {state:<9} {reason}")


def show_alarm_states(cw_client, prefix: str):
    """Display CloudWatch alarm states for AutoTier alarms."""
    print_section("CLOUDWATCH ALARMS")

    resp = cw_client.describe_alarms(AlarmNamePrefix=prefix, MaxRecords=20)
    alarms = resp.get("MetricAlarms", [])

    if not alarms:
        print("  ⚠️  No alarms found with prefix: " + prefix)
        return

    ok_count = sum(1 for a in alarms if a["StateValue"] == "OK")
    alarm_count = sum(1 for a in alarms if a["StateValue"] == "ALARM")
    insuf_count = sum(1 for a in alarms if a["StateValue"] == "INSUFFICIENT_DATA")

    summary = f"  {ok_count} OK"
    if alarm_count:
        summary += f"  |  ❌ {alarm_count} ALARM"
    if insuf_count:
        summary += f"  |  ❓ {insuf_count} INSUFFICIENT_DATA"
    print(summary)

    print(f"\n  {'Alarm':<45} {'State':<20} {'Last Updated'}")
    print(f"  {'─' * 45} {'─' * 20} {'─' * 20}")
    for a in sorted(alarms, key=lambda x: x["AlarmName"]):
        state = a["StateValue"]
        icon = {"OK": "✅", "ALARM": "❌", "INSUFFICIENT_DATA": "❓"}.get(state, "—")
        updated = a["StateUpdatedTimestamp"].strftime("%Y-%m-%d %H:%M")
        short_name = a["AlarmName"].replace("autotier-dev-", "")
        print(f"  {short_name:<45} {icon} {state:<17} {updated}")


def main():
    parser = argparse.ArgumentParser(description="AutoTier infrastructure status dashboard.")
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--tf-dir", default=None)
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tf_dir = args.tf_dir or os.path.join(project_root, "terraform")

    print("=" * 60)
    print("  AutoTier — Infrastructure Status")
    print(f"  {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print("=" * 60)

    outputs = get_terraform_outputs(tf_dir)
    asg_name = outputs.get("asg_name")
    tg_arn = outputs.get("target_group_arn")
    alb_url = outputs.get("alb_url", "N/A")

    if not asg_name or not tg_arn:
        print("\nERROR: Infrastructure not deployed. Run: make up")
        sys.exit(1)

    print(f"\n  🌐 ALB URL: {alb_url}")

    asg_client = boto3.client("autoscaling", region_name=args.region)
    elbv2_client = boto3.client("elbv2", region_name=args.region)
    cw_client = boto3.client("cloudwatch", region_name=args.region)

    show_asg_status(asg_client, asg_name)
    show_target_health(elbv2_client, tg_arn)
    show_alarm_states(cw_client, "autotier-dev-")

    print(f"\n{'=' * 60}")
    print("  Done.")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
