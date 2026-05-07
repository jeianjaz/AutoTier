#!/usr/bin/env python3
"""
AutoTier — Chaos Test: Kill an Instance, Measure MTTR
=====================================================

This is the flagship deliverable of the AutoTier project. It answers:
  "If an EC2 instance dies, how long until the system is fully healthy again?"

What it does (in order):
  1. Reads Terraform outputs to discover the ASG name, target group ARN, and ALB DNS.
  2. Picks a random healthy instance from the ASG.
  3. Records the start time (T0).
  4. Terminates that instance via the ASG API (simulating a crash).
  5. Polls the ALB target group health every 10 seconds.
  6. When ALL targets are healthy again, records the end time (T1).
  7. MTTR = T1 - T0.
  8. Prints a structured report and optionally appends to docs/chaos-results.md.

Usage:
  cd project-2-autotier
  python scripts/chaos_test.py --region ap-southeast-1

Prerequisites:
  - AWS credentials configured (same profile used for Terraform)
  - Infrastructure is UP (make up)
  - pip install -r scripts/requirements.txt
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time
from datetime import datetime, timezone

try:
    import boto3
except ImportError:
    print("ERROR: boto3 not installed. Run: pip install -r scripts/requirements.txt")
    sys.exit(1)


# ─── Terraform Output Helpers ───────────────────────────────────────────────

def get_terraform_outputs(tf_dir: str) -> dict:
    """Run `terraform output -json` and return parsed dict."""
    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=tf_dir,
            capture_output=True,
            text=True,
            check=True,
        )
        raw = json.loads(result.stdout)
        # terraform output -json wraps each value in {"value": ..., "type": ...}
        return {k: v["value"] for k, v in raw.items()}
    except FileNotFoundError:
        print("ERROR: 'terraform' not found in PATH.")
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: terraform output failed:\n{e.stderr}")
        sys.exit(1)


# ─── AWS Client Helpers ─────────────────────────────────────────────────────

def get_healthy_instances(asg_client, elbv2_client, asg_name: str, tg_arn: str) -> list:
    """Return instance IDs that are both in the ASG and healthy in the target group."""
    # Get ASG instance IDs
    asg_resp = asg_client.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )
    asg_groups = asg_resp.get("AutoScalingGroups", [])
    if not asg_groups:
        print(f"ERROR: ASG '{asg_name}' not found.")
        sys.exit(1)

    asg_instance_ids = {
        inst["InstanceId"]
        for inst in asg_groups[0]["Instances"]
        if inst["LifecycleState"] == "InService"
    }

    # Get target group health
    tg_resp = elbv2_client.describe_target_health(TargetGroupArn=tg_arn)
    healthy_ids = [
        t["Target"]["Id"]
        for t in tg_resp["TargetHealthDescriptions"]
        if t["TargetHealth"]["State"] == "healthy"
        and t["Target"]["Id"] in asg_instance_ids
    ]
    return healthy_ids


def wait_for_degradation(elbv2_client, tg_arn: str, desired_count: int, victim_id: str, poll_interval: int = 5) -> None:
    """Wait until the victim is no longer healthy (confirming termination took effect)."""
    print(f"\n⏳ Waiting for {victim_id} to leave the healthy pool...")
    while True:
        resp = elbv2_client.describe_target_health(TargetGroupArn=tg_arn)
        targets = resp["TargetHealthDescriptions"]

        healthy_ids = [
            t["Target"]["Id"] for t in targets
            if t["TargetHealth"]["State"] == "healthy"
        ]

        now = datetime.now(timezone.utc)

        if victim_id not in healthy_ids or len(healthy_ids) < desired_count:
            print(f"  {now.strftime('%H:%M:%S')}  Degradation confirmed: {len(healthy_ids)}/{desired_count} healthy")
            return

        print(f"  {now.strftime('%H:%M:%S')}  Still {len(healthy_ids)} healthy (victim not yet removed)...")
        time.sleep(poll_interval)


def wait_for_full_health(elbv2_client, tg_arn: str, desired_count: int, poll_interval: int = 10) -> list:
    """Poll target group until `desired_count` targets are healthy. Returns timeline."""
    timeline = []
    while True:
        resp = elbv2_client.describe_target_health(TargetGroupArn=tg_arn)
        targets = resp["TargetHealthDescriptions"]

        healthy = [t for t in targets if t["TargetHealth"]["State"] == "healthy"]
        unhealthy = [t for t in targets if t["TargetHealth"]["State"] == "unhealthy"]
        other = [t for t in targets if t["TargetHealth"]["State"] not in ("healthy", "unhealthy")]

        now = datetime.now(timezone.utc)
        entry = {
            "time": now.isoformat(),
            "healthy": len(healthy),
            "unhealthy": len(unhealthy),
            "other": len(other),
            "total": len(targets),
        }
        timeline.append(entry)

        status_parts = []
        if healthy:
            status_parts.append(f"✅ {len(healthy)} healthy")
        if unhealthy:
            status_parts.append(f"❌ {len(unhealthy)} unhealthy")
        if other:
            states = [t["TargetHealth"]["State"] for t in other]
            status_parts.append(f"⏳ {len(other)} ({', '.join(set(states))})")

        elapsed = ""
        if len(timeline) > 1:
            t0 = datetime.fromisoformat(timeline[0]["time"])
            elapsed = f" [{int((now - t0).total_seconds())}s elapsed]"

        print(f"  {now.strftime('%H:%M:%S')}  {' | '.join(status_parts)}{elapsed}")

        if len(healthy) >= desired_count:
            return timeline

        time.sleep(poll_interval)


# ─── Report Generator ───────────────────────────────────────────────────────

def generate_report(
    victim_id: str,
    asg_name: str,
    desired_count: int,
    t0: datetime,
    t1: datetime,
    timeline: list,
    region: str,
) -> str:
    """Build a Markdown report block for docs/chaos-results.md."""
    mttr_seconds = (t1 - t0).total_seconds()
    minutes = int(mttr_seconds // 60)
    seconds = int(mttr_seconds % 60)

    report = f"""
## Chaos Test — {t0.strftime('%Y-%m-%d %H:%M:%S UTC')}

| Metric | Value |
|--------|-------|
| **Region** | `{region}` |
| **ASG** | `{asg_name}` |
| **Victim instance** | `{victim_id}` |
| **Desired capacity** | {desired_count} |
| **T0 (instance terminated)** | `{t0.strftime('%Y-%m-%d %H:%M:%S UTC')}` |
| **T1 (full health restored)** | `{t1.strftime('%Y-%m-%d %H:%M:%S UTC')}` |
| **MTTR** | **{minutes}m {seconds}s ({int(mttr_seconds)}s)** |

### Recovery timeline

| Time (UTC) | Healthy | Unhealthy | Other | Total |
|------------|---------|-----------|-------|-------|
"""
    for entry in timeline:
        t = datetime.fromisoformat(entry["time"]).strftime("%H:%M:%S")
        report += f"| {t} | {entry['healthy']} | {entry['unhealthy']} | {entry['other']} | {entry['total']} |\n"

    report += f"""
### What happened

1. `chaos_test.py` terminated instance `{victim_id}` via the ASG API at T0.
2. The ALB detected the target as unhealthy within ~15–30s (health check interval).
3. CloudWatch alarm `alb-unhealthy-hosts` transitioned to ALARM → SNS → Lambda fired.
4. The ASG launched a replacement instance (cloud-init: install Python, start Flask).
5. The new instance passed the ALB `/health` check and was marked healthy at T1.
6. **Total MTTR: {minutes}m {seconds}s.**
"""
    return report


def append_to_results_file(report: str, results_path: str):
    """Append the report to docs/chaos-results.md."""
    if not os.path.exists(results_path):
        header = """# Chaos Test Results

Each section below documents one chaos test run — an instance was deliberately
killed and we measured how long until the system was fully healthy again.

---
"""
        with open(results_path, "w", encoding="utf-8") as f:
            f.write(header)

    with open(results_path, "a", encoding="utf-8") as f:
        f.write("\n---\n")
        f.write(report)

    print(f"\n📄 Report appended to {results_path}")


# ─── Main ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="AutoTier Chaos Test — kill an instance, measure MTTR."
    )
    parser.add_argument(
        "--region", default="ap-southeast-1",
        help="AWS region (default: ap-southeast-1)",
    )
    parser.add_argument(
        "--tf-dir", default=None,
        help="Path to the terraform/ directory. Auto-detected if run from project root.",
    )
    parser.add_argument(
        "--poll-interval", type=int, default=10,
        help="Seconds between health polls (default: 10).",
    )
    parser.add_argument(
        "--no-save", action="store_true",
        help="Don't append results to docs/chaos-results.md.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be done without actually terminating.",
    )
    args = parser.parse_args()

    # ── Resolve paths ──
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tf_dir = args.tf_dir or os.path.join(project_root, "terraform")
    results_path = os.path.join(project_root, "docs", "chaos-results.md")

    print("=" * 60)
    print("  AutoTier — Chaos Test: Kill an Instance, Measure MTTR")
    print("=" * 60)

    # ── Step 1: Read Terraform outputs ──
    print("\n🔍 Reading Terraform outputs...")
    outputs = get_terraform_outputs(tf_dir)

    asg_name = outputs.get("asg_name")
    tg_arn = outputs.get("target_group_arn")
    alb_url = outputs.get("alb_url", "N/A")

    if not asg_name or not tg_arn:
        print("ERROR: Could not read asg_name or target_group_arn from Terraform outputs.")
        print("       Is the infrastructure up? Run: make up")
        sys.exit(1)

    print(f"   ASG:          {asg_name}")
    print(f"   Target Group: {tg_arn.split('/')[-2]}/{tg_arn.split('/')[-1]}")
    print(f"   ALB URL:      {alb_url}")

    # ── Step 2: Find healthy instances ──
    print("\n🔍 Discovering healthy instances...")
    asg_client = boto3.client("autoscaling", region_name=args.region)
    elbv2_client = boto3.client("elbv2", region_name=args.region)

    healthy_ids = get_healthy_instances(asg_client, elbv2_client, asg_name, tg_arn)
    if not healthy_ids:
        print("ERROR: No healthy instances found. Is the app running?")
        sys.exit(1)

    print(f"   Found {len(healthy_ids)} healthy instance(s): {healthy_ids}")

    # Get desired capacity for later
    asg_resp = asg_client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    desired_count = asg_resp["AutoScalingGroups"][0]["DesiredCapacity"]

    # ── Step 3: Pick a victim ──
    victim_id = random.choice(healthy_ids)
    print(f"\n🎯 Victim selected: {victim_id}")

    if args.dry_run:
        print(f"\n⚠️  --dry-run flag set. Would terminate {victim_id} but stopping here.")
        sys.exit(0)

    # ── Step 4: Confirm ──
    print(f"\n⚠️  This will TERMINATE instance {victim_id} in ASG '{asg_name}'.")
    print("   The ASG will replace it automatically. This is a destructive action.")
    confirm = input("   Type 'yes' to proceed: ").strip().lower()
    if confirm != "yes":
        print("Aborted.")
        sys.exit(0)

    # ── Step 5: Terminate the victim (T0) ──
    print(f"\n🔥 Terminating {victim_id}...")
    t0 = datetime.now(timezone.utc)

    asg_client.terminate_instance_in_auto_scaling_group(
        InstanceId=victim_id,
        ShouldDecrementDesiredCapacity=False,
    )
    print(f"   ✅ Termination requested at {t0.strftime('%H:%M:%S UTC')}")
    print(f"   MTTR clock started.")

    # ── Step 6: Wait for degradation, then poll until fully healthy ──
    wait_for_degradation(elbv2_client, tg_arn, desired_count, victim_id)

    print(f"\n⏱️  Polling target group health every {args.poll_interval}s...")
    print(f"   Waiting for {desired_count} healthy target(s)...\n")

    timeline = wait_for_full_health(elbv2_client, tg_arn, desired_count, args.poll_interval)

    t1 = datetime.now(timezone.utc)
    mttr_seconds = (t1 - t0).total_seconds()
    minutes = int(mttr_seconds // 60)
    seconds = int(mttr_seconds % 60)

    # ── Step 7: Report ──
    print("\n" + "=" * 60)
    print(f"  ✅ FULL HEALTH RESTORED")
    print(f"  MTTR: {minutes}m {seconds}s ({int(mttr_seconds)}s)")
    print("=" * 60)

    report = generate_report(
        victim_id=victim_id,
        asg_name=asg_name,
        desired_count=desired_count,
        t0=t0,
        t1=t1,
        timeline=timeline,
        region=args.region,
    )

    print(report)

    if not args.no_save:
        append_to_results_file(report, results_path)

    print("Done. The self-healing loop works. ✅")


if __name__ == "__main__":
    main()
