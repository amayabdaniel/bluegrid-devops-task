# gs-rest-monitor

> Availability monitor for `gs-rest-service`. Submitted as the second repo for
> the BlueGrid DevOps assessment.
> Main repo (app, infra, CI/CD, Segment B):
> <https://github.com/amayabdaniel/bluegrid-devops-task>

## What it does

Polls `<target>/greeting` on a cadence, tracks `UP`/`DOWN` transitions, logs
structured JSON to stdout, and — optionally — posts a Slack message on
every state change.

**Design points worth calling out:**

- **Stdlib-only runtime.** Zero third-party deps, so attack surface and
  install cost stay tiny. `monitor.py` + a venv + systemd is the whole
  install.
- **State is persisted to disk** (atomic rename). A crash/restart does NOT
  re-fire a "recovered" alert that was already delivered.
- **Latency tracking, not just up/down.** Each probe records HTTP status +
  latency; `summary` events log p50/p95 over a sliding window every N polls.
- **Flap dampening.** A transition is only confirmed after N consecutive
  probes in the new state. Defends against one-off network blips becoming
  pages.
- **Exponential backoff with jitter while DOWN** so we don't hammer a
  wounded server; resets to the steady interval on recovery.
- **Signal handling.** SIGTERM triggers a graceful shutdown with a final
  log line, so systemd doesn't think we crashed.

## Wire format

One JSON line per event to stdout:

```json
{"ts":"2026-04-22T10:00:00Z","event":"probe","target":"http://host:777/greeting","ok":true,"state":"UP","http_status":200,"latency_ms":12.3,"run_id":"2026-04-22-abc1234"}
{"ts":"2026-04-22T10:00:30Z","event":"transition","from_state":"UP","to_state":"DOWN","http_status":null,"target":"...","run_id":"..."}
{"ts":"2026-04-22T10:01:00Z","event":"summary","state":"DOWN","window":40,"p50_ms":12.3,"p95_ms":18.9,"run_id":"..."}
```

## Local run

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

# Run against a real target
python -m monitor.monitor \
  --target http://100.26.229.108:777/greeting \
  --interval 5 --timeout 3 --down-threshold 2 --up-threshold 2 \
  --state-file /tmp/state.json

# With Slack:
SLACK_WEBHOOK_URL=https://hooks.slack.com/... python -m monitor.monitor --target ...
```

## Install on a host (systemd, hardened unit)

```bash
sudo ./install.sh
$EDITOR /etc/gs-rest-monitor.env   # set TARGET_URL, INTERVAL, SLACK_WEBHOOK_URL
sudo systemctl restart gs-rest-monitor.service
journalctl -u gs-rest-monitor.service -f -o cat
```

The systemd unit runs with `NoNewPrivileges=yes`, `ProtectSystem=strict`,
`ProtectKernelTunables=yes`, `MemoryDenyWriteExecute=yes`, and a
`SystemCallFilter` allowlist. See `systemd/gs-rest-monitor.service`.

## Tests

```bash
pip install -e ".[dev]"
ruff check .
pytest -q        # 11 cases, no network, runs in <2s
```

CI runs both on every push and PR.

## Proof it actually works

Evidence from a live chaos drill against the service running on
`ec2-100-26-229-108.compute-1.amazonaws.com:777` is in the main repo:
<https://github.com/amayabdaniel/bluegrid-devops-task/blob/master/evidence/50-monitor-run.log>

Full `UP → DOWN → UP` cycle captured with timestamps.

## Configuration

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--target` | `TARGET_URL` | (required) | URL that returns `{"content":"..."}` |
| `--interval` | `INTERVAL` | `15` | Seconds between polls while `UP` |
| `--timeout` | — | `3` | HTTP timeout, seconds |
| `--down-threshold` | — | `2` | Consecutive bad probes before declaring DOWN |
| `--up-threshold` | — | `2` | Consecutive good probes before declaring UP |
| `--max-backoff` | — | `120` | Max seconds between polls while DOWN |
| `--state-file` | — | `/var/lib/gs-rest-monitor/state.json` | Persisted state path |
| `--slack-webhook` | `SLACK_WEBHOOK_URL` | unset | Omit to disable Slack entirely |

## License

Apache-2.0.
