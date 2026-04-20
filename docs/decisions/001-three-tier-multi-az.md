# ADR-001: Three-Tier Architecture with Multi-AZ Deployment

- **Status:** Accepted
- **Date:** 2026-04-20
- **Deciders:** Jeian Jasper

## Context

AutoTier's purpose is to demonstrate resilience engineering: a system that
continues serving traffic when individual components fail. The design must
survive (a) a single EC2 instance crash, (b) a single Availability Zone
outage, and (c) a database primary failure — without manual intervention.

A single-tier, single-AZ deployment (e.g. one EC2 with a local MySQL) would
be cheaper and simpler, but it conflates concerns, cannot scale horizontally,
and has no failure isolation. Since the entire project is about *measurable
recovery*, the architecture must have real failure domains to measure across.

## Decision

Deploy AutoTier as a **three-tier architecture across two Availability Zones**:

- **Tier 1 (Edge):** Application Load Balancer spanning both AZs, fronted by
  Route 53 / the ALB DNS name.
- **Tier 2 (Compute):** EC2 instances in an Auto Scaling Group with minimum
  size 2, spread across both AZs. Stateless web/app workload.
- **Tier 3 (Data):** RDS MySQL with Multi-AZ enabled. Primary in one AZ,
  synchronous standby in the other. Automatic failover on primary failure.

Only the ALB sits in public subnets. EC2 and RDS live in private subnets.
Outbound internet for private resources routes through a single NAT Gateway
(cost trade-off, see Consequences).

## Consequences

**Positive**
- **Failure isolation:** Losing an AZ takes out at most half the compute and
  triggers RDS failover — the system keeps serving.
- **Horizontal scalability:** The ASG can grow/shrink without touching data
  or edge layers.
- **Security by design:** Data tier is unreachable from the internet; only
  the app tier can talk to RDS via tier-chained security groups.
- **Real measurement surface:** The chaos test (`scripts/chaos_test.py`)
  has something meaningful to measure — ASG replacement across AZs.
- **Industry-standard shape:** Mirrors how real production web apps are
  deployed; useful as interview signal.

**Negative**
- **Higher idle cost:** NAT Gateway (~$1.10/day), ALB (~$0.55/day), and RDS
  baseline charges run even with zero traffic. Mitigated by `make down`.
- **More moving parts:** More Terraform, more IAM, more security groups,
  more ways to misconfigure — accepted as a learning goal.
- **Single NAT Gateway (cost compromise):** A true production design puts
  one NAT per AZ. We run one to keep hourly cost down; a full-prod
  variant is left as an exercise.

## Alternatives Considered

- **Single-AZ single-EC2 with embedded database** — rejected: no failure
  isolation, cannot demonstrate resilience, defeats the project's purpose.
- **Single-tier containers on ECS Fargate** — rejected: shifts the learning
  focus from AWS networking/IaC fundamentals to container orchestration.
  Kubernetes/containers are the focus of Project 3 (DockerLens).
- **Serverless (API Gateway + Lambda + DynamoDB)** — rejected: already the
  shape of Project 1 (CloudDeck). AutoTier intentionally uses long-running
  compute so failures are observable as instance replacements.
- **Three AZs instead of two** — rejected for cost: 2 AZs is enough to
  demonstrate every failure scenario AutoTier cares about, at lower burn.
