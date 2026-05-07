#!/usr/bin/env python3
"""
AutoTier — SSM Session Manager Connect
========================================

Lists running ASG instances and starts an SSM Session Manager session
to the one you pick. No SSH keys, no port 22, no bastion host.

Usage:
  python scripts/connect.py --region ap-southeast-1
  python scripts/connect.py --region ap-southeast-1 --index 0

Real-world value:
  Production environments use SSM over SSH because:
  - No key management (IAM handles auth)
  - No inbound ports open (SSM uses outbound HTTPS)
  - Full session logging to CloudWatch/S3 for audit
  - Works through NAT (private subnet instances reachable)
"""

import argparse
import json
import os
import subprocess
import sys

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


def get_running_instances(asg_client, ec2_client, asg_name: str) -> list:
    """Get running instances in the ASG with their AZ and private IP."""
    resp = asg_client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
    if not resp["AutoScalingGroups"]:
        return []

    instance_ids = [
        inst["InstanceId"]
        for inst in resp["AutoScalingGroups"][0]["Instances"]
        if inst["LifecycleState"] == "InService"
    ]

    if not instance_ids:
        return []

    ec2_resp = ec2_client.describe_instances(InstanceIds=instance_ids)
    instances = []
    for reservation in ec2_resp["Reservations"]:
        for inst in reservation["Instances"]:
            if inst["State"]["Name"] == "running":
                instances.append({
                    "id": inst["InstanceId"],
                    "az": inst["Placement"]["AvailabilityZone"],
                    "private_ip": inst.get("PrivateIpAddress", "N/A"),
                    "launch_time": inst["LaunchTime"].strftime("%Y-%m-%d %H:%M"),
                })

    return sorted(instances, key=lambda x: x["az"])


def main():
    parser = argparse.ArgumentParser(description="Connect to an AutoTier ASG instance via SSM.")
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--tf-dir", default=None)
    parser.add_argument(
        "--index", type=int, default=None,
        help="Directly connect to instance at this index (0-based). Skip the menu.",
    )
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tf_dir = args.tf_dir or os.path.join(project_root, "terraform")

    print("=" * 60)
    print("  AutoTier — SSM Connect")
    print("=" * 60)

    outputs = get_terraform_outputs(tf_dir)
    asg_name = outputs.get("asg_name")

    if not asg_name:
        print("\nERROR: Infrastructure not deployed. Run: make up")
        sys.exit(1)

    asg_client = boto3.client("autoscaling", region_name=args.region)
    ec2_client = boto3.client("ec2", region_name=args.region)

    print(f"\n  ASG: {asg_name}")
    print("  Discovering running instances...\n")

    instances = get_running_instances(asg_client, ec2_client, asg_name)

    if not instances:
        print("  ❌ No running instances found in the ASG.")
        sys.exit(1)

    # Display instance list
    print(f"  {'#':<4} {'Instance ID':<22} {'AZ':<25} {'Private IP':<16} {'Launched'}")
    print(f"  {'─' * 4} {'─' * 22} {'─' * 25} {'─' * 16} {'─' * 16}")
    for i, inst in enumerate(instances):
        print(f"  {i:<4} {inst['id']:<22} {inst['az']:<25} {inst['private_ip']:<16} {inst['launch_time']}")

    # Select instance
    if args.index is not None:
        idx = args.index
    else:
        print()
        try:
            idx = int(input(f"  Select instance [0-{len(instances)-1}]: ").strip())
        except (ValueError, KeyboardInterrupt):
            print("\n  Aborted.")
            sys.exit(0)

    if idx < 0 or idx >= len(instances):
        print(f"  ❌ Invalid index. Must be 0-{len(instances)-1}.")
        sys.exit(1)

    target = instances[idx]
    print(f"\n  🔗 Connecting to {target['id']} ({target['az']})...")
    print(f"     Via SSM Session Manager (no SSH, no keys, no port 22)")
    print(f"     Type 'exit' to disconnect.\n")

    # Start SSM session — hands control to the AWS CLI
    try:
        subprocess.run(
            ["aws", "ssm", "start-session", "--target", target["id"], "--region", args.region],
            check=True,
        )
    except FileNotFoundError:
        print("  ❌ AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html")
        sys.exit(1)
    except subprocess.CalledProcessError:
        print("  ❌ SSM session failed. Is the SSM agent running? Is the IAM role attached?")
        sys.exit(1)


if __name__ == "__main__":
    main()
