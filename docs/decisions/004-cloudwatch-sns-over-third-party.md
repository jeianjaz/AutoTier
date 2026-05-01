# ADR-004: CloudWatch Alarms + SNS for Observability (over Datadog / Prometheus)

- **Status**: Accepted
- **Date**: 2026-05-01
- **Context**: AutoTier Step 6 — observability layer

## Context

Self-healing requires *detection* before *remediation*. Step 6 needs to answer
two questions when something goes wrong:

1. **Did it break?** — somebody (or something) must notice.
2. **Who/what gets told?** — the signal must reach a remediator within seconds.

The remediator in Step 7 will be a Lambda function. In a real production team,
the remediator would also include humans on a pager rotation.

Three serious options for this layer:

1. **AWS CloudWatch Alarms + SNS** — native, fully managed, free at this scale.
2. **Datadog / New Relic / Dynatrace** — third-party APM with richer dashboards
   and anomaly detection.
3. **Self-hosted Prometheus + Alertmanager + Grafana** — open-source, maximum
   control, no vendor lock-in.

## Decision

**Use CloudWatch Alarms + SNS.** A single SNS topic (`autotier-dev-alerts`)
fans out to:

- An **email subscription** (this engineer, for visibility during dev).
- A **Lambda subscription** (Step 7, for auto-remediation).
- *Future*: a Slack webhook or PagerDuty integration via a second Lambda or
  AWS Chatbot.

Five alarms are defined in `cloudwatch.tf`:

| Alarm | Metric | Threshold | Why |
|---|---|---|---|
| `alb-unhealthy-hosts` | `AWS/ApplicationELB UnHealthyHostCount` | ≥ 1 for 1 min | Headline alarm. Starts the MTTR clock in Step 8. |
| `asg-cpu-high` | `AWS/EC2 CPUUtilization` | ≥ 80% for 2 min | Pre-scaling signal; will drive Step 11 scale-out policy. |
| `rds-cpu-high` | `AWS/RDS CPUUtilization` | ≥ 80% for 5 min | Runaway query / connection storm. |
| `rds-connections-high` | `AWS/RDS DatabaseConnections` | ≥ 40 for 5 min | t3.micro caps near 66 connections; 40 = leak. |
| `rds-storage-low` | `AWS/RDS FreeStorageSpace` | ≤ 2 GB for 5 min | Disk-full pushes RDS into read-only — catastrophic. |

## Consequences

### Positive

- **$0 added cost** at this scale: SNS gives 1,000 free email notifications per
  month; the first 10 CloudWatch alarms are free.
- **Zero new infrastructure to operate** — no Prometheus server, no agent on
  instances. CloudWatch metrics flow automatically from ALB, ASG, and RDS.
- **Native IAM** — the Step 7 Lambda's permission to be invoked by SNS is one
  IAM policy, not an API key in a secret.
- **Same topic, many subscribers** — fan-out lets us add Slack/PagerDuty later
  without changing alarm config.
- **Resume signal**: shows up in every AWS SAA / SysOps exam objective.

### Negative

- **No distributed tracing**. We see *that* a target is unhealthy, not *which
  request* caused it. In production we'd add AWS X-Ray (Step 7+) or Datadog APM.
- **Alarm UX is dated**. Mitigated by always defining alarms in Terraform,
  never click-ops.
- **Static thresholds, no anomaly detection**. CloudWatch *does* offer
  anomaly-detection alarms but they aren't free-tier-eligible. Accepted for v1;
  noted as a Step 11 follow-up.

## Alternatives considered

### Datadog / New Relic / Dynatrace

Vastly better dashboards and APM. Rejected because:

- **Cost**: ~$15/host/month for Datadog Infrastructure + APM. With 2 ASG hosts
  that's ~$30/month for *this* project alone — more than the rest of AutoTier's
  runtime cost combined.
- **Off-platform**: the project's value proposition is "I can run AWS"; routing
  alerts through a SaaS would obscure that.
- **Lambda integration is harder**: would need an API key in Secrets Manager
  and an HTTP-call Lambda, vs. native SNS → Lambda invocation.

### Self-hosted Prometheus + Alertmanager + Grafana

Maximum control, full open-source. Rejected because:

- **Operational tax**: requires EC2/ECS for Prometheus, another for Grafana,
  persistent storage, exporter agents on every app instance. Triples the
  surface area of the project.
- **Pulls vs. pushes**: Prometheus scrapes, awkward across the app/data-tier
  security boundary. Would need to open SGs we deliberately closed in Step 2.
- **Defeats the "managed services first" principle** the rest of the project
  follows (RDS Multi-AZ over self-managed MySQL, etc.).

Right answer at ~50+ services across multiple AWS accounts; overkill at one.

### CloudWatch alarms direct to ASG action (no SNS)

CloudWatch alarms *can* trigger ASG scaling policies directly. Rejected for the
alarms in this ADR because:

- The Step 7 Lambda needs to react to multiple alarm types, not just scale.
- An SNS topic in the middle is the standard fan-out point; lets us add
  subscribers (email, Slack, second Lambda) without touching the alarms.
- The future scale-out policy in Step 11 *will* attach to its alarm directly —
  that's the right pattern for *that specific* alarm.

## Implementation notes

- SNS topic name: `autotier-dev-alerts`.
- Email is provided via `var.alert_email` with **no default** — passed via
  `terraform.tfvars` (gitignored). Email addresses do not belong in the repo.
- Email subscription requires **manual confirmation**: AWS sends a "Confirm
  subscription" link to the address; nothing flows until clicked.
- Topic policy explicitly grants `cloudwatch.amazonaws.com` permission to
  `Publish` — without it, alarms in `ALARM` state silently fail to send.
- All alarms set `alarm_actions` and `ok_actions` to the SNS topic so we get
  both fire and recovery emails.
- `treat_missing_data = "notBreaching"` everywhere so an idle metric doesn't
  generate a false alarm during apply or after destroy of dependencies.
