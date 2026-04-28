# ADR-002: RDS MySQL Multi-AZ over Aurora and Single-AZ

- **Status**: Accepted
- **Date**: 2026-04-27
- **Deciders**: Jeian Jasper (sole engineer)
- **Related**: ADR-001 (three-tier architecture)

## Context

AutoTier needs a relational database for the app tier. Three real choices on AWS:

1. **RDS MySQL Single-AZ** — one EC2 host running MySQL, daily snapshots.
2. **RDS MySQL Multi-AZ** — synchronous replica in a second AZ, automatic failover.
3. **Aurora MySQL-Compatible** — AWS-rebuilt MySQL with a distributed storage layer, sub-second failover, read replicas, but higher floor cost and no `db.t3.micro`-class instance.

The project's stated goal is to **measure** Mean Time To Recovery from real failures. The database choice dominates that number — if it takes 30 minutes for a single-AZ DB to come back, MTTR is 30 minutes regardless of how clever EC2 auto-recovery is.

## Decision

**Use RDS MySQL 8.0 with `multi_az = true` on `db.t3.micro`, 20 GB gp3 storage.**

Reasoning:

- **Multi-AZ is the only way to demonstrate sub-2-minute database recovery** without manual snapshot restore. Single-AZ would force a 10–30 min RTO that defeats the chaos-test narrative.
- **Aurora was rejected** — see Alternatives. Short version: 3x the floor cost for capabilities the chaos test doesn't exercise.
- **`db.t3.micro` keeps Multi-AZ affordable** (~$24/month). With the $20 RDS credit and `terraform destroy` between dev sessions, real out-of-pocket is near zero.
- **MySQL 8.0** because that's what most SMB stacks run; matches what an entry-level cloud engineer will actually face.

## Consequences

### Positive

- Demonstrable sub-2-minute failover RTO (measured in chaos test, Step 8).
- Free automated backups, automatic minor version patching, encryption at rest.
- Resume-able: "I built a Multi-AZ MySQL with sub-2-min failover, measured by chaos engineering."

### Negative / Trade-offs

- ~2x compute cost vs single-AZ. Mitigated by `terraform destroy` between dev sessions.
- Standby is invisible (not a read replica). Read scaling would need `aws_db_instance_read_replica` — out of scope for v1.
- `db.t3.micro` uses burstable CPU credits. Under sustained load it can throttle. Fine for a portfolio demo; production would step to `db.t3.small` minimum.

## Alternatives Considered

### A. Single-AZ RDS MySQL
- **Pros**: Half the cost (~$12/month). Simpler.
- **Cons**: Failure recovery requires snapshot restore — RTO 10–30 minutes, undermines AutoTier's "self-healing" thesis.
- **Verdict**: Rejected. The whole project is about HA; cutting the DB out of HA defeats the point.

### B. Aurora MySQL-Compatible
- **Pros**: Faster failover (<30s), distributed storage layer survives whole-AZ failure on the storage side, easy horizontal read scaling.
- **Cons**:
  - No `db.t3.micro` — minimum is `db.t4g.medium` at ~$60/month, **3x the cost**.
  - Our chaos test (stop primary, measure recovery) is a narrative around classic failover, not Aurora's transparent storage layer.
  - Aurora's deeper feature surface is overkill and reads as resume-padding for a single-region demo.
- **Verdict**: Rejected for AutoTier. Revisit for multi-region or read-heavy workloads.

### C. DynamoDB
- **Pros**: Serverless, scales horizontally, always multi-AZ by design.
- **Cons**: NoSQL. The skill being demonstrated here is **classic 3-tier with relational data and HA**. DynamoDB sidesteps the interesting part.
- **Verdict**: Out of scope. Would be an entirely different project.

## Implementation Notes

- DB password generated at apply time via `random_password` and stored in **AWS Secrets Manager**. EC2 reads it at runtime via IAM role. Never committed, never in env vars, never in `terraform.tfvars`.
- Storage encrypted at rest with the AWS-managed `aws/rds` KMS key (free; customer-managed KMS would add ~$1/month).
- `deletion_protection = false` for now because `terraform destroy` is a daily action. **Will flip to `true` in Step 11** alongside `skip_final_snapshot = false` before any "production" framing.
- Backup retention 7 days — enough to demonstrate point-in-time recovery in the runbook without paying for a month of backup storage.

- **`backup_retention_period = 0`** because AWS Free Plan accounts cap retention at 0.
  On a paid account, this would be 7 to enable daily automated backups + PITR.
  Step 11's "production framing" pass flips this back to 7.