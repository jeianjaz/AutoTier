#!/usr/bin/env python3
"""
AutoTier — Lambda Remediation Log Viewer
==========================================

Tails the auto-remediation Lambda's CloudWatch logs with color-coded output.

Usage:
  python scripts/logs.py --region ap-southeast-1
  python scripts/logs.py --region ap-southeast-1 --minutes 30
  python scripts/logs.py --region ap-southeast-1 --follow

Real-world value:
  After a chaos test or real incident, this answers:
  "What did the Lambda do? Did it find an unhealthy instance? Did it terminate it?"
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone, timedelta

try:
    import boto3
except ImportError:
    print("ERROR: boto3 not installed. Run: pip install -r scripts/requirements.txt")
    sys.exit(1)


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
        return {k: v["value"] for k, v in raw.items()}
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        print(f"ERROR: Could not read Terraform outputs: {e}")
        sys.exit(1)


def format_log_event(event: dict) -> str:
    """Format a single CloudWatch log event for display."""
    ts = datetime.fromtimestamp(event["timestamp"] / 1000, tz=timezone.utc)
    message = event["message"].strip()

    # Color-code based on content
    if "ERROR" in message or "Exception" in message or "Traceback" in message:
        prefix = "❌"
    elif "ALARM" in message or "Terminating" in message or "terminated" in message:
        prefix = "🔥"
    elif "healthy" in message.lower() or "Remediation complete" in message:
        prefix = "✅"
    elif "START" in message or "END" in message or "REPORT" in message:
        prefix = "⚙️ "
    else:
        prefix = "  "

    return f"  {ts.strftime('%H:%M:%S')}  {prefix} {message}"


def fetch_logs(logs_client, log_group: str, start_time: int, next_token: str = None):
    """Fetch log events from CloudWatch."""
    kwargs = {
        "logGroupName": log_group,
        "startTime": start_time,
        "interleaved": True,
    }
    if next_token:
        kwargs["nextToken"] = next_token

    try:
        resp = logs_client.filter_log_events(**kwargs)
        return resp.get("events", []), resp.get("nextToken")
    except logs_client.exceptions.ResourceNotFoundException:
        print(f"  ⚠️  Log group '{log_group}' not found. Has the Lambda been invoked yet?")
        return [], None


def main():
    parser = argparse.ArgumentParser(description="View AutoTier Lambda remediation logs.")
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--tf-dir", default=None)
    parser.add_argument(
        "--minutes", type=int, default=60,
        help="How many minutes back to fetch (default: 60).",
    )
    parser.add_argument(
        "--follow", "-f", action="store_true",
        help="Continuously poll for new log events (like tail -f).",
    )
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tf_dir = args.tf_dir or os.path.join(project_root, "terraform")

    print("=" * 60)
    print("  AutoTier — Lambda Remediation Logs")
    print("=" * 60)

    outputs = get_terraform_outputs(tf_dir)
    log_group = outputs.get("lambda_log_group")

    if not log_group:
        print("\nERROR: Could not read lambda_log_group from Terraform outputs.")
        sys.exit(1)

    print(f"\n  Log group: {log_group}")
    print(f"  Lookback:  {args.minutes} minutes")
    if args.follow:
        print("  Mode:      follow (Ctrl+C to stop)")
    print()

    logs_client = boto3.client("logs", region_name=args.region)
    start_time = int((datetime.now(timezone.utc) - timedelta(minutes=args.minutes)).timestamp() * 1000)

    # Initial fetch
    events, next_token = fetch_logs(logs_client, log_group, start_time)

    if not events and not args.follow:
        print("  No log events found in the last {args.minutes} minutes.")
        print("  The Lambda may not have been invoked recently.")
        return

    for event in events:
        print(format_log_event(event))

    if not args.follow:
        print(f"\n  ({len(events)} events)")
        return

    # Follow mode — poll every 5 seconds
    print(f"\n  --- Following (Ctrl+C to stop) ---\n")
    last_timestamp = events[-1]["timestamp"] + 1 if events else start_time

    try:
        while True:
            time.sleep(5)
            events, next_token = fetch_logs(logs_client, log_group, last_timestamp)
            for event in events:
                print(format_log_event(event))
                last_timestamp = event["timestamp"] + 1
    except KeyboardInterrupt:
        print("\n\n  Stopped.")


if __name__ == "__main__":
    main()
