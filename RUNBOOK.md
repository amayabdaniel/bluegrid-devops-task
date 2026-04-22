# Runbook

Operational procedures for `gs-rest-service`.

## 1. Is the service alive?

```bash
curl -fsS http://<public-ip>:777/greeting

# from the host via ssm
aws ssm start-session --target <instance-id>
docker ps --filter name=gs-rest-service
docker logs -n 50 gs-rest-service
```

## 2. Fresh deploy

1. Push to `master`.
2. CI runs: build, scan, sign, push to GHCR.
3. CD assumes OIDC role, `aws ssm send-command` runs `gs-deploy.sh` as `deploy`.
4. Smoke test hits `:777/greeting`.
5. Slack (if enabled) posts the result.

Track progress in the Actions tab.

## 3. Hot-fix deploy (manual)

```bash
make deploy IMAGE_REF=ghcr.io/amayabdaniel/gs-rest-service:master-<sha>
# ssh fallback:
scripts/deploy.sh ghcr.io/amayabdaniel/gs-rest-service:master-<sha>
```

`gs-deploy.sh` is idempotent: kills old container, smoke-tests new one.

## 4. Rollback

```bash
make deploy IMAGE_REF=ghcr.io/amayabdaniel/gs-rest-service:master-<previous-sha>
```

Tags are immutable on GHCR by default.

## 5. Restart the monitor

```bash
aws ssm start-session --target <monitor-instance-id>
sudo systemctl restart gs-rest-monitor.service
journalctl -u gs-rest-monitor.service -n 50 -f
```

State persisted in `/var/lib/gs-rest-monitor/state.json`; restart does not re-fire prior transitions.

## 6. Rotate admin SSH key

```bash
ssh-keygen -t ed25519 -C bluegrid-demo -f ~/.ssh/bluegrid-v2
# update infra/terraform.tfvars ssh_public_key
make tf-apply
```

User-data rewrites `~deploy/.ssh/authorized_keys` atomically.

## 7. Rotate AWS deploy role

```bash
cd infra
terraform taint aws_iam_role.github_deploy
terraform apply
# copy the new arn into repo variable AWS_DEPLOY_ROLE_ARN
```

## 8. Decommission

```bash
make tf-destroy
```

GHCR image stays. Delete via GitHub UI or `gh api`.

## 9. Common failures

| Symptom | Where to look | Fix |
|---|---|---|
| CD `AccessDenied` on `ssm:SendCommand` | CloudTrail `AssumeRoleWithWebIdentity` | Confirm OIDC trust policy includes the branch ref |
| `curl :777/greeting` 502 / refused | `docker ps` on host | Container restarting. `docker logs`. If OOM, raise `--memory` |
| CI Trivy gate fails on a new CRITICAL | Actions log, Security tab | Bump offending dependency (Dependabot may already have a PR) |
| Monitor flaps every poll | Host network / external firewall | Check `/var/lib/gs-rest-monitor/state.json`, ISP/router |
| `terraform apply` wants to replace the EC2 | `user_data_replace_on_change = true` | Intentional. Change in `main.tf` if unwanted |

## 10. On-call first five minutes

1. Look at `#gs-rest-service-monitor` (if Slack enabled) for the last transition.
2. `curl -w '%{time_total}\n' :777/greeting` from your laptop. Latency or availability?
3. `aws ssm start-session --target <instance-id>`; `docker ps`, `docker logs -n 200 gs-rest-service`.
4. If the container is healthy but external is down, SG or AWS reachability.
5. If the container is dead, roll back: `sudo -u deploy /usr/local/bin/gs-deploy.sh <last-known-good-image>`.
6. Post a timeline to the CI channel as you go.
