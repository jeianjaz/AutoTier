# AutoTier

**Self-healing 3-tier infrastructure on AWS that recovers from failures without human intervention.**

> Part 2 of a 4-project Cloud/DevOps portfolio ([CLOUD2026](https://github.com/jeianjaz)).
> Previous: [CloudDeck](https://github.com/jeianjaz/project-1-self-deploying-portfolio) — serverless portfolio.

---

## Architecture

![AutoTier Architecture](./docs/autotier-architecture.png)

*Red paths trace the self-healing flow: a CloudWatch alarm fires on an
unhealthy host, publishes to SNS, and invokes a Lambda that terminates the
failed instance — the Auto Scaling Group then replaces it, spreading across
AZs as needed. Normal request flow (black) is kept visually quiet so the
recovery path dominates.*

---

## Why this project exists

Most tutorials teach you how to *deploy* infrastructure. Few teach you what
happens at 3 AM when an EC2 instance dies, the database drops connections, or
a load balancer starts returning 5xx errors.

AutoTier is a hands-on answer to that question: a production-shaped 3-tier
architecture where **failure is expected, detected, and remediated
automatically** — and the recovery time is *measured*, not assumed.

## What's inside

| Layer | AWS Service | Purpose |
|-------|-------------|---------|
| Edge | Application Load Balancer (ALB) | TLS termination, health checks, request routing |
| Web / App | EC2 + Auto Scaling Group (Multi-AZ) | Horizontally scalable stateless compute |
| Data | RDS MySQL (Multi-AZ) | Relational storage with automated failover |
| Observability | CloudWatch + SNS | Metric-based alerting on health / CPU / 5xx |
| Remediation | Lambda (Python) | Auto-replaces unhealthy instances on alarm |
| Chaos | `scripts/chaos_test.py` | Stops an EC2, measures Mean Time To Recovery |

## Key characteristics

- **Multi-AZ by default** — ALB + ASG + RDS all span two availability zones.
- **Self-healing** — CloudWatch alarms → SNS → Lambda terminates unhealthy
  instances; the ASG replaces them automatically.
- **Measured recovery** — `chaos_test.py` produces a real MTTR number
  documented in [`docs/chaos-results.md`](./docs/chaos-results.md).
- **IaC-first** — 100% Terraform, no click-ops. `terraform destroy` takes the
  environment to $0 cost.
- **Engineering-grade repo** — ADRs, incident runbook, feature-branch PRs,
  Checkov in CI, conventional commits.

## Project status

✅ **Complete — 11/11 steps done.**
See [`docs/decisions/`](./docs/decisions/) for the rationale behind each
design choice.

| Step | Status | Highlights |
|------|--------|------------|
| 0  — Repo scaffold, ADR-001 design             | 🟢 DONE | Three-tier Multi-AZ design accepted |
| 1  — VPC + networking                          | 🟢 DONE | 1 VPC / 6 subnets / IGW / NAT / 3 route tables |
| 2  — Security groups                           | 🟢 DONE | ALB → App → RDS chain via SG references |
| 3  — RDS data tier                             | 🟢 DONE | MySQL 8.0 Multi-AZ, password in Secrets Manager |
| 4  — EC2 + user data                           | 🟢 DONE | Flask app + IAM + SSM, DB OK verified end-to-end |
| 5  — ALB + Auto Scaling Group                  | 🟢 DONE | Public ALB + 2-instance ASG across AZs, ELB health checks |
| 6  — CloudWatch + SNS alarms                   | 🟢 DONE | 5 alarms (ALB, ASG CPU, RDS CPU/conn/storage) + email alerts |
| 7  — Lambda auto-remediation                   | 🟢 DONE | SNS → Lambda terminates unhealthy targets, ASG replaces |
| 8  — Chaos testing + MTTR measurement          | 🟢 DONE | **MTTR: 80s** — measured via `chaos_test.py` |
| 9  — Helper scripts                            | 🟢 DONE | `status.py`, `logs.py`, `connect.py` (SSM) |
| 10 — CI/CD + Checkov + branch protection       | 🟢 DONE | 3-job GitHub Actions pipeline, branch ruleset |
| 11 — Runbook + production framing + README      | 🟢 DONE | Incident playbook, escalation path, polished docs |

## Architecture Decisions

| ADR | Decision |
|-----|----------|
| [001](./docs/decisions/001-three-tier-multi-az.md) | Three-tier architecture with Multi-AZ |
| [002](./docs/decisions/002-rds-mysql-multi-az.md) | RDS MySQL Multi-AZ over Aurora and Single-AZ |
| [003](./docs/decisions/003-asg-over-auto-recovery.md) | Auto Scaling Group over EC2 Auto Recovery |
| [004](./docs/decisions/004-cloudwatch-sns-over-third-party.md) | CloudWatch + SNS over Datadog / Prometheus |
| [005](./docs/decisions/005-lambda-sns-over-ssm-run-command.md) | Lambda SNS subscriber over SSM Run Command |
| [006](./docs/decisions/006-ci-cd-checkov.md) | GitHub Actions CI with Checkov over manual reviews |

## Operational Commands

```bash
make status    # Health dashboard: ASG + ALB targets + alarm states
make logs      # View Lambda remediation activity
make connect   # SSM into an ASG instance (no SSH, no keys)
make chaos     # Run chaos test — measures MTTR (destructive)
```

See [`docs/runbook.md`](./docs/runbook.md) for the full incident response playbook.

## Running locally

**Prerequisites:** AWS credentials (IAM user, not root), Terraform ≥ 1.6, Python ≥ 3.11.

```bash
# Create terraform.tfvars (gitignored) with your email for alarm notifications
echo 'alert_email = "you@example.com"' > terraform/terraform.tfvars

make plan      # terraform plan
make up        # terraform apply (~12 min, RDS is the long pole)
make down      # terraform destroy (ALWAYS run after a work session)
```

After `make up`, confirm the SNS email subscription (check your inbox) to
receive alarm notifications.

## Cost discipline

NAT Gateway, ALB, and RDS are the primary cost drivers (~$2/day when up).
This project is **designed to be destroyed between work sessions**.
`make down` is a reflex, not an afterthought.

## Author

Jeian Jasper — BS Information Technology, Quezon City University.
Building toward Cloud/DevOps roles in 2026.
