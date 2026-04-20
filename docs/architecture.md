# AutoTier Architecture

> **Status:** Placeholder — this document is filled in during Step 11.
> Until then, see [`decisions/`](./decisions/) for incremental architecture
> rationale.

## Planned contents

- High-level diagram (ALB → ASG → RDS, Multi-AZ)
- Request flow (client → DNS → ALB → EC2 → RDS)
- Failure modes + detection paths (CloudWatch → SNS → Lambda)
- Network design (CIDR plan, subnets per AZ, NAT strategy)
- Security posture (SG chain, IAM least-privilege, RDS private)
- Observability strategy (metrics, alarms, log destinations)
- Data flow for the chaos test
