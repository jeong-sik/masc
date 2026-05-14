#!/usr/bin/env bash
# pr-ci-triage.sh — collapse a PR's check runs into pass / cancelled-stale /
# fail / pending, so a wall of red "fail" rows from `gh pr checks` reduces to
# the few that genuinely need attention.
#
# Why this exists: `gh pr checks` (text mode) reports CANCELLED runs — a
# frequent result of pushing a new commit while CI is mid-flight — as "fail"
# with 0s duration, making a PR look far worse than it is. The JSON `bucket`
# field already separates `cancel` from `fail`; this script uses it, prints
# only the genuine `fail` runs, and with --logs fetches the tail of each
# failing job so you can judge real regression vs pre-existing advisory
# failure (e.g. masc-mcp's `ocamlformat-check` on pre-existing in-file
# violations) without opening a browser.
#
# Usage:
#   pr-ci-triage.sh <repo|.> <pr>
#   pr-ci-triage.sh <repo|.> <pr> --logs        # tail (40 lines) of each fail job
#   pr-ci-triage.sh <repo|.> <pr> --logs=80     # ... with N lines of tail
#
# Exit codes: 0 no genuine failures · 1 one or more genuine failures · 2 setup error.
#
# Requires: gh, jq
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 2; }

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

REPO="${1:-}"; PR="${2:-}"; MODE="${3:-}"
[ -n "$REPO" ] && [ -n "$PR" ] || die "usage: $0 <repo|.> <pr> [--logs[=N]]"

LOG_LINES=0
case "${MODE:-}" in
  "")            ;;
  --logs)        LOG_LINES=40 ;;
  --logs=*)      LOG_LINES="${MODE#--logs=}"; [[ "$LOG_LINES" =~ ^[0-9]+$ ]] || die "bad --logs value: $MODE" ;;
  *)             die "unknown arg: $MODE" ;;
esac

if [ "$REPO" = "." ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "cannot infer repo from cwd"
fi

CHECKS_JSON="$(gh pr checks "$PR" --repo "$REPO" --json name,state,bucket,link 2>/dev/null)" \
  || die "gh pr checks failed (no checks yet, or bad PR number?)"

summary() {
  # `group_by` only groups *adjacent* equal keys, so sort by .bucket first —
  # otherwise a bucket appearing non-contiguously would be split into multiple
  # groups and double-counted.
  echo "$CHECKS_JSON" | jq -r '
    sort_by(.bucket) | group_by(.bucket) | map({bucket: .[0].bucket, n: length})
    | map("\(.n) \(.bucket)") | join(" · ")'
}

N_FAIL="$(echo "$CHECKS_JSON" | jq '[.[] | select(.bucket == "fail")] | length')"
N_TOTAL="$(echo "$CHECKS_JSON" | jq 'length')"

echo "$REPO#$PR — $N_TOTAL checks: $(summary)"

if [ "$N_FAIL" -eq 0 ]; then
  echo "no genuine failures (any 'fail' you saw in \`gh pr checks\` was cancelled/stale)"
  exit 0
fi

echo
echo "Genuine failures ($N_FAIL):"
echo "$CHECKS_JSON" | jq -r '.[] | select(.bucket == "fail") | "── \(.name)\n   \(.state)  \(.link)"'

if [ "$LOG_LINES" -gt 0 ]; then
  # job link looks like .../actions/runs/<run_id>/job/<job_id>
  echo
  echo "$CHECKS_JSON" | jq -r '.[] | select(.bucket == "fail") | "\(.name)\t\(.link)"' | while IFS=$'\t' read -r name link; do
    run_id="${link#*/runs/}"; run_id="${run_id%%/*}"
    job_id="${link##*/job/}"
    [[ "$run_id" =~ ^[0-9]+$ ]] && [[ "$job_id" =~ ^[0-9]+$ ]] \
      || { echo "── $name: cannot parse run/job id from $link"; continue; }
    echo "──────── $name (run $run_id job $job_id) — failed step, last $LOG_LINES lines ────────"
    # --log-failed prints only the failing step's log; fall back to full job log.
    gh run view "$run_id" --repo "$REPO" --job "$job_id" --log-failed 2>/dev/null | tail -n "$LOG_LINES" \
      || gh api "repos/$REPO/actions/jobs/$job_id/logs" 2>/dev/null | tail -n "$LOG_LINES" \
      || echo "(log fetch failed — may be expired)"
    echo
  done
fi

exit 1
