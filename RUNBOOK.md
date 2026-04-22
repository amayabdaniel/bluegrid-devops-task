# RUNBOOK

Operational procedures for `gs-rest-service` on the demo EC2.

## 1. Is the service alive?

```bash
# from anywhere
curl -fsS http://<public-ip>:777/greeting

# from the host (via SSM Session Manager, no SSH required)
aws ssm start-session --target <instance-id>
docker ps --filter name=gs-rest-service
docker logs -n 50 gs-rest-service
```

## 2. Fresh deploy (normal path)

1. Push to `master`.
2. CI runs, builds, scans, signs, pushes to GHCR.
3. CD assumes the OIDC role, `aws ssm send-command` → `gs-deploy.sh`.
4. Smoke test hits `:777/greeting`.
5. Slack `#gs-rest-service-ci` gets a green message.

Track progress in the Actions tab; every step logs to the run.

## 3. Hot-fix deploy (manual)

```bash
# From your laptop with AWS creds and terraform state available
make deploy IMAGE=ghcr.io/amayabdaniel/gs-rest-service:master-<sha>
# Or, as last resort, via SSH:
scripts/deploy.sh ghcr.io/amayabdaniel/gs-rest-service:master-<sha>
```

`gs-deploy.sh` is idempotent: it kills the old container and smoke-tests the
new one. If the smoke test fails it exits non-zero; the old container is
already gone, so you either roll forward or fix fast.

## 4. Rollback

```bash
# Find the last known-good SHA from GHCR or from journalctl on the host
make deploy IMAGE=ghcr.io/amayabdaniel/gs-rest-service:master-<previous-sha>
```

The image tags are immutable (GHCR default) — rolling back is literally just
pointing at the previous tag.

## 5. Restart the monitor

```bash
aws ssm start-session --target <monitor-instance-id>
sudo systemctl restart gs-rest-monitor.service
journalctl -u gs-rest-monitor.service -n 50 -f
```

State is persisted in `/var/lib/gs-rest-monitor/state.json`; a restart
does **not** re-fire UP/DOWN transitions you've already been notified of.

## 6. Rotate the admin SSH key

```bash
ssh-keygen -t ed25519 -C bluegrid-demo -f ~/.ssh/bluegrid-v2
# Update infra/terraform.tfvars -> ssh_public_key = "ssh-ed25519 AAAA..."
make tf-apply
# user-data re-rewrites ~deploy/.ssh/authorized_keys atomically.
```

## 7. Rotate the AWS deploy role (after any suspected compromise)

```bash
# Recreate the role to force all OIDC federations to re-handshake
cd infra
terraform taint aws_iam_role.github_deploy
terraform apply
# Copy the new ARN into the GitHub repo variable AWS_DEPLOY_ROLE_ARN
```

## 8. Decommission (for the defence call cleanup)

```bash
make tf-destroy
# The GHCR image stays; delete it via the GitHub UI or `gh api` if you want a
# clean slate.
```

## 9. Common failures and their fixes

| Symptom | Where to look | Fix |
|---|---|---|
| CD job fails with `AccessDenied` on `ssm:SendCommand` | CloudTrail `AssumeRoleWithWebIdentity` events | Confirm the OIDC trust policy includes the current branch ref |
| `curl :777/greeting` returns 502/connection refused | `docker ps` on the host | Container is restarting. `docker logs` to find the cause; if OOM, raise `--memory` in `gs-deploy.sh` |
| CI Trivy gate fails on a new CRITICAL | Actions run log, Security tab | Bump the offending dependency (Dependabot may already have an open PR) |
| Monitor flaps on every poll | Host network or external firewall | Check `/var/lib/gs-rest-monitor/state.json`; check your ISP or home router |
| `terraform apply` wants to replace the EC2 | `user_data_replace_on_change = true` in `main.tf` | Intentional — user-data changes rebuild the host. If you don't want this, change it in `main.tf` |

## 10. On-call first five minutes

1. Look at `#gs-rest-service-monitor` for the last transition.
2. `curl -w '%{time_total}\n' :777/greeting` from your laptop — is it latency or availability?
3. `aws ssm start-session --target <instance-id>`; `docker ps`, `docker logs -n 200 gs-rest-service`.
4. If the container is healthy but external is down → Security Group or AWS reachability.
5. If the container is dead → `sudo -u deploy /usr/local/bin/gs-deploy.sh <last-known-good-image>` to roll back.
6. Post a timeline to `#gs-rest-service-ci` with timestamps as you go.
