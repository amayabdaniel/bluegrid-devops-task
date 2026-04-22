## What
<!-- One-paragraph summary of the change -->

## Why
<!-- Motivation, ticket, or context -->

## How
<!-- Key implementation choices, tradeoffs, anything reviewers should look at first -->

## Risk & rollback
- Blast radius:
- How to roll back:

## Checklist
- [ ] Tests added or updated (or n/a)
- [ ] Docs updated (`README.md`, `RUNBOOK.md`, `SECURITY.md`) if behaviour changed
- [ ] No secrets, tokens, or credentials committed
- [ ] Image still passes Trivy (no new CRITICAL findings)
- [ ] Hadolint and Gitleaks pass locally
- [ ] If touching IaC: `terraform plan` reviewed and attached
