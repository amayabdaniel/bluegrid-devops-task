#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
gs-rest-service availability monitor.

Polls <target>/greeting, tracks UP/DOWN transitions, logs structured JSON,
and (optionally) notifies a Slack channel via an incoming webhook.

Design choices worth calling out on the defence call
----------------------------------------------------
- Stdlib-only core. Only external dep is `urllib3`-via-`requests` for Slack,
  and even that is replaceable with urllib. This keeps the attack surface tiny
  and deploy trivial (just systemd + a venv).
- State is persisted to disk (atomic rename) so a crash/restart does NOT
  re-fire a "recovered" alert that was already delivered.
- Each poll records HTTP status + latency, so we get more than binary up/down:
  p50/p95 over a sliding window are logged every N polls.
- Exponential backoff with jitter while DOWN so we don't hammer a wounded
  server; resets to the steady interval on recovery.
- Signal handling: SIGTERM triggers a graceful shutdown with a final log line,
  so systemd doesn't think we crashed.
- "Flap dampening": a transition is only confirmed after N consecutive polls
  in the new state. Defends against one-off network blips becoming pages.

Wire format of the structured log line (one per poll)
-----------------------------------------------------
{
  "ts":"2026-04-22T10:00:00Z",
  "event":"probe",            # or "transition", "summary", "startup", "shutdown"
  "target":"http://host:777/greeting",
  "ok":true,                  # per-poll result
  "state":"UP",               # confirmed state
  "http_status":200,
  "latency_ms":12.3,
  "run_id":"2026-04-22-abc1234"
}
"""

from __future__ import annotations

import argparse
import contextlib
import json
import logging
import os
import random
import signal
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from collections import deque
from dataclasses import asdict, dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

UP = "UP"
DOWN = "DOWN"
UNKNOWN = "UNKNOWN"


@dataclass
class Config:
    target: str
    interval_s: float = 15.0
    timeout_s: float = 3.0
    down_threshold: int = 2     # consecutive bad polls before declaring DOWN
    up_threshold: int = 2       # consecutive good polls before declaring UP
    max_backoff_s: float = 120.0
    window_size: int = 40       # latency sliding window
    summary_every: int = 20     # emit a "summary" event every N polls
    state_file: Path = field(default_factory=lambda: Path("state.json"))
    slack_webhook: str | None = None
    slack_channel_hint: str | None = "gs-rest-service-monitor"
    run_id: str = field(default_factory=lambda: f"{time.strftime('%Y-%m-%d')}-{uuid.uuid4().hex[:7]}")
    hostname: str = field(default_factory=socket.gethostname)


@dataclass
class State:
    state: str = UNKNOWN
    consecutive_bad: int = 0
    consecutive_good: int = 0
    last_transition_ts: str | None = None
    last_http_status: int | None = None


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def pct(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return round(s[k], 2)


def log_event(**kv) -> None:
    kv.setdefault("ts", iso_now())
    sys.stdout.write(json.dumps(kv, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def atomic_write(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, path)
    except Exception:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def load_state(path: Path) -> State:
    if not path.exists():
        return State()
    try:
        raw = json.loads(path.read_text())
        fields = (
            "state",
            "consecutive_bad",
            "consecutive_good",
            "last_transition_ts",
            "last_http_status",
        )
        return State(**{k: raw.get(k) for k in fields})
    except Exception as e:  # corrupt state is never fatal
        log_event(event="state_reset", reason=str(e))
        return State()


def save_state(path: Path, st: State) -> None:
    atomic_write(path, json.dumps(asdict(st), indent=2))


# ---------------------------------------------------------------------------
# Probing
# ---------------------------------------------------------------------------

def probe(target: str, timeout_s: float) -> tuple[bool, int | None, float]:
    """Return (ok, http_status, latency_ms)."""
    start = time.perf_counter()
    try:
        req = urllib.request.Request(target, headers={"User-Agent": "gs-rest-monitor/0.1"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:  # noqa: S310 (we do want http)
            status = resp.getcode()
            body = resp.read(4096)
            ok = status == 200 and b'"content"' in body
    except urllib.error.HTTPError as e:
        status, ok = e.code, False
    except (urllib.error.URLError, TimeoutError, OSError):
        status, ok = None, False
    latency_ms = round((time.perf_counter() - start) * 1000.0, 2)
    return ok, status, latency_ms


# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------

def slack_notify(webhook: str, text: str) -> None:
    """POST a minimal JSON payload to an incoming webhook. Never raises."""
    data = json.dumps({"text": text}).encode("utf-8")
    try:
        req = urllib.request.Request(
            webhook,
            data=data,
            headers={"Content-Type": "application/json", "User-Agent": "gs-rest-monitor/0.1"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:  # noqa: S310
            resp.read()
    except Exception as e:  # delivery best-effort; never crash the monitor
        log_event(event="slack_error", error=str(e))


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

_SHUTDOWN = False


def _on_signal(signum, _frame):  # pragma: no cover (wired via signal)
    global _SHUTDOWN
    _SHUTDOWN = True
    log_event(event="signal", signum=int(signum))


def run(cfg: Config) -> int:
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

    st = load_state(cfg.state_file)
    latencies: deque[float] = deque(maxlen=cfg.window_size)
    backoff = cfg.interval_s
    polls_since_summary = 0

    log_event(
        event="startup",
        target=cfg.target,
        run_id=cfg.run_id,
        state=st.state,
        host=cfg.hostname,
    )

    while not _SHUTDOWN:
        ok, http_status, latency_ms = probe(cfg.target, cfg.timeout_s)
        latencies.append(latency_ms)
        polls_since_summary += 1

        # Update flap-dampened counters
        if ok:
            st.consecutive_good += 1
            st.consecutive_bad = 0
        else:
            st.consecutive_bad += 1
            st.consecutive_good = 0

        # Per-poll structured log
        log_event(
            event="probe",
            target=cfg.target,
            ok=ok,
            state=st.state,
            http_status=http_status,
            latency_ms=latency_ms,
            run_id=cfg.run_id,
        )

        # Transition detection
        new_state = st.state
        if st.state != DOWN and st.consecutive_bad >= cfg.down_threshold:
            new_state = DOWN
        elif st.state != UP and st.consecutive_good >= cfg.up_threshold:
            new_state = UP

        if new_state != st.state:
            prev = st.state
            st.state = new_state
            st.last_transition_ts = iso_now()
            st.last_http_status = http_status
            save_state(cfg.state_file, st)

            log_event(
                event="transition",
                from_state=prev,
                to_state=new_state,
                http_status=http_status,
                target=cfg.target,
                run_id=cfg.run_id,
            )

            if cfg.slack_webhook:
                emoji = ":white_check_mark:" if new_state == UP else ":rotating_light:"
                status_txt = f" (HTTP {http_status})" if http_status is not None else ""
                slack_notify(
                    cfg.slack_webhook,
                    f"{emoji} *{cfg.target}* is *{new_state}*{status_txt} — host `{cfg.hostname}`",
                )

        # Periodic summary
        if polls_since_summary >= cfg.summary_every:
            log_event(
                event="summary",
                target=cfg.target,
                state=st.state,
                window=len(latencies),
                p50_ms=pct(list(latencies), 50),
                p95_ms=pct(list(latencies), 95),
                run_id=cfg.run_id,
            )
            polls_since_summary = 0

        # Pacing: exponential backoff while DOWN, steady interval while UP
        if st.state == DOWN:
            backoff = min(cfg.max_backoff_s, backoff * 1.5)
            sleep_s = backoff + random.uniform(0, backoff * 0.1)
        else:
            backoff = cfg.interval_s
            sleep_s = cfg.interval_s

        # Interruptible sleep
        slept = 0.0
        while slept < sleep_s and not _SHUTDOWN:
            chunk = min(0.5, sleep_s - slept)
            time.sleep(chunk)
            slept += chunk

    log_event(event="shutdown", state=st.state, run_id=cfg.run_id)
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str]) -> Config:
    p = argparse.ArgumentParser(description="gs-rest-service availability monitor")
    p.add_argument("--target", required=True, help="URL to probe, e.g. http://1.2.3.4:777/greeting")
    p.add_argument("--interval", type=float, default=15.0, dest="interval_s")
    p.add_argument("--timeout", type=float, default=3.0, dest="timeout_s")
    p.add_argument("--down-threshold", type=int, default=2)
    p.add_argument("--up-threshold", type=int, default=2)
    p.add_argument("--max-backoff", type=float, default=120.0, dest="max_backoff_s")
    p.add_argument("--state-file", type=Path, default=Path("/var/lib/gs-rest-monitor/state.json"))
    p.add_argument(
        "--slack-webhook",
        default=os.environ.get("SLACK_WEBHOOK_URL"),
        help="Defaults to $SLACK_WEBHOOK_URL. Omit entirely to disable Slack.",
    )
    args = p.parse_args(argv)
    return Config(
        target=args.target,
        interval_s=args.interval_s,
        timeout_s=args.timeout_s,
        down_threshold=args.down_threshold,
        up_threshold=args.up_threshold,
        max_backoff_s=args.max_backoff_s,
        state_file=args.state_file,
        slack_webhook=args.slack_webhook,
    )


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO)  # for future non-json lib logs
    cfg = parse_args(argv)
    return run(cfg)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
