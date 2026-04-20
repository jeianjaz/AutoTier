# Chaos Test Results

> **Status:** Placeholder — populated by `scripts/chaos_test.py` during Step 8.

## Format

Each run appends a row:

| Run # | Date (UTC) | Instance terminated | ASG replacement InService | MTTR (seconds) | Notes |
|-------|-----------|---------------------|----------------------------|----------------|-------|
| *example* | 2026-05-01 14:32 | i-0abc123 | 2026-05-01 14:33 | **47** | Baseline run |

## Methodology

1. `chaos_test.py` selects a random healthy EC2 in the ASG.
2. Records **T0** (UTC timestamp).
3. Calls `ec2.stop_instances` via boto3.
4. Polls the ASG + target group every 5 seconds.
5. Records **T1** when a replacement instance is `InService` and `healthy`.
6. **MTTR = T1 - T0.**
7. Appends a row to this file and prints result to stdout.

## Why this matters

"Self-healing infrastructure" is a claim. **"Recovery time: 47 seconds"** is
evidence. Every row in this file is a measured observation against a live
system — the gap between what engineers *say* their system does and what it
actually does.
