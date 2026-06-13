#!/usr/bin/env bash
# pr-queue-lanes.sh — classify open PRs into operator triage lanes.
#
# Usage:
#   scripts/pr-queue-lanes.sh <repo|.> [--limit N] [--lane NAME] [--json]
#
# Lanes are ordered by the next human/operator action:
#   conflict    mergeStateStatus=DIRTY
#   ci_fail     one or more real check failures
#   ci_pending  no real failures, at least one check still running/queued
#   review_wait reviewDecision=REVIEW_REQUIRED or CHANGES_REQUESTED
#   blocked     mergeStateStatus=BLOCKED after checks/review are accounted for
#   draft       draft PR with no earlier blocker lane
#   ready       no blocker detected by this lightweight queue view
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 2
}

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
}

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

REPO="${1:-}"
[ -n "$REPO" ] || {
  usage >&2
  exit 2
}
shift

LIMIT=100
LANE_FILTER=""
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit)
      LIMIT="${2:-}"
      shift 2
      ;;
    --limit=*)
      LIMIT="${1#--limit=}"
      shift
      ;;
    --lane)
      LANE_FILTER="${2:-}"
      shift 2
      ;;
    --lane=*)
      LANE_FILTER="${1#--lane=}"
      shift
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "bad --limit value: $LIMIT"

if [ "$REPO" = "." ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
    || die "cannot infer repo from cwd"
fi

CHECK_FIELDS="number,title,url,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup,updatedAt,headRefName,baseRefName"
PRS_JSON="$(gh pr list --repo "$REPO" --state open --limit "$LIMIT" --json "$CHECK_FIELDS")" \
  || die "gh pr list failed"

jq -r \
  --arg repo "$REPO" \
  --arg lane_filter "$LANE_FILTER" \
  --argjson json_out "$JSON_OUT" '
  def clean_title:
    gsub("[\t\r\n]+"; " ") | gsub("  +"; " ");

  def check_counts:
    (.statusCheckRollup // []) as $checks
    | {
        real_failures:
          [ $checks[]
            | select((.conclusion // "") == "FAILURE")
            | select((.name // "") | test("^PR Live Gate$") | not)
          ],
        live_gate_failures:
          [ $checks[]
            | select((.conclusion // "") == "FAILURE")
            | select((.name // "") | test("^PR Live Gate$"))
          ],
        pending:
          [ $checks[]
            | select((.status // "") != "COMPLETED")
          ],
        total: ($checks | length)
      };

  def lane_for($c):
    if (.mergeStateStatus // "") == "DIRTY" then "conflict"
    elif ($c.real_failures | length) > 0 then "ci_fail"
    elif ($c.pending | length) > 0 then "ci_pending"
    elif (.reviewDecision // "") == "CHANGES_REQUESTED" then "review_wait"
    elif (.reviewDecision // "") == "REVIEW_REQUIRED" then "review_wait"
    elif (.mergeStateStatus // "") == "BLOCKED" then "blocked"
    elif (.isDraft // false) then "draft"
    else "ready"
    end;

  def lane_rank:
    {
      conflict: 0,
      ci_fail: 1,
      ci_pending: 2,
      review_wait: 3,
      blocked: 4,
      draft: 5,
      ready: 6
    }[.] // 99;

  [ .[]
    | check_counts as $c
    | . + {
        repo: $repo,
        lane: lane_for($c),
        check_total: $c.total,
        real_failure_count: ($c.real_failures | length),
        real_failures: ($c.real_failures | map(.name)),
        live_gate_failure_count: ($c.live_gate_failures | length),
        pending_count: ($c.pending | length),
        pending_checks: ($c.pending | map(.name))
      }
    | del(.statusCheckRollup)
  ]
  | map(select($lane_filter == "" or .lane == $lane_filter))
  | sort_by((.lane | lane_rank), .updatedAt)
  | if $json_out == 1 then
      .
    else
      (["lane","pr","draft","merge","fail","pending","review","updated","title"] | @tsv),
      (.[] | [
        .lane,
        ("#" + (.number | tostring)),
        (.isDraft | tostring),
        (.mergeStateStatus // "UNKNOWN"),
        (.real_failure_count | tostring),
        (.pending_count | tostring),
        (if (.reviewDecision // "") == "" then "NONE" else .reviewDecision end),
        (.updatedAt // ""),
        (.title | clean_title)
      ] | @tsv)
    end
  ' <<< "$PRS_JSON"
