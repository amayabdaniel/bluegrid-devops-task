# CHAOS — prove the monitor actually works

A reviewer can look at the monitor code and *trust* it detects outages. It's
a lot stronger to **demonstrate** it. This is the exact sequence I run on
the defence call.

## The drill

```bash
# Terminal 1: tail the monitor logs on the monitor host
aws ssm start-session --target <monitor-instance-id>
journalctl -u gs-rest-monitor.service -f -o cat

# Terminal 2: tail the Slack channel (#gs-rest-service-monitor) in the browser

# Terminal 3: on the service host, kill the container
aws ssm start-session --target <service-instance-id>
docker kill gs-rest-service

# Watch:
#   - Terminal 1 prints `probe ok=false` for the next 2 polls,
#     then prints `transition from=UP to=DOWN`.
#   - Slack gets "🚨 <target> is DOWN (HTTP None)".
#   - Poll cadence backs off (15s -> 22s -> 33s -> ... capped at 120s).

# Still on the service host, restart:
sudo -u deploy /usr/local/bin/gs-deploy.sh ghcr.io/<owner>/gs-rest-service:master

# Watch:
#   - Terminal 1 prints `probe ok=true`, then `transition from=DOWN to=UP`.
#   - Slack gets "✅ <target> is UP (HTTP 200)".
#   - Poll cadence snaps back to 15s.
```

## Expected timing (tuned for a clean demo)

Monitor defaults are `--interval 15 --down-threshold 2 --up-threshold 2`, so:

- Detection latency (DOWN): ~30 s after the container dies.
- Notification latency: ~31 s (Slack post is <1 s).
- Recovery detection (UP): ~30 s after the container is healthy.
- Total drill length: ~90 s from kill to "UP" in Slack.

If you need a tighter demo, export `INTERVAL=5` in `/etc/gs-rest-monitor.env`
and `systemctl restart gs-rest-monitor.service` beforehand.

## What the log looks like

```
{"ts":"2026-04-22T10:10:00Z","event":"probe","target":"http://1.2.3.4:777/greeting","ok":true,"state":"UP","http_status":200,"latency_ms":12.3,"run_id":"2026-04-22-abc1234"}
{"ts":"2026-04-22T10:10:15Z","event":"probe","ok":false,"state":"UP","http_status":null,"latency_ms":3000.0, ...}
{"ts":"2026-04-22T10:10:30Z","event":"probe","ok":false,"state":"UP","http_status":null,"latency_ms":3000.0, ...}
{"ts":"2026-04-22T10:10:30Z","event":"transition","from_state":"UP","to_state":"DOWN","http_status":null,"target":"...", ...}
{"ts":"2026-04-22T10:11:22Z","event":"probe","ok":true,"state":"DOWN","http_status":200,"latency_ms":14.1, ...}
{"ts":"2026-04-22T10:11:37Z","event":"probe","ok":true,"state":"DOWN","http_status":200,"latency_ms":13.8, ...}
{"ts":"2026-04-22T10:11:37Z","event":"transition","from_state":"DOWN","to_state":"UP","http_status":200, ...}
```

## Prove the Trivy gate works

A second drill I'll run on the call if time allows:

```bash
# Add a known-vulnerable package to pom.xml temporarily, push to a branch.
# Open a draft PR targeting master.
# Watch the CI run -> `trivy image --severity CRITICAL --exit-code 1` fails the build.
# The PR cannot merge (branch protection + required check).
```

This turns the Trivy configuration into a *proven* control, not a configured one.
