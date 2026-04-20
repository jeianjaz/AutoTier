# AutoTier Incident Runbook

> **Status:** Placeholder — filled during Step 11 once all components exist.

## Planned scenarios

1. **EC2 instance fails health check**
   - Expected auto-recovery path
   - How to verify ASG replaced the instance
   - Manual override if auto-recovery stalls

2. **RDS is unreachable**
   - Diagnosis checklist (SG, subnet routes, DNS)
   - Multi-AZ failover behavior
   - Point-in-time restore procedure

3. **ALB returning 5xx errors**
   - Debug path: target group health → SG → app logs
   - Decision tree for rolling back a deploy

4. **Running the chaos test safely**
   - Pre-flight checks
   - What to expect during the 60-120s recovery window
   - How to abort mid-test

Each section will follow this format:

```
### Scenario N: <title>

**Symptoms:** ...
**Immediate action:** ...
**Diagnosis:** ...
**Remediation:** ...
**Post-incident:** log to docs/incidents/, update runbook if new failure mode
```
