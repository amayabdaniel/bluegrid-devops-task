#!/usr/bin/env bash
# Install the monitor on any Linux host with systemd + Python 3.13.
# Run with sudo.
set -euo pipefail

INSTALL_DIR=/opt/gs-rest-monitor
STATE_DIR=/var/lib/gs-rest-monitor
ENV_FILE=/etc/gs-rest-monitor.env
SVC_FILE=/etc/systemd/system/gs-rest-monitor.service

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! id monitor >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin monitor
fi

mkdir -p "$INSTALL_DIR" "$STATE_DIR"

# Virtualenv + install package from source (stdlib-only at runtime)
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/python" -m pip install --upgrade pip >/dev/null
"$INSTALL_DIR/.venv/bin/python" -m pip install "$REPO_ROOT" >/dev/null
chown -R monitor:monitor "$INSTALL_DIR"

# Env file (don't overwrite if operator already customised)
if [ ! -f "$ENV_FILE" ]; then
  install -m 0640 -o root -g monitor "$REPO_ROOT/systemd/gs-rest-monitor.env.example" "$ENV_FILE"
  echo "NOTE: edit $ENV_FILE with your TARGET_URL and (optional) SLACK_WEBHOOK_URL"
fi

install -m 0644 "$REPO_ROOT/systemd/gs-rest-monitor.service" "$SVC_FILE"

systemctl daemon-reload
systemctl enable --now gs-rest-monitor.service

echo
echo "Installed. Tail logs with:"
echo "  journalctl -u gs-rest-monitor.service -f"
