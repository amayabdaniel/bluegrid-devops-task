#!/usr/bin/env bash
# Prove the CRITICAL-severity Trivy gate actually blocks a build.
#
# This opens a throwaway branch whose Dockerfile uses an ancient Alpine base
# known to carry CRITICAL CVEs, opens a PR, waits for CI to fail Trivy, then
# closes the PR and deletes the branch. Intended for the defence call demo.
#
# Requires: gh, git. Operates on the current repo.
set -euo pipefail

BRANCH="demo/trivy-gate-$(date +%s)"

cleanup() {
  git checkout - >/dev/null 2>&1 || true
  gh pr close --delete-branch "$BRANCH" --comment "demo complete" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true
}
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

echo "waiting for the trivy step to fail..."
for _ in $(seq 1 30); do
  conclusion=$(gh run list --branch "$BRANCH" --workflow ci.yml --limit 1 --json conclusion -q '.[0].conclusion // ""')
  [ "$conclusion" = "failure" ] && { echo "gate fired: CI failed as expected."; break; }
  sleep 15
done

gh run list --branch "$BRANCH" --workflow ci.yml --limit 1
