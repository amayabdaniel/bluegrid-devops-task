# SECURITY

This document covers the attack surface of the deployed service and the
CI/CD pipeline, the controls applied, and residual risks.

## TL;DR: what this system exposes

| Surface | Reachable from | How |
|---|---|---|
| TCP 777 on the EC2 host | Internet | Spring Boot `gs-rest-service`, `GET /greeting` only. |
| TCP 22 on the EC2 host | Your single `/32` | Key-only SSH, `deploy` user only. |
| AWS SSM Session Manager | Your AWS console / CLI | Default for human ops; no inbound port needed. |
| GitHub repository | Public | Code, Dockerfile, IaC, docs (no secrets). |
| GHCR `gs-rest-service` image | Internet | Public by default so the EC2 can pull anonymously. |
| Slack channels `#gs-rest-service-ci`, `#gs-rest-service-monitor` | Slack workspace members | Build + incident notifications. |

Everything else (app-internal `/actuator`, Docker daemon, the deploy IAM role,
the monitor's state file) is on non-routable loopback or behind IAM.

---

## Threat model (STRIDE)

One row per asset × STRIDE category. The `Control` column is the mechanism;
`Residual` lists what's left after the control.

| Asset | Threat (STRIDE) | Attack | Control | Residual |
|---|---|---|---|---|
| `gs-rest-service` on EC2 | **S**poofing | Attacker serves a lookalike on 777 | Public IP belongs to Amazon; user connects directly by IP/DNS | DNS spoofing of the operator's laptop (out of scope) |
| `/greeting` endpoint | **T**ampering | Crafted payload to trigger deserialization | Spring Boot 4.0.5 (latest); `server.error.include-*=never`; image scanned each build | A zero-day in Spring MVC |
| EC2 host | **R**epudiation | Operator claims a deploy wasn't them | Every deploy goes through SSM RunCommand, logged in CloudTrail with the IAM role session name tagged `gh-cd-<run_id>` | CloudTrail data-event coverage is opt-in |
| App logs / `/actuator/health` | **I**nformation disclosure | Leaked stack trace or env vars via `/actuator` | `management.server.address=127.0.0.1`, `show-details=never`, stacktrace suppressed | Log line contents if an operator greps loosely |
| EC2 host | **D**enial of service | Volumetric L3/L4 flood on :777 | Small blast radius (single t2.micro); AWS Shield Standard included; fail2ban on sshd | No WAF / no auto-scaling |
| Container | **E**levation of privilege | Escape from JVM to host | Non-root UID 10001; `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`; Docker daemon has `no-new-privileges`, `icc=false` | A kernel container-escape CVE |
| SSH | **S**poofing / **E**oP | Brute-force root or `ec2-user` | `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers deploy`, `MaxAuthTries 3`, fail2ban, ec2-user locked | Credential theft of operator's laptop |
| Deploy pipeline | **T**ampering | Malicious PR edits `.github/workflows/*` | Branch protection on master; required CI; CODEOWNERS on `.github/`; Dependabot + SHA-pinning on third-party actions | Insider with write access |
| Deploy pipeline | **S**poofing | A different repo assumes our deploy role | IAM OIDC trust conditioned on `token.actions.githubusercontent.com:sub` = `repo:OWNER/REPO:ref:refs/heads/master\|develop` | GitHub's OIDC provider compromise |
| Image supply chain | **T**ampering | Builder injects a backdoor | Multi-stage build, SBOM (SPDX) generated with Syft, image signed keylessly with Cosign via OIDC, SBOM attested to the image; Trivy **fails the build on any CRITICAL**; base image pinned per release | A CVE in Cosign or the Sigstore chain |
| Container image | **T**ampering | User pulls an old, vulnerable tag | Image tagged by Git SHA (`master-<sha>`) and referenced by digest on production host | Operator overriding with a wrong tag manually |
| Credentials | **I**nformation disclosure | Secret committed to Git | `.gitignore` covers `.env`, `*.pem`, `*.key`, `id_*`, `credentials`, `aws-credentials`, `.aws/`, `*.tfvars`; Gitleaks full-history scan in CI | Gitleaks misses a novel pattern |
| Monitor | **I**nformation disclosure | Monitor leaks target or Slack webhook in logs | Webhook passed via `EnvironmentFile=/etc/gs-rest-monitor.env` (mode 0640), not on argv; logs are JSON with no secret fields | Journald access by root |

---

## Controls applied (mapped to Task 5 requirements)

### EC2 network
- Security Group: **TCP 777 from 0.0.0.0/0**, **TCP 22 from `var.admin_cidr` (validated `/32`)**; all other inbound denied.
- Egress limited to HTTPS (443), DNS (UDP 53), NTP (UDP 123). No plain-HTTP or SMTP egress.
- IMDSv2 enforced (`http_tokens = required`, hop limit 1) — defence against SSRF → instance-credentials theft.

### EC2 access
- `PasswordAuthentication no`, `ChallengeResponseAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers deploy`, modern KEX/Cipher/MAC lists, `MaxAuthTries 3`, `ClientAliveInterval 300`.
- `deploy` user is a member of `docker` only — **no sudoers entry, no wheel**.
- `ec2-user` locked (`usermod -L`) and its `authorized_keys` emptied.
- fail2ban jail on sshd: 3 retries → 1 hour ban.
- `dnf-automatic.timer` enabled for daily security updates.

### Container
- Multi-stage build: separate build → jlinked JRE (≈65 MB) → Alpine runtime.
- Non-root UID 10001, `/sbin/nologin` shell.
- `tini` as PID 1 (correct signal handling).
- `HEALTHCHECK` hits `/actuator/health` on a loopback-only management port (8081).
- Image run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--memory`, `--pids-limit`, `--log-driver=json-file --log-opt max-size=10m --log-opt max-file=5`.
- Docker daemon hardened (`/etc/docker/daemon.json`: `no-new-privileges`, `icc=false`, `userland-proxy=false`, `live-restore`, log rotation).

### Secrets
- Nothing committed. `.gitignore` covers `.env`, `.env.*`, `*.pem`, `*.key`, `*.jks`, `id_rsa*`, `id_ed25519*`, `credentials`, `aws-credentials`, `.aws/`, `.docker/config.json`, `*.tfvars`, `secrets.yml`.
- CI uses GitHub Secrets only (`SLACK_BOT_TOKEN`) and repo Variables (`SLACK_*`, `AWS_DEPLOY_ROLE_ARN`, `AWS_INSTANCE_ID`, `PUBLIC_SERVICE_URL`).
- **Zero static AWS credentials** in CI: deploy role assumed via OIDC, trust scoped to `repo:OWNER/REPO:ref:refs/heads/master|develop`.
- Gitleaks full-history scan runs on every CI build.

### Dependency scanning
- Trivy scans the built image and **exits 1 on any CRITICAL** — pipeline fails.
- Results also exported as SARIF and uploaded to the GitHub Security tab.
- Checkov runs against the Terraform configuration (60 passed, 0 failed, 3 explicitly skipped with justification for intentional design constraints).
- Hadolint lints the Dockerfile (warning threshold).
- Dependabot watches Actions (SHA-pinned), Maven, Docker, pip, and Terraform deps weekly.

### Supply chain
- All third-party GitHub Actions pinned to commit SHA with the version in a comment (Trivy, Slack, Hadolint, Gitleaks, Syft, Cosign, JUnit reporter, Harden-Runner, aws-actions/configure-aws-credentials). **This is non-negotiable after the March 2026 `aquasecurity/trivy-action` compromise.**
- First-party `actions/*` pinned to major tag per GitHub's own guidance.
- `step-security/harden-runner` in audit mode on every job to build an egress allowlist over time.
- Image signed keylessly with Cosign using the GitHub OIDC token; SBOM attested to the image digest.

### Runner / CI
- Per-job least-privilege `permissions:` blocks. Workflow default is `contents: read`.
- `id-token: write` only on the image-build and deploy jobs.
- `packages: write` only on the image-build job.
- `concurrency:` cancels superseded runs (CI) and refuses to cancel in-flight deploys (CD).
- `timeout-minutes` on every job.

---

## Residual risks and the one-line mitigation I'd ship if this were production

1. **No WAF / L7 rate limiting.** A single t2.micro can be knocked over by ~5k rps.
   *Mitigation:* put the service behind an ALB + AWS WAF with a default rate rule, or Cloudflare in front. ~$18/month for WAF.
2. **No intrusion detection on the host.** fail2ban catches sshd brute force but nothing else.
   *Mitigation:* enable AWS GuardDuty (first 30 days free, then ~$0.70/M CloudTrail events for this scale).
3. **No mTLS between the monitor and the service.** The monitor calls plain HTTP.
   *Mitigation:* terminate TLS at an ALB with an ACM cert (free for AWS-issued certs) and switch the monitor URL to `https://`.
4. **No log shipping off the host.** If the host is compromised, logs can be erased.
   *Mitigation:* CloudWatch Logs agent shipping journald + Docker stdout.
5. **The `deploy` user can run `docker run` with any image.** That's the stated privilege, but in a production blast-radius review I'd constrain `gs-deploy.sh` to a specific image prefix (`ghcr.io/OWNER/gs-rest-service:*`) and chmod 700 the script.
6. **IAM OIDC role max session duration is 1h.** If a deploy needs more, someone will be tempted to bump it — I'd refuse and instead shard the deploy into smaller steps.
7. **No branch protection programmatically enforced.** The repo needs a one-time setting to require PR review + passing CI before merge to master.

---

## Verification checklist (what to run before the defence call)

```bash
# Container
docker scout cves gs-rest-service:dev          # or:
trivy image --severity CRITICAL --exit-code 1 gs-rest-service:dev

# Dockerfile
hadolint --config .hadolint.yaml Dockerfile

# IaC
cd infra && terraform fmt -check -recursive && terraform validate && tflint --recursive && checkov -d .

# Secrets (full history)
gitleaks detect --source . --no-banner

# Workflows
actionlint .github/workflows/*.yml

# Monitor
cd monitor && ruff check . && pytest -q
```

If every one of those exits 0, the submission is defensible on security grounds.
