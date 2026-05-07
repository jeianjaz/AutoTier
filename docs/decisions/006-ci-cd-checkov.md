# ADR-006 — GitHub Actions CI with Checkov over Manual Reviews

| Field   | Value              |
|---------|--------------------|
| Status  | Accepted           |
| Date    | 2026-05-07         |

## Context

Infrastructure-as-code changes can introduce security misconfigurations (open
security groups, unencrypted volumes, overly permissive IAM policies) or syntax
errors that only surface at `terraform apply` time. Manual code review alone
cannot reliably catch these issues at scale.

### Options considered

| Option | Pros | Cons |
|--------|------|------|
| **Manual review only** | Zero setup | Human error, no consistent baseline |
| **tflint** | Fast, HCL-aware | Limited security rules, no compliance frameworks |
| **Checkov + GitHub Actions** | 1000+ built-in policies, CIS/SOC2 mapping, free, runs in CI | Noisy on first scan (soft-fail initially) |
| **Terraform Cloud / Sentinel** | Policy-as-code, deep integration | Paid for team features, vendor lock-in |

## Decision

Use **GitHub Actions** with a three-job pipeline on every PR to `main`:

1. **Terraform Validate** — `terraform init -backend=false` → `fmt -check` → `validate`
2. **Checkov Security Scan** — scans all `.tf` files against 1000+ policies (soft-fail initially)
3. **Python Lint** — `py_compile` on all scripts to catch syntax errors

Checkov runs in `soft_fail: true` mode so it reports findings without blocking
merges initially. As we remediate findings, we can switch to hard-fail.

## Why this matters

- **Shift-left security:** Catch misconfigurations before they reach AWS, not after
- **Consistent baseline:** Every PR gets the same automated review regardless of reviewer fatigue
- **Audit trail:** GitHub Actions logs provide evidence of security scanning for compliance
- **Cost:** $0 — GitHub Actions free tier (2000 min/month) and Checkov is open-source

## Consequences

- PRs touching `terraform/` trigger the pipeline automatically
- Developers must run `terraform fmt` before pushing (or CI fails)
- Checkov findings appear in PR checks — team reviews and addresses them
- Branch protection rules require these checks to pass before merge
