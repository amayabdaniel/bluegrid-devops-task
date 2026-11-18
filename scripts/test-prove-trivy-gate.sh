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

# Replay a scripted sequence of `gh` conclusions and assert both the exit
# status and the number of polls before await_gate returned. The poll count
# is what distinguishes "classified immediately on a terminal conclusion"
# from "fell through to the unrecognised-value branch and polled out" —
# both return EXIT_INCONCLUSIVE, so without the count the two paths are
# indistinguishable and a sibling value dropped out of the terminal-case
# list would still look passing.
expect_outcome() {
  local label="$1" want_exit="$2" want_polls="$3"
  shift 3
  local -a replies=("$@")

  # await_gate calls fetch_conclusion inside $( ), i.e. a subshell, so an
  # in-memory cursor would be discarded after every call and the first reply
  # would replay forever. The cursor lives in a file to survive that, and
  # its final value is also the poll count.
  local cursor
  cursor="$(mktemp)"
  printf '0' >"$cursor"

  fetch_conclusion() {
    local i last clamped
    i="$(cat "$cursor")"
    last=$(( ${#replies[@]} - 1 ))
    # Clamp the index used to pick a reply (steady-state after the last
    # scripted value), but write the un-clamped count back so the cursor
    # is also an honest poll counter — otherwise a replies array of size
    # one makes the counter stick at 1 after the first call.
    clamped="$i"
    if [ "$clamped" -gt "$last" ]; then clamped="$last"; fi
    printf '%s' "${replies[$clamped]}"
    printf '%s' "$(( i + 1 ))" >"$cursor"
  }

  local got_exit=0
  await_gate 3 0 >/dev/null 2>&1 || got_exit=$?
  local got_polls
  got_polls="$(cat "$cursor")"
  rm -f "$cursor"

  if [ "$got_exit" = "$want_exit" ] && [ "$got_polls" = "$want_polls" ]; then
    printf 'pass  %-50s exit=%s polls=%s\n' "$label" "$got_exit" "$got_polls"
  else
    printf 'FAIL  %-50s exit=%s polls=%s want exit=%s polls=%s\n' \
      "$label" "$got_exit" "$got_polls" "$want_exit" "$want_polls"
    FAILURES=$((FAILURES + 1))
  fi
}

# Terminal FIRED and DID_NOT_BLOCK classify on first terminal reply.
expect_outcome "CI failed -> gate fired"                 "$EXIT_GATE_FIRED"         1 "failure"
expect_outcome "CI timed_out -> gate fired"              "$EXIT_GATE_FIRED"         1 "timed_out"
expect_outcome "no run yet, then failure -> gate fired"  "$EXIT_GATE_FIRED"         3 "" "" "failure"
expect_outcome "CI PASSED -> gate did not block"         "$EXIT_GATE_DID_NOT_BLOCK" 1 "success"

# Every INCONCLUSIVE sibling in the case list classifies on first poll.
# cancelled was already covered; the other five are new sibling coverage.
# startup_failure is a terminal GitHub Actions conclusion that was not in
# the case list before this commit — it fell through to the unrecognised
# branch, kept polling, and only "arrived" at INCONCLUSIVE by timing out.
# Asserting polls=1 is what makes this test distinguish classification
# from polling out.
expect_outcome "CI cancelled -> inconclusive"            "$EXIT_INCONCLUSIVE"       1 "cancelled"
expect_outcome "CI skipped -> inconclusive"              "$EXIT_INCONCLUSIVE"       1 "skipped"
expect_outcome "CI neutral -> inconclusive"              "$EXIT_INCONCLUSIVE"       1 "neutral"
expect_outcome "CI stale -> inconclusive"                "$EXIT_INCONCLUSIVE"       1 "stale"
expect_outcome "CI action_required -> inconclusive"      "$EXIT_INCONCLUSIVE"       1 "action_required"
expect_outcome "CI startup_failure -> inconclusive"      "$EXIT_INCONCLUSIVE"       1 "startup_failure"

# Non-terminal and unknown values keep polling until the attempt budget
# runs out, then return INCONCLUSIVE from the loop's timeout path — polls
# equals the attempt budget (3 here).
expect_outcome "never concludes -> inconclusive"         "$EXIT_INCONCLUSIVE"       3 ""
expect_outcome "unknown value -> inconclusive (polled)"  "$EXIT_INCONCLUSIVE"       3 "mystery_value"

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES decision-table case(s) failed" >&2
  exit 1
fi
echo "all 12 decision-table cases pass"
