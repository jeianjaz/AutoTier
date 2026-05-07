# AutoTier Incident Runbook

> **Owner:** On-call engineer  
> **Last updated:** 2026-05-07  
> **Region:** ap-southeast-1  

## Quick Reference

| Command | Purpose |
|---------|---------|
| `make status` | Full health dashboard (ASG + ALB + alarms) |
| `make logs` | View Lambda remediation activity |
| `make connect` | SSM into an ASG instance |
| `make chaos` | Run chaos test (destructive — confirm first) |

---

## Scenario 1: ALB Unhealthy Hosts Alarm

**Alarm:** `autotier-dev-alb-unhealthy-hosts`  
**Trigger:** ≥1 unhealthy target for 1 minute  

### Symptoms
- Email from "AutoTier Alerts" with subject containing `ALARM: "autotier-dev-alb-unhealthy-hosts"`
- Users may see intermittent 502/503 errors (if only 1 instance was running)

### What happens automatically
1. CloudWatch alarm transitions OK → ALARM
2. SNS publishes to `autotier-dev-alerts` topic
3. Lambda `autotier-dev-remediation` fires:
   - Queries ALB target group for unhealthy targets
   - Terminates unhealthy instances via ASG API (`ShouldDecrementDesiredCapacity=False`)
   - ASG launches replacement automatically
4. New instance boots (~60–90s), passes `/health` check, enters service
5. Alarm returns to OK

### Manual verification
```bash
# Check current state
make status

# View what Lambda did
make logs

# Confirm new instance is serving traffic
curl -s http://<ALB_URL>/health
```

### If auto-recovery stalls (>5 minutes)
1. Check ASG activity: AWS Console → EC2 → Auto Scaling Groups → Activity tab
2. Check if launch template is valid: `terraform plan` (look for drift)
3. Check if AZ capacity is available (rare): try a different instance type
4. Manual fix: `aws autoscaling set-desired-capacity --auto-scaling-group-name autotier-dev-app-asg --desired-capacity 2 --region ap-southeast-1`

---

## Scenario 2: ASG High CPU Alarm

**Alarm:** `autotier-dev-asg-cpu-high`  
**Trigger:** Average CPU > 70% for 5 minutes  

### Symptoms
- Application response times increase
- Alarm email received

### Immediate action
1. Run `make status` — confirm instance count and health
2. Check if this is a traffic spike or a runaway process

### Diagnosis
```bash
# Connect to the instance
make connect

# Inside the instance:
top                          # Check what's consuming CPU
journalctl -u flask-app -f   # Check app logs
```

### Remediation
- **Traffic spike:** ASG should scale out automatically if scaling policies are configured. For now, manually increase desired capacity:
  ```bash
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name autotier-dev-app-asg \
    --desired-capacity 3 --region ap-southeast-1
  ```
- **Runaway process:** SSM in and kill the process, or terminate the instance (ASG replaces it)

---

## Scenario 3: RDS High CPU / High Connections

**Alarms:** `autotier-dev-rds-cpu-high`, `autotier-dev-rds-connections-high`  
**Trigger:** CPU > 80% for 5 min, or connections > 50 for 5 min  

### Symptoms
- App returns database timeout errors
- `/health` endpoint may start failing if DB is unreachable

### Immediate action
1. Check RDS status in AWS Console → RDS → Databases
2. Check if Multi-AZ failover occurred (Events tab)

### Diagnosis
```bash
# SSM into app instance
make connect

# Test database connectivity
python3 -c "
import pymysql, json, boto3
sm = boto3.client('secretsmanager', region_name='ap-southeast-1')
secret = json.loads(sm.get_secret_value(SecretId='autotier-dev-db-credentials')['SecretString'])
conn = pymysql.connect(host=secret['host'], user=secret['username'], password=secret['password'])
print('DB connection OK')
conn.close()
"
```

### Remediation
- **High connections:** Identify source — is it connection pooling misconfigured? Are zombie connections open?
- **High CPU:** Check slow queries. Consider enabling Performance Insights (free for 7-day retention).
- **Emergency:** RDS Multi-AZ failover is automatic. Manual failover: AWS Console → RDS → Actions → Reboot with failover.

---

## Scenario 4: RDS Low Storage

**Alarm:** `autotier-dev-rds-storage-low`  
**Trigger:** Free storage < 5 GB  

### Immediate action
1. Enable storage autoscaling (if not already):
   ```bash
   aws rds modify-db-instance \
     --db-instance-identifier autotier-dev-mysql \
     --max-allocated-storage 100 \
     --region ap-southeast-1
   ```
2. Identify what's consuming space (large tables, logs, binlogs)

---

## Scenario 5: Running the Chaos Test

### Pre-flight checklist
- [ ] Infrastructure is up (`make status` shows 2 healthy targets)
- [ ] You are prepared for ~2 min of reduced capacity
- [ ] No other maintenance is in progress
- [ ] SNS subscription is confirmed (you'll receive alarm emails)

### Running
```bash
cd /path/to/project-2-autotier
source .venv/bin/activate
python scripts/chaos_test.py --region ap-southeast-1
# Type 'yes' when prompted
```

### What to expect
| Time | Event |
|------|-------|
| T+0s | Instance terminated |
| T+5–15s | ALB marks target unhealthy |
| T+15–30s | CloudWatch alarm fires → SNS → Lambda |
| T+30–60s | ASG launches replacement |
| T+60–90s | New instance boots, joins target group |
| T+80–120s | Health check passes → full recovery |

### Expected MTTR: ~80 seconds

### How to abort
- You **cannot** un-terminate an instance
- If something goes wrong, the ASG will still replace the instance automatically
- Worst case: `make down` and `make up` to rebuild everything

---

## Escalation Path

| Level | Action | When |
|-------|--------|------|
| L0 | Auto-remediation (Lambda) | Immediate — no human needed |
| L1 | Run `make status` + `make logs` | If alarm doesn't auto-resolve in 5 min |
| L2 | SSM in, check app/system logs | If issue persists after instance replacement |
| L3 | `terraform plan` to detect drift | If infrastructure state seems corrupted |
| L4 | `make down` + `make up` | Nuclear option — full rebuild (~12 min) |

---

## Post-Incident

After every incident (including chaos tests):
1. Update `docs/chaos-results.md` with measured MTTR
2. If a new failure mode was discovered, add a scenario to this runbook
3. If Lambda didn't fire correctly, check CloudWatch Logs (`make logs`)
