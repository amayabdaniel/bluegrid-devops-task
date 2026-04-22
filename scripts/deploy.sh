#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <image-ref> [host] [user=deploy]" >&2
  exit 64
}

IMAGE="${1:-}"; HOST="${2:-}"; USERNAME="${3:-deploy}"
[ -z "$IMAGE" ] && usage

if [ -z "$HOST" ] && command -v terraform >/dev/null 2>&1; then
  HOST="$(terraform -chdir=infra output -raw public_dns 2>/dev/null || true)"
fi
[ -z "$HOST" ] && usage

ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$USERNAME@$HOST" \
    "/usr/local/bin/gs-deploy.sh '$IMAGE' 8080 777"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if body=$(curl -fsS --max-time 5 "http://$HOST:777/greeting"); then
    echo "$body"
    exit 0
  fi
  sleep 3
done
echo "smoke test failed" >&2
exit 1
