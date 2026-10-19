#!/usr/bin/env bash
# Exercise prove-trivy-gate.sh's decision logic without GitHub, network access,
# or Actions minutes.
#
# This exists because the proof script previously exited 0 whenever CI did not
# report "failure" — so "the gate blocked the build" was indistinguishable from
# "CI never finished" and from "CI passed a knowingly-vulnerable image". A proof
# that cannot fail proves nothing, so its decision table is itself under test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROVE_TRIVY_GATE_LIB_ONLY=1
export PROVE_TRIVY_GATE_LIB_ONLY
# shellcheck source=scripts/prove-trivy-gate.sh
. "$HERE/prove-trivy-gate.sh"

# Keep the poll instant; the delay is not what is under test.
sleep() { :; }

FAILURES=0

# Replay a scripted sequence of `gh` conclusions and assert the exit status.
expect_outcome() {
  local label="$1" want="$2"
  shift 2
  local -a replies=("$@")

  # await_gate calls fetch_conclusion inside $( ), i.e. a subshell, so an
  # in-memory cursor would be discarded after every call and the first reply
  # would replay forever. The cursor lives in a file to survive that.
  local cursor
  cursor="$(mktemp)"
  printf '0' >"$cursor"

  fetch_conclusion() {
    local i last
    i="$(cat "$cursor")"
    last=$(( ${#replies[@]} - 1 ))
    if [ "$i" -gt "$last" ]; then i="$last"; fi
    printf '%s' "${replies[$i]}"
    printf '%s' "$(( i + 1 ))" >"$cursor"
  }

  local got=0
  await_gate 3 0 >/dev/null 2>&1 || got=$?
  rm -f "$cursor"

  if [ "$got" = "$want" ]; then
    printf 'pass  %-46s exit=%s\n' "$label" "$got"
  else
    printf 'FAIL  %-46s exit=%s want=%s\n' "$label" "$got" "$want"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_outcome "CI failed -> gate fired"                "$EXIT_GATE_FIRED"        "failure"
expect_outcome "CI timed_out -> gate fired"             "$EXIT_GATE_FIRED"        "timed_out"
expect_outcome "no run yet, then failure -> gate fired" "$EXIT_GATE_FIRED"        "" "" "failure"
expect_outcome "CI PASSED -> gate did not block"        "$EXIT_GATE_DID_NOT_BLOCK" "success"
expect_outcome "CI cancelled -> inconclusive"           "$EXIT_INCONCLUSIVE"      "cancelled"
expect_outcome "never concludes -> inconclusive"        "$EXIT_INCONCLUSIVE"      ""

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES decision-table case(s) failed" >&2
  exit 1
fi
echo "all 6 decision-table cases pass"
