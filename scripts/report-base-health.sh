#!/usr/bin/env bash
# Say whether the commit this PR branched from was already failing.
#
# A CI failure does not carry the one fact its author needs: did my change
# cause this. On 2026-08-22 main was red for about 100 minutes and thirteen
# open PRs — different authors, different areas — inherited the same five
# failures. An adversarial review on one of them recorded "causality is not
# established", because the reviewer could not tell either (#29332).
#
# This reports, it does not gate. Never exits non-zero on an unhealthy base:
# rebasing is the author's call, and the missing thing was the information.
set -uo pipefail

base_ref="${1:?usage: report-base-health.sh <base-ref> <repo>}"
repo="${2:?usage: report-base-health.sh <base-ref> <repo>}"

merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
if [ -z "$merge_base" ]; then
  echo "[base-health] no merge base with ${base_ref}; nothing to report"
  exit 0
fi

short="${merge_base:0:12}"
echo "[base-health] this branch left ${base_ref} at ${short}"

# `gh api` prints its error body to stdout and exits non-zero, so the exit code
# is the only thing that separates "no runs" from "the call failed". Capturing
# output alone reported a 404 body as a clean run list and called the base
# green, which is the opposite of what this script is for.
if ! runs="$(gh api "repos/${repo}/commits/${merge_base}/check-runs" \
               --jq '.check_runs[] | select(.conclusion != null) | "\(.conclusion)\t\(.name)"' \
             2>/dev/null)"; then
  echo "[base-health] could not read check runs for ${short}"
  echo "[base-health] base health is UNKNOWN — not a statement that it was green"
  exit 0
fi

if [ -z "$runs" ]; then
  echo "[base-health] no completed check runs recorded for ${short}"
  echo "[base-health] (it may predate the retention window, or never ran)"
  exit 0
fi

failed="$(printf '%s\n' "$runs" | awk -F'\t' '$1 == "failure" || $1 == "timed_out" { print $2 }' | sort -u)"

if [ -z "$failed" ]; then
  echo "[base-health] OK - ${short} was green; a failure here is this branch's"
  exit 0
fi

echo "[base-health] ${short} was ALREADY FAILING these checks:"
printf '%s\n' "$failed" | sed 's/^/  - /'
echo
echo "[base-health] A failure in one of those is not evidence about this branch."
echo "[base-health] Rebase onto a green ${base_ref} to separate the two."
exit 0
