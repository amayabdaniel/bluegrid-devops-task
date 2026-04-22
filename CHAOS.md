# Chaos drill

Prove the monitor detects outages and recoveries.

## Steps

```bash
# terminal 1: tail monitor logs
aws ssm start-session --target <monitor-instance-id>
journalctl -u gs-rest-monitor.service -f -o cat

# terminal 2: watch #gs-rest-service-monitor (if slack enabled)

# terminal 3: kill the container on the service host
aws ssm start-session --target <service-instance-id>
docker kill gs-rest-service

# expect:
#   - `probe ok=false` for a couple of polls
#   - `transition from=UP to=DOWN`
#   - poll cadence backs off (15s -> 22s -> 33s -> ..., capped at 120s)

# restore:
sudo -u deploy /usr/local/bin/gs-deploy.sh ghcr.io/amayabdaniel/gs-rest-service:master

# expect:
#   - `probe ok=true`, then `transition from=DOWN to=UP`
#   - poll cadence snaps back to the steady interval
```

## Timing (default settings)

`--interval 15 --down-threshold 2 --up-threshold 2`:

- DOWN detection: ~30s after container dies
- Notification: ~31s (slack is <1s)
- UP detection: ~30s after container is healthy
- Total drill: ~90s

For a tighter demo: `INTERVAL=5` in `/etc/gs-rest-monitor.env`, `systemctl restart gs-rest-monitor.service`.

## Log sample

```
{"ts":"2026-04-22T10:10:00Z","event":"probe","target":"http://1.2.3.4:777/greeting","ok":true,"state":"UP","http_status":200,"latency_ms":12.3}
{"ts":"2026-04-22T10:10:15Z","event":"probe","ok":false,"state":"UP","http_status":null,"latency_ms":3000.0}
{"ts":"2026-04-22T10:10:30Z","event":"probe","ok":false,"state":"UP","http_status":null,"latency_ms":3000.0}
{"ts":"2026-04-22T10:10:30Z","event":"transition","from_state":"UP","to_state":"DOWN","http_status":null}
{"ts":"2026-04-22T10:11:22Z","event":"probe","ok":true,"state":"DOWN","http_status":200,"latency_ms":14.1}
{"ts":"2026-04-22T10:11:37Z","event":"probe","ok":true,"state":"DOWN","http_status":200,"latency_ms":13.8}
{"ts":"2026-04-22T10:11:37Z","event":"transition","from_state":"DOWN","to_state":"UP","http_status":200}
```

## Trivy gate drill

```bash
# Add a known-vulnerable package, push to a branch, open a draft PR to master.
# The CI run fails at `trivy image --severity CRITICAL --exit-code 1`.
# Branch protection blocks merge.
```

Proves the gate, not just its config.
