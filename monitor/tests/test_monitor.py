# SPDX-License-Identifier: Apache-2.0
"""Unit tests for the monitor — stdlib-only, no network."""

from __future__ import annotations

import http.server
import json
import socket
import threading
from pathlib import Path

import pytest

from gs_rest_monitor.monitor import (
    UP,
    Config,
    State,
    load_state,
    pct,
    probe,
    save_state,
)

# ---------- helpers -----------------------------------------------------------

def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _Handler(http.server.BaseHTTPRequestHandler):
    mode = "ok"

    def log_message(self, *a, **k):  # silence test noise
        return

    def do_GET(self):
        if _Handler.mode == "ok":
            body = json.dumps({"id": 1, "content": "Hello, World!"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif _Handler.mode == "500":
            self.send_error(500, "boom")
        elif _Handler.mode == "bad-body":
            body = b"{}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


@pytest.fixture
def http_server():
    port = _free_port()
    srv = http.server.HTTPServer(("127.0.0.1", port), _Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        yield f"http://127.0.0.1:{port}/greeting"
    finally:
        srv.shutdown()
        srv.server_close()


# ---------- pct ---------------------------------------------------------------

@pytest.mark.parametrize(
    ("vals", "p", "expected"),
    [
        ([], 50, 0.0),
        ([10.0], 50, 10.0),
        ([1.0, 2.0, 3.0, 4.0, 5.0], 50, 3.0),
        ([1.0, 2.0, 3.0, 4.0, 100.0], 95, 100.0),
    ],
)
def test_pct(vals, p, expected):
    assert pct(vals, p) == expected


# ---------- state round-trip --------------------------------------------------

def test_state_roundtrip(tmp_path: Path):
    p = tmp_path / "s" / "state.json"
    save_state(p, State(state=UP, consecutive_good=3, last_transition_ts="2026-04-22T00:00:00Z"))
    loaded = load_state(p)
    assert loaded.state == UP
    assert loaded.consecutive_good == 3
    assert loaded.last_transition_ts == "2026-04-22T00:00:00Z"


def test_corrupt_state_does_not_crash(tmp_path: Path):
    p = tmp_path / "state.json"
    p.write_text("{garbage")
    st = load_state(p)
    assert st.state == "UNKNOWN"


# ---------- probe (integration against a local HTTP server) -------------------

def test_probe_ok(http_server):
    _Handler.mode = "ok"
    ok, status, latency = probe(http_server, timeout_s=2.0)
    assert ok is True
    assert status == 200
    assert latency >= 0


def test_probe_500(http_server):
    _Handler.mode = "500"
    ok, status, _ = probe(http_server, timeout_s=2.0)
    assert ok is False
    assert status == 500


def test_probe_bad_body_is_not_ok(http_server):
    _Handler.mode = "bad-body"
    ok, status, _ = probe(http_server, timeout_s=2.0)
    assert ok is False
    assert status == 200


def test_probe_unreachable():
    ok, status, _ = probe("http://127.0.0.1:1/greeting", timeout_s=0.5)
    assert ok is False
    assert status is None


# ---------- Config sanity -----------------------------------------------------

def test_config_defaults_sane():
    cfg = Config(target="http://x/greeting")
    assert cfg.down_threshold >= 1
    assert cfg.up_threshold >= 1
    assert cfg.interval_s > 0
    assert cfg.max_backoff_s >= cfg.interval_s
