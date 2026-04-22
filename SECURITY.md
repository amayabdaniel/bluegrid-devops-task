# Security

Attack surface, applied controls, and known residual risks.

## Exposed surfaces

| Surface | Reachable from | How |
|---|---|---|
| TCP 777 on the EC2 host | Internet | Spring Boot `gs-rest-service`, `GET /greeting` only |
| TCP 22 on the EC2 host | Your single /32 | Key-only SSH, `deploy` user only |
| AWS SSM Session Manager | Your AWS console/CLI | Default for human ops, no inbound port |
| GitHub repository | Public | Code, Dockerfile, IaC, docs (no secrets) |
| GHCR image | Internet | Public so EC2 can pull anonymously |

Everything else (app-internal `/actuator`, Docker daemon, the deploy IAM role, the monitor's state file) is on loopback or behind IAM.

## STRIDE

One row per asset x STRIDE category.

| Asset | Threat | Attack | Control | Residual |
|---|---|---|---|---|
| `gs-rest-service` on EC2 | Spoofing | Lookalike on 777 | Public IP is Amazon, users connect by IP/DNS | DNS spoofing on the operator's laptop |
| `/greeting` endpoint | Tampering | Crafted payload / deserialization | Spring Boot 4.0.5, `server.error.include-*=never`, image scanned per build | Zero-day in Spring MVC |
| EC2 host | Repudiation | Operator denies the deploy | SSM RunCommand, CloudTrail logs session tagged `gh-cd-<run_id>` | CloudTrail data-event coverage is opt-in |
| App logs | Information disclosure | Leaked stack trace or env vars | `management.server.address=127.0.0.1`, `show-details=never`, stacktrace suppressed | Log-line content if grep is loose |
| EC2 host | DoS | Volumetric flood on :777 | Single t2.micro, Shield Standard included, fail2ban on sshd | No WAF |
| Container | EoP | Escape JVM to host | Non-root UID 10001, `--read-only`, `--cap-drop=ALL`, `no-new-privileges`, daemon `icc=false` | Kernel container-escape CVE |
| SSH | Spoofing / EoP | Brute force root or ec2-user | `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers deploy`, `MaxAuthTries 3`, fail2ban, ec2-user locked | Operator laptop credential theft |
| Deploy pipeline | Tampering | Malicious PR to `.github/workflows/*` | Branch protection, required CI, CODEOWNERS on `.github/`, Dependabot + SHA pins | Insider with write access |
| Deploy pipeline | Spoofing | Another repo assumes our role | OIDC trust conditioned on `sub = repo:OWNER/REPO:ref:refs/heads/master\|develop` | GitHub OIDC provider compromise |
| Image supply chain | Tampering | Backdoor in build | Multi-stage build, SBOM (SPDX) via Syft, Cosign keyless sign via OIDC, SBOM attested to digest, Trivy fails on CRITICAL, base image pinned per release | CVE in Cosign or Sigstore |
| Container image | Tampering | Old vulnerable tag | Tagged by git sha (`master-<sha>`), host references digest | Operator overriding with wrong tag |
| Credentials | Information disclosure | Secret committed | `.gitignore` covers `.env`, `*.pem`, `*.key`, `id_*`, `credentials`, `aws-credentials`, `.aws/`, `*.tfvars`; Gitleaks full-history scan | Gitleaks misses a novel pattern |
| Monitor | Information disclosure | Leaks target or Slack webhook | Webhook via `EnvironmentFile=/etc/gs-rest-monitor.env` (0640), not argv, logs are JSON | Journald access by root |

## Controls

### EC2 network
- SG: TCP 777 from 0.0.0.0/0, TCP 22 from `var.admin_cidr` (/32 validated), all other inbound denied.
- Egress: HTTPS, DNS, NTP only. No plain HTTP or SMTP egress.
- IMDSv2 required, hop limit 1. Defends SSRF to instance-credentials theft.

### EC2 access
- `PasswordAuthentication no`, `ChallengeResponseAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers deploy`, modern KEX/Cipher/MAC, `MaxAuthTries 3`, `ClientAliveInterval 300`.
- `deploy` is in `docker` only. No sudoers entry. No wheel.
- `ec2-user` locked (`usermod -L`), `authorized_keys` emptied.
- fail2ban jail on sshd: 3 retries -> 1h ban.
- `dnf-automatic.timer` enabled for daily security updates.

### Container
- Multi-stage build: build -> jlinked JRE (~65 mb) -> Alpine runtime.
- Non-root UID 10001, `/sbin/nologin` shell.
- `tini` as PID 1.
- HEALTHCHECK hits `/actuator/health` on loopback-only management port 8081.
- Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--memory`, `--pids-limit`, `--log-driver=json-file` with rotation.
- Docker daemon: `no-new-privileges`, `icc=false`, `userland-proxy=false`, `live-restore`, log rotation.

### Secrets
- Nothing committed. `.gitignore` covers `.env`, `.env.*`, `*.pem`, `*.key`, `*.jks`, `id_rsa*`, `id_ed25519*`, `credentials`, `aws-credentials`, `.aws/`, `.docker/config.json`, `*.tfvars`, `secrets.yml`.
- CI uses GitHub Secrets only (`SLACK_BOT_TOKEN` if Slack is enabled) and repo Variables (`SLACK_*`, `AWS_DEPLOY_ROLE_ARN`, `AWS_INSTANCE_ID`, `PUBLIC_SERVICE_URL`).
- No static AWS creds in CI. Deploy role assumed via OIDC, trust scoped to `repo:OWNER/REPO:ref:refs/heads/master|develop`.
- Gitleaks full-history scan runs on every CI build.

### Dependency scanning
- Trivy scans the built image and exits 1 on any CRITICAL. Pipeline fails.
- Results uploaded as SARIF to GitHub Security tab.
- Checkov runs against Terraform (60 passed, 0 failed, 3 skipped with justification).
- Hadolint lints the Dockerfile (warning threshold).
- Dependabot watches Actions (SHA-pinned), Maven, Docker, pip, Terraform weekly.

### Supply chain
- All third-party GitHub Actions pinned to commit SHA with the version in a comment (Trivy, Slack, Hadolint, Gitleaks, Syft, Cosign, JUnit reporter, Harden-Runner, `aws-actions/configure-aws-credentials`).
- First-party `actions/*` pinned to major tag.
- `step-security/harden-runner` in audit mode on every job.
- Image signed keylessly with Cosign via GitHub OIDC token, SBOM attested to image digest.

### Runner / CI
- Per-job least-privilege `permissions:`. Workflow default `contents: read`.
- `id-token: write` only on image-build and deploy jobs.
- `packages: write` only on image-build.
- `concurrency:` cancels superseded CI runs, refuses to cancel in-flight deploys.
- `timeout-minutes` on every job.

## Residual risks

1. No WAF or L7 rate limiting. A single t2.micro can be knocked over by ~5k rps. Fix: ALB + AWS WAF or Cloudflare in front.
2. No IDS on the host beyond fail2ban. Fix: GuardDuty.
3. No mTLS. Monitor uses plain HTTP. Fix: terminate TLS at ALB with ACM.
4. No off-host log shipping. If host is compromised, logs can be erased. Fix: CloudWatch Logs agent.
5. `deploy` user can `docker run` any image. Production would constrain `gs-deploy.sh` to `ghcr.io/OWNER/gs-rest-service:*`.
6. IAM OIDC role max session 1h. Keep it there.
7. Branch protection requires status checks but admin can bypass (enforce_admins=false). Fine for this demo; production would set enforce_admins=true plus a break-glass IAM role.
8. The monitor itself is a single point of failure: if its host dies, DOWN events are missed silently. Fix: run a second monitor on a different AZ / machine, and alert on stale heartbeat from either (a dead-man's switch).
9. Terraform state is local. On a team this should be an S3 backend with DynamoDB locking. The `backend "s3"` stanza in `versions.tf` is commented out and ready to enable.
10. The Trivy gate is configured but not proven against a real failure. `scripts/prove-trivy-gate.sh` runs the end-to-end proof.

## Verification

```bash
trivy image --severity CRITICAL --exit-code 1 gs-rest-service:dev
hadolint --config .hadolint.yaml Dockerfile
cd infra && terraform fmt -check -recursive && terraform validate && tflint --recursive && checkov -d .
gitleaks detect --source . --no-banner
actionlint .github/workflows/*.yml
```
