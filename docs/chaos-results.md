# Chaos Test Results

> Populated automatically by `scripts/chaos_test.py`.

## Methodology

1. `chaos_test.py` reads Terraform outputs to discover the ASG and target group.
2. Picks a random **healthy** instance from the ASG.
3. Records **T0** (UTC) and calls `TerminateInstanceInAutoScalingGroup`
   with `ShouldDecrementDesiredCapacity=False`.
4. Polls the ALB target group health every 10 seconds.
5. Records **T1** when ALL targets are healthy again (desired count met).
6. **MTTR = T1 − T0.**
7. Appends a detailed report (with recovery timeline) below.

## Why this matters

"Self-healing infrastructure" is a claim. **"MTTR: 3m 42s"** is evidence.
Every section below is a measured observation against a live system — the gap
between what engineers *say* their system does and what it actually does.

---

*Run the test: `python scripts/chaos_test.py --region ap-southeast-1`*
*Results appear below after each run.*

---

## Chaos Test — 2026-05-07 06:44:43 UTC

| Metric | Value |
|--------|-------|
| **Region** | `ap-southeast-1` |
| **ASG** | `autotier-dev-app-asg` |
| **Victim instance** | `i-0be833692e717d629` |
| **Desired capacity** | 2 |
| **T0 (instance terminated)** | `2026-05-07 06:44:43 UTC` |
| **T1 (full health restored)** | `2026-05-07 06:46:03 UTC` |
| **MTTR** | **1m 20s (80s)** |

### Recovery timeline

| Time (UTC) | Healthy | Unhealthy | Other | Total |
|------------|---------|-----------|-------|-------|
| 06:44:48 | 1 | 0 | 1 | 2 |
| 06:44:58 | 1 | 0 | 2 | 3 |
| 06:45:09 | 1 | 0 | 2 | 3 |
| 06:45:21 | 1 | 1 | 0 | 2 |
| 06:45:31 | 1 | 1 | 0 | 2 |
| 06:45:41 | 1 | 1 | 0 | 2 |
| 06:45:53 | 1 | 1 | 0 | 2 |
| 06:46:03 | 2 | 0 | 0 | 2 |

### What happened

1. `chaos_test.py` terminated instance `i-0be833692e717d629` via the ASG API at T0.
2. The ALB detected the target as unhealthy within ~15–30s (health check interval).
3. CloudWatch alarm `alb-unhealthy-hosts` transitioned to ALARM → SNS → Lambda fired.
4. The ASG launched a replacement instance (cloud-init: install Python, start Flask).
5. The new instance passed the ALB `/health` check and was marked healthy at T1.
6. **Total MTTR: 1m 20s.**
