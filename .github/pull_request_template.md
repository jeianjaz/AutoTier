<!-- Delete sections that don't apply. Keep the template focused. -->

## Context

<!-- What problem does this PR solve? Link to an issue or ADR if applicable. -->

## Changes

<!-- Bullet list of what changed. Be specific. -->
-
-

## Testing

<!-- How did you verify this works? -->
- [ ] `make validate` passes (`terraform fmt` + `terraform validate`)
- [ ] `make plan` shows only the expected changes
- [ ] `make checkov` has no new HIGH/CRITICAL findings
- [ ] Manual test: <describe>

## Rollback

<!-- How do we undo this if it breaks production? -->
`git revert <merge-commit-sha>` and `terraform apply`, or
`terraform destroy` of the new resources.

## Related ADRs

<!-- Which architecture decisions back this PR? -->
- ADR-00X: <title>

## Checklist

- [ ] Commit messages follow conventional format (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`)
- [ ] Resources are tagged with `Project`, `Environment`, `ManagedBy`
- [ ] No secrets, keys, or `*.tfvars` committed
- [ ] Documentation updated (README / runbook / ADR) if behavior changed
