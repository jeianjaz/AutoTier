# ADR-003: Auto Scaling Group over EC2 Auto Recovery

- **Status**: Accepted
- **Date**: 2026-04-29
- **Deciders**: Jeian Jasper (sole engineer)
- **Related**: ADR-001 (three-tier multi-AZ), ADR-002 (RDS multi-AZ)

## Context

AutoTier needs the EC2 app tier to recover from instance failure without
manual intervention. AWS offers two real mechanisms:

1. **EC2 Auto Recovery** — a CloudWatch alarm on the system status check
   recovers the *same* instance ID on healthy hardware in the *same AZ*.
2. **Auto Scaling Group (ASG)** — a managed pool of instances behind a
   launch template. Replaces unhealthy instances with brand-new ones,
   spreads across AZs, and is the substrate for horizontal scaling.

The project's stated flagship deliverable is a **measured MTTR via chaos
engineering**. The choice here decides what kinds of failure that test
can demonstrate.

## Decision

**Use an Auto Scaling Group with `health_check_type = "ELB"`.**

- **Min = 2, Desired = 2, Max = 4.** Two AZs, one instance each by default,
  room to double if a scale-out event is added later.
- **`health_check_type = "ELB"`** so the ASG terminates instances the ALB
  marks unhealthy, not just instances that fail EC2 hardware checks.
- **`health_check_grace_period = 180s`** to give cloud-init enough time
  to install Python, write the Flask app, and start the systemd unit
  before the ALB starts judging health.
- **Launch template, not launch configuration.** Launch configs were
  deprecated in 2023; templates support versioning, IMDSv2, and the
  full modern instance feature set.

## Consequences

### Positive

- **Recovers from app-level failure**, not just hardware. Killing the Flask
  process triggers ALB-detected unhealthy → ASG terminate → ASG launches
  a fresh instance. Auto Recovery would not detect this.
- **Spreads across AZs.** Instance in AZ-1a dies, ASG can launch the
  replacement in either AZ — preserving zonal redundancy automatically.
- **Substrate for chaos test.** Step 8 will `aws ec2 stop-instances`
  on a target and measure how long until the ALB sees a healthy fleet
  again. That experiment makes no sense without an ASG.
- **Substrate for blue/green or rolling deploys later.** Step 11's
  "production framing" pass can introduce `instance_refresh` to roll
  through new launch template versions with zero downtime.

### Negative / Trade-offs

- **Replaced instances have new IDs.** Anything keyed on instance ID (logs,
  CloudWatch alarms targeting a specific instance, manual SSH key trust)
  breaks. We avoid this by tagging instances, using SSM (which targets
  instance IDs but resolves them dynamically), and routing logs by
  instance metadata.
- **Slightly more configuration.** A launch template + ASG + target
  group is three resources where Auto Recovery is one alarm. The payoff
  is real-world relevance.
- **Cold starts.** A replaced instance must run cloud-init before serving
  traffic — adds ~90s to recovery vs Auto Recovery's same-instance reboot
  (~60s). Mitigated by min=2: the surviving instance keeps serving while
  the replacement boots.

## Alternatives Considered

### A. EC2 Auto Recovery (CloudWatch alarm + recover action)

- **Pros**: Single resource. Faster recovery for the same-instance case.
  Preserves instance ID.
- **Cons**:
  - Only triggers on system status check failures (hardware/hypervisor),
    not on app crashes, OOM, or stuck processes.
  - Recovers in the *same AZ*. If the AZ itself is unhealthy, recovery
    can fail.
  - No horizontal scale. To add a second instance you re-architect.
- **Verdict**: Rejected. Misses the "app crashed" failure mode that the
  chaos test needs to demonstrate.

### B. ECS Fargate

- **Pros**: No EC2 to manage. AWS handles host patching. Faster cold
  starts than launch-template EC2.
- **Cons**: Different operational model entirely. Containerizes the app
  (extra step out of scope). Hides the EC2/ALB/ASG primitives the
  project is specifically meant to teach.
- **Verdict**: Out of scope. Worth a separate project if/when AutoTier
  evolves into a container demo.

### C. Kubernetes (EKS)

- **Pros**: Industry-relevant. Sub-second pod replacement.
- **Cons**: $73/month for the EKS control plane alone. Wildly
  disproportionate to a portfolio demo's needs.
- **Verdict**: Out of scope. Project 3 (DockerLens + Kubernetes)
  will cover this stack.

## Implementation Notes

- **Launch template `update_default_version = true`** so changing user-data
  or instance type increments the default version, not just the latest.
  ASG references `version = "$Latest"` and pulls the new template on
  next instance replacement.
- **Target group `deregistration_delay = 30`** (default 300). Five
  minutes of draining is appropriate for long-lived stateful sessions;
  AutoTier's stateless `/` page needs ~zero. Faster drain = faster
  chaos-test recovery measurement.
- **No scaling policy yet.** This ADR only commits to "self-healing." A
  scale-out-on-CPU policy could land in Step 6 (CloudWatch + SNS) but
  is not required for the MTTR narrative.
- **Single internet-facing ALB on :80 only for now.** HTTPS would need
  an ACM certificate and a domain; out of scope for v1. Step 11 may
  add ACM + Route 53 if a custom domain is wired up.
