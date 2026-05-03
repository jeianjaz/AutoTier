# ADR-005: Lambda SNS Subscriber for Auto-Remediation (over SSM Run Command / EventBridge Rules)

- **Status**: Accepted
- **Date**: 2026-05-01
- **Context**: AutoTier Step 7 — auto-remediation layer

## Context

Step 6 gives us *detection* (CloudWatch alarm → SNS topic → email). Step 7
must close the loop: **when the alarm fires, automatically terminate the
unhealthy instance so the ASG replaces it**.

Three options for the remediation actor:

1. **Lambda function subscribed to the SNS topic** — receives alarm payload,
   queries ALB target health, terminates the unhealthy instance via the ASG API.
2. **SSM Run Command** — have the alarm invoke a Run Command document on the
   unhealthy instance to restart the app or reboot the host.
3. **EventBridge rule → Step Functions / direct API call** — EventBridge can
   match CloudWatch alarm state changes and call AWS APIs directly.

## Decision

**Lambda subscribed to the SNS topic.**

The function:

1. Parses the SNS → CloudWatch alarm JSON payload.
2. Calls `elbv2:DescribeTargetHealth` on the target group to find which
   instance(s) are `unhealthy`.
3. For each unhealthy instance, calls
   `autoscaling:TerminateInstanceInAutoScalingGroup` with
   `ShouldDecrementDesiredCapacity=False`.
4. The ASG's desired count stays the same, so it immediately launches a
   replacement. The new instance boots, passes the `/health` check, and the
   alarm returns to OK.

This is idempotent: if the instance was already terminated (e.g. ASG's own
ELB health check got there first), the API call returns gracefully and the
Lambda logs "already terminated".

## Consequences

### Positive

- **Sub-minute remediation**: Lambda cold start ~200ms + API calls ~500ms.
  Total detection-to-termination: ~90s (60s alarm period + ~30s Lambda).
- **No infrastructure to manage**: Lambda is serverless; no EC2, no container,
  no cron.
- **Same SNS topic, additive**: the email subscription (Step 6) continues to
  work. Adding the Lambda is just another subscriber — no changes to alarms or
  the topic.
- **Full audit trail**: CloudWatch Logs captures every invocation, every
  decision ("instance i-xxx is unhealthy, terminating"), every API response.
- **Cost: $0**: Lambda free tier = 1M requests + 400,000 GB-seconds/month. We
  expect <10 invocations/month during chaos tests.
- **Resume signal**: "built a Lambda that auto-remediates unhealthy instances
  by subscribing to CloudWatch alarms via SNS" is a strong talking point.

### Negative

- **Cold starts**: first invocation after idle takes ~200-500ms. Irrelevant
  for remediation (we're measuring MTTR in minutes, not milliseconds).
- **Python runtime maintenance**: Lambda runtimes eventually reach EOL. We pin
  `python3.12` and note the upgrade path in the runbook (Step 11).
- **Single point of failure**: if the Lambda itself is broken (bad deploy,
  permission removed), remediation stops. Mitigated by: (a) the ASG's own
  ELB health check still terminates/replaces after `health_check_grace_period`,
  just slower; (b) the email still reaches us; (c) Lambda has built-in retries
  (SNS delivers up to 3 times on failure).

## Alternatives considered

### SSM Run Command

Could send a `RestartService` document to the failing instance. Rejected:

- **Requires the instance to be reachable via SSM agent**. If the instance is
  hung or the agent crashed, Run Command can't reach it.
- **Restarts the app, not the instance**. If the root cause is a corrupted
  disk, exhausted memory, or a kernel panic, restarting Flask won't help.
  Termination + fresh launch is more reliable.
- **Harder to audit**: Run Command output lives in SSM, not CloudWatch Logs.

### EventBridge rule → direct API target

EventBridge can match alarm state changes and call `TerminateInstance` directly
via an API destination or a built-in target. Rejected:

- **Can't query target health first**: EventBridge rules are pattern-match →
  action. We need logic ("which instance is unhealthy?") that requires an API
  call to `DescribeTargetHealth` before we know *what* to terminate.
- **Less observable**: no CloudWatch Logs trail of the decision process.
- **EventBridge → direct EC2 action skips the ASG**: calling
  `ec2:TerminateInstances` directly doesn't tell the ASG "I did this on
  purpose". The ASG would see an unexpected termination and might enter a
  thrash loop. `TerminateInstanceInAutoScalingGroup` is the correct API.

### CloudWatch alarm → ASG scaling policy

CloudWatch alarms can trigger ASG scaling policies directly. Rejected for
remediation because:

- Scaling policies change *desired count*, not *terminate a specific instance*.
  If instance A is sick and B is healthy, a scale-out would add C but leave A
  running (still failing health checks, still eating alarm budget).
- The correct action is "terminate the specific bad instance", which only
  `TerminateInstanceInAutoScalingGroup` does.

## Implementation notes

- Lambda function name: `autotier-dev-remediation`.
- Runtime: `python3.12`, handler: `handler.lambda_handler`.
- Memory: 128 MB (API calls only, no data processing).
- Timeout: 30s (generous; typical execution is <2s).
- Source code lives in `lambda/remediation/handler.py`.
- IAM role: `autotier-dev-lambda-remediation-role` with inline policy scoped
  to the specific target group ARN and ASG ARN.
- SNS trigger: `aws_sns_topic_subscription` with protocol `lambda` +
  `aws_lambda_permission` granting SNS invoke access.
- CloudWatch log group: `/aws/lambda/autotier-dev-remediation`, 14-day
  retention (enough for chaos test analysis, cheap).
- The Lambda is idempotent: re-processing the same alarm is safe (already-
  terminated instances return a clean error, logged and skipped).
