#!/usr/bin/env bash
# Local fallback deployment script.
#
# The CD path is GitHub Actions -> OIDC -> SSM RunCommand -> the host.
# This script is the manual escape hatch for when:
#   - GitHub Actions is down
#   - You're testing a new image without pushing to master
#   - You're rebuilding the host from scratch
#
# Usage:
#   scripts/deploy.sh <image-ref> [host=ec2-...amazonaws.com] [user=deploy]
#
# Example:
#   scripts/deploy.sh ghcr.io/amayabdaniel/gs-rest-service:master \
#                     ec2-1-2-3-4.compute-1.amazonaws.com
#
# Requires:
#   - SSH key configured for the deploy user on the target host
#   - The host already provisioned by `terraform apply` in infra/
#
set -euo pipefail

usage() {
  echo "usage: $0 <image-ref> [host] [user=deploy]" >&2
  echo "  e.g.: $0 ghcr.io/amayabdaniel/gs-rest-service:master ec2-1-2-3-4.compute-1.amazonaws.com" >&2
  exit 64
}

IMAGE="${1:-}"; HOST="${2:-}"; USERNAME="${3:-deploy}"
[ -z "$IMAGE" ] && usage

# Resolve host from terraform output if not supplied
if [ -z "$HOST" ] && command -v terraform >/dev/null 2>&1; then
  HOST="$(terraform -chdir=infra output -raw public_dns 2>/dev/null || true)"
fi
[ -z "$HOST" ] && { echo "no host given and 'terraform output public_dns' is empty" >&2; usage; }

echo "[deploy] image=$IMAGE host=$USERNAME@$HOST"

ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$USERNAME@$HOST" \
    "/usr/local/bin/gs-deploy.sh '$IMAGE' 8080 777"

# Smoke-test from the operator's machine
echo "[deploy] smoke-testing http://$HOST:777/greeting"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if body=$(curl -fsS --max-time 5 "http://$HOST:777/greeting"); then
    echo "[deploy] OK: $body"
    exit 0
  fi
  sleep 3
done
echo "[deploy] smoke test FAILED" >&2
exit 1
