#!/usr/bin/env bash
# gh-run-logs.sh — fetch a GitHub Actions run's job list and raw job logs.
#
# Web UI (and other masking channels) redact log lines that contain secrets;
# `gh api .../jobs/<id>/logs` returns the RAW log bytes over an authenticated
# channel, which is what you need when reproducing a CI failure exactly as
# the runner saw it (see corrective-grammar-v0.3.md, task-1595).
#
# Usage:
#   scripts/ci/gh-run-logs.sh <run_id> [job_id ...]
#
#   <run_id>       GitHub Actions run id (number, or its URL).
#   [job_id ...]   Optional. With no job ids, logs for every job are fetched
#                  into $GH_RUN_LOGS_DIR (default: /tmp/gh-run-logs-<run_id>).
#                  With job ids, those jobs' RAW logs are printed to stdout.
#
# Example:
#   $ scripts/ci/gh-run-logs.sh 35038275836
#   repo: jeong-sik/masc
#   run 35038275836: lint suite — completed (success)
#   jobs (4):
#     104305809985  lint suite  success
#     ...
#   logs -> /tmp/gh-run-logs-35038275836/104305809985-lint-suite.log (raw)
#
#   $ scripts/ci/gh-run-logs.sh 35038275836 104305809985 | head -20
#   (raw log lines of that job, straight to stdout)
#
# Auth: uses `gh api`, so the token comes from your usual gh credential
# (GH_TOKEN/GITHUB_TOKEN env or `gh auth login`). Job-log endpoints return
# 401 without a token and 403 for a token without actions:read on the repo;
# both are reported loudly below instead of an empty output.
#
# Note: job list uses --paginate, so runs with >100 jobs are covered; job-log
# endpoints are single calls.

set -euo pipefail

REPO="${GH_REPO:-jeong-sik/masc}"
repo_path() { printf '%s' "${REPO#https://github.com/}"; }
api() { gh api "repos/$(repo_path)/$1"; }

die_auth() { # $1 = http status
  case "$1" in
    401) echo "ERROR: 401 from GitHub API — no/invalid token. Set GH_TOKEN or run 'gh auth login'." >&2 ;;
    403) echo "ERROR: 403 from GitHub API — token lacks actions:read scope (or rate limit) for $(repo_path)." >&2 ;;
    404) echo "ERROR: 404 — run/job not found in $(repo_path) (check the id, or the logs expired)." >&2 ;;
    *)   echo "ERROR: HTTP $1 from GitHub API." >&2 ;;
  esac
  exit 2
}

# gh prints e.g. "gh: Not Found (HTTP 404)" on stderr and exits 1.
status_of_err() { grep -Eo 'HTTP 40[0-9]' "$1" | grep -Eo '40[0-9]' | head -1; }
run_api() { # $@: api path — on HTTP 40x die with the loud message
  local err; err="$(mktemp)"
  if ! api "$1" 2>"$err"; then
    local code; code="$(status_of_err "$err")"; rm -f "$err"
    die_auth "${code:-0}"
  fi
  rm -f "$err"
}

safe_name() { tr -c 'A-Za-z0-9._-' '-' <<<"$1" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'; }

usage() { grep '^# Usage:' -A 12 "$0" | sed 's/^# \{0,1\}//' >&2; }

[ $# -ge 1 ] || { usage; exit 2; }
RUN_ID="${1##*/}"; shift
case "$RUN_ID" in ''|*[!0-9]*) echo "ERROR: run id must be numeric (got '$RUN_ID')" >&2; exit 2;; esac

run_json="$(run_api "actions/runs/$RUN_ID")"
echo "repo: $(repo_path)"
echo "run $RUN_ID: $(jq -r '.name' <<<"$run_json") — $(jq -r '.status' <<<"$run_json") ($(jq -r '.conclusion // "-"' <<<"$run_json"))"

jobs_json="$(run_api "actions/runs/$RUN_ID/jobs?per_page=100" --paginate)"
echo "jobs ($(jq '.total_count' <<<"$jobs_json")):"
jq -r '.jobs[] | "  \(.id)  \(.name)  \(.conclusion // .status)"' <<<"$jobs_json"

# Fetch the RAW log of one job. $1 = job id, $2 = "-" for stdout or a path.
# gh refuses to print bodies containing ANSI escape sequences by default
# ("pass --allow-escape-sequences"); raw CI logs always contain them, so we
# pass the flag deliberately — the raw bytes are the whole point here.
# Failure semantics: HTTP 40x -> loud message + exit 2; empty body -> loud
# message + nonzero for that job; never leave a silent empty file as
# "success" (set -e alone is not the contract — observed task-1595: a 0-byte
# file landed while the pipe died quietly).
fetch_log() {
  local jid="$1" dest="$2" err code out
  err="$(mktemp)"
  # The body must land in $dest via redirection ON the gh call itself: gh
  # prints the raw log to its stdout, and a bare `cat` afterwards would read
  # the caller's stdin instead (observed task-1595: an 88-byte file holding
  # a herestring line while the real log leaked to script stdout).
  #
  # Fallback (observed by code-reviewer on run 35040252284, job
  # 104618294154): gh api can return HTTP 200 with an EMPTY body for job
  # logs — suspected redirect gh does not follow. curl -sL follows it and
  # fetched the full 4340-line log, so we treat an empty gh body as a
  # fallback trigger, not as success.
  if [ "$dest" = "-" ]; then
    out="$(gh api --allow-escape-sequences "repos/$(repo_path)/actions/jobs/$jid/logs" 2>"$err")" || {
      code="$(status_of_err "$err")"; rm -f "$err"
      die_auth "${code:-0}"
    }
    rm -f "$err"
    if [ -z "$out" ] && command -v curl >/dev/null; then
      out="$(curl -sL --max-time 90 -H "Authorization: Bearer $(gh auth token)" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$(repo_path)/actions/jobs/$jid/logs")"
    fi
    printf '%s' "$out"
  else
    if ! gh api --allow-escape-sequences "repos/$(repo_path)/actions/jobs/$jid/logs" >"$dest" 2>"$err"; then
      code="$(status_of_err "$err")"; rm -f "$err"
      die_auth "${code:-0}"
    fi
    if [ ! -s "$dest" ] && command -v curl >/dev/null; then
      curl -sL --max-time 90 -H "Authorization: Bearer $(gh auth token)" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$(repo_path)/actions/jobs/$jid/logs" >"$dest"
    fi
    rm -f "$err"
    if [ ! -s "$dest" ]; then
      echo "ERROR: job $jid returned an empty log (unexpected)" >&2
      return 1
    fi
    echo "  log -> $dest ($(wc -c <"$dest") bytes, raw)"
  fi
}

# Per-job loop never aborts the whole batch: failures are counted and
# reported, the run summary keeps its exit status. Without this guard the
# `while` subshell dies on the first bad job under `set -e`.
fetch_all() {
  local failed=0
  while IFS=$'\t' read -r jid jname; do
    [ -n "$jid" ] || continue
    if ! fetch_log "$jid" "$out_dir/$(safe_name "$jid-$jname").log"; then
      failed=$((failed + 1))
    fi
  done <<<"$(jq -r '.jobs[] | "\(.id)\t\(.name)"' <<<"$jobs_json")"
  return $((failed > 0))
}

if [ $# -eq 0 ]; then
  out_dir="${GH_RUN_LOGS_DIR:-/tmp/gh-run-logs-${RUN_ID}}"
  mkdir -p "$out_dir"
  echo "logs -> $out_dir (raw, unmasked)"
  if ! fetch_all; then
    echo "ERROR: some job logs failed to fetch (see above)" >&2
    exit 1
  fi
else
  for jid in "$@"; do
    case "$jid" in ''|*[!0-9]*) echo "ERROR: job id must be numeric (got '$jid')" >&2; exit 2;; esac
    fetch_log "$jid" "-"
  done
fi
