# Architecture Decision Records

Captures the *why* behind key technical choices in AutoTier. Each ADR is an
immutable record: what we chose, why, and what we gave up.

Format: [Michael Nygard's ADR template](https://github.com/joelparkerhenderson/architecture-decision-record).

| ID | Title | Status |
|----|-------|--------|
| [001](./001-three-tier-multi-az.md) | Three-tier architecture with Multi-AZ | Accepted |
| [002](./002-rds-mysql-multi-az.md) | RDS MySQL Multi-AZ + Free-Tier trade-offs | Accepted |
| [003](./003-asg-over-auto-recovery.md) | Auto Scaling Group over EC2 Auto Recovery | Accepted |
| [004](./004-cloudwatch-sns-over-third-party.md) | CloudWatch Alarms + SNS over Datadog / Prometheus | Accepted |
| [005](./005-lambda-sns-over-ssm-run-command.md) | Lambda SNS subscriber over SSM Run Command | Accepted |

## Adding a new ADR

1. Copy `000-template.md` → `NNN-slug.md` (next number).
2. Fill in Context, Decision, Consequences, Alternatives.
3. Open a PR with status `Proposed`. Discuss. Merge as `Accepted`.
4. Never edit an accepted ADR — supersede it with a new one.
