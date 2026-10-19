#!/usr/bin/env bash
# Prove the CRITICAL-severity Trivy gate actually blocks a build.
#
# This opens a throwaway branch whose Dockerfile uses an ancient Alpine base
# known to carry CRITICAL CVEs, opens a PR, waits for CI to reach a terminal
# conclusion, then closes the PR and deletes the branch.
#
# Exit status is the result of the proof, not merely of the plumbing:
#   0  the gate fired  — CI failed, as a blocked build should
#   1  the gate DID NOT block — CI passed a knowingly-vulnerable base image
#   2  inconclusive — no terminal conclusion observed, so nothing was proven
#
# Requires: gh, git. Operates on the current repo.
set -euo pipefail

readonly EXIT_GATE_FIRED=0
readonly EXIT_GATE_DID_NOT_BLOCK=1
readonly EXIT_INCONCLUSIVE=2

BRANCH="${BRANCH:-demo/trivy-gate-$(date +%s)}"

# Indirected through a function so await_gate's decision logic can be exercised
# without GitHub, network access, or spending Actions minutes. See
# scripts/test-prove-trivy-gate.sh.
fetch_conclusion() {
  gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 \
    --json conclusion -q '.[0].conclusion // ""'
}

# Wait for a terminal CI conclusion and map it to a proof outcome.
#
# Every exit path is explicit. Previously this loop treated anything other than
# "failure" as uninteresting and fell through to exit 0, so "the gate blocked
# the build" was indistinguishable from "CI never finished" and — worse — from
# "CI passed a knowingly-CRITICAL image", which is precisely the failure this
# script exists to detect.
await_gate() {
  local attempts="${1:-30}" delay="${2:-15}" conclusion=""
  local i
  for ((i = 0; i < attempts; i++)); do
    conclusion="$(fetch_conclusion)"
    case "$conclusion" in
    failure | timed_out)
      echo "gate fired: CI concluded '$conclusion', so the build was blocked."
      return "$EXIT_GATE_FIRED"
      ;;
    success)
      echo "GATE DID NOT BLOCK: CI concluded 'success' on a base image carrying known CRITICAL CVEs." >&2
      return "$EXIT_GATE_DID_NOT_BLOCK"
      ;;
    cancelled | skipped | neutral | stale | action_required)
      echo "inconclusive: CI concluded '$conclusion'; the trivy step never decided." >&2
      return "$EXIT_INCONCLUSIVE"
      ;;
    "")
      : # no run registered yet, keep waiting
      ;;
    *)
      echo "note: unrecognised conclusion '$conclusion', continuing to poll" >&2
      ;;
    esac
    sleep "$delay"
  done
  echo "inconclusive: no terminal CI conclusion after $((attempts * delay))s; nothing was proven." >&2
  return "$EXIT_INCONCLUSIVE"
}

# Reached via `trap` and via the guard at the bottom of this file, neither of
# which static analysis follows.
# shellcheck disable=SC2329
cleanup() {
  git checkout - >/dev/null 2>&1 || true
  gh pr close --delete-branch "$BRANCH" --comment "demo complete" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true
}

# shellcheck disable=SC2329
main() {
  trap cleanup EXIT

  git checkout -b "$BRANCH"

  sed -i.bak -E 's/^ARG ALPINE_VERSION=.*/ARG ALPINE_VERSION=3.10/' Dockerfile
  rm -f Dockerfile.bak
  grep ALPINE_VERSION Dockerfile | head -2

  git add Dockerfile
  git -c user.email="$(git config user.email || echo demo@local)" \
    -c user.name="$(git config user.name || echo demo)" \
    commit -q -m "demo: alpine:3.10 to trigger trivy critical gate"
  git push -u origin "$BRANCH"

  gh pr create --base master --head "$BRANCH" \
    --title "demo: trivy gate" \
    --body "Intentionally vulnerable base image. Expect CI to fail at the trivy critical step."

  echo "waiting for the trivy step to decide..."
  local status=0
  await_gate || status=$?

  gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 || true

  case "$status" in
  "$EXIT_GATE_FIRED") echo "PROOF: the CRITICAL trivy gate blocks a vulnerable build." ;;
  "$EXIT_GATE_DID_NOT_BLOCK") echo "PROOF FAILED: the gate is not blocking. Treat the pipeline as unguarded." >&2 ;;
  *) echo "PROOF INCONCLUSIVE: re-run before claiming the gate works." >&2 ;;
  esac

  return "$status"
}

# Sourcing with PROVE_TRIVY_GATE_LIB_ONLY=1 loads the functions above and runs
# nothing else, so the decision logic is testable without GitHub or CI minutes.
if [ "${PROVE_TRIVY_GATE_LIB_ONLY:-0}" != "1" ]; then
  main "$@"
fi
