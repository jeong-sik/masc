#!/usr/bin/env bash
# Report or close stale Copilot [WIP] draft PRs with zero changed files.
#
# Usage:
#   scripts/cleanup-copilot-zero-diff-prs.sh --repo owner/name
#   scripts/cleanup-copilot-zero-diff-prs.sh --repo owner/name --close
#
# Safety defaults:
#   - report-only unless --close is passed
#   - only considers draft PRs authored by copilot-swe-agent
#   - only considers titles starting with [WIP]
#   - only considers PRs whose GraphQL files.totalCount is 0
#   - skips PRs with reviews, review threads, issue comments, or reviewDecision

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-}"
AUTHOR="copilot-swe-agent"
TITLE_PREFIX="[WIP]"
LIMIT=100
MIN_AGE_HOURS=24
CLOSE=0
COMMENT="Closing this stale Copilot [WIP] draft because it is draft-only, authored by copilot-swe-agent, and currently has zero changed files. Reopen or recreate it if work resumes with a real diff."

usage() {
  awk '
    NR == 1 { next }
    /^[[:space:]]*$/ {
      if (started) print ""
      next
    }
    /^#/ {
      line = $0
      sub(/^# ?/, "", line)
      print line
      started = 1
      next
    }
    started { exit }
  ' "$0"
}

die() {
  echo "error: $*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires owner/name"
      REPO="$2"
      shift 2
      ;;
    --author)
      [ "$#" -ge 2 ] || die "--author requires a GitHub login"
      AUTHOR="$2"
      shift 2
      ;;
    --title-prefix)
      [ "$#" -ge 2 ] || die "--title-prefix requires a value"
      TITLE_PREFIX="$2"
      shift 2
      ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit requires 1..100"
      LIMIT="$2"
      shift 2
      ;;
    --min-age-hours)
      [ "$#" -ge 2 ] || die "--min-age-hours requires a non-negative integer"
      MIN_AGE_HOURS="$2"
      shift 2
      ;;
    --comment)
      [ "$#" -ge 2 ] || die "--comment requires text"
      COMMENT="$2"
      shift 2
      ;;
    --close)
      CLOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown arg: $1"
      ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*) die "--limit must be an integer from 1 to 100" ;;
esac
[ "$LIMIT" -ge 1 ] || die "--limit must be at least 1"
[ "$LIMIT" -le 100 ] || die "--limit must be at most 100"

case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*) die "--min-age-hours must be a non-negative integer" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi

[ -n "$REPO" ] || die "repository not found; pass --repo owner/name"
case "$REPO" in
  */*) ;;
  *) die "--repo must be owner/name" ;;
esac

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

QUERY='query($owner: String!, $name: String!, $limit: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: $limit, states: OPEN, orderBy: {field: UPDATED_AT, direction: ASC}) {
      nodes {
        number
        title
        url
        isDraft
        updatedAt
        headRefName
        headRefOid
        reviewDecision
        author { login }
        files(first: 1) { totalCount }
        reviews(first: 1) { totalCount }
        reviewThreads(first: 1) { totalCount }
        comments(first: 1) { totalCount }
      }
    }
  }
}'

response="$(
  gh api graphql \
    -f query="$QUERY" \
    -f owner="$OWNER" \
    -f name="$NAME" \
    -F limit="$LIMIT"
)"

candidates="$(
  printf '%s' "$response" | jq \
    --arg author "$AUTHOR" \
    --arg prefix "$TITLE_PREFIX" \
    --argjson min_age_hours "$MIN_AGE_HOURS" '
      def age_ok($hours):
        if $hours <= 0 then
          true
        else
          ((now - (.updatedAt | fromdateiso8601)) >= ($hours * 3600))
        end;

      [
        .data.repository.pullRequests.nodes[]
        | .authorLogin = (.author.login // "")
        | .fileCount = (.files.totalCount // -1)
        | .reviewsCount = (.reviews.totalCount // 0)
        | .threadCount = (.reviewThreads.totalCount // 0)
        | .commentCount = (.comments.totalCount // 0)
        | select(.isDraft == true)
        | select(.authorLogin == $author)
        | select(.title | startswith($prefix))
        | select(.fileCount == 0)
        | select(age_ok($min_age_hours))
        | .activeReviewCount =
            (.reviewsCount
             + .threadCount
             + .commentCount
             + (if .reviewDecision == null then 0 else 1 end))
        | .eligible = (.activeReviewCount == 0)
        | {
            number,
            title,
            url,
            updatedAt,
            headRefName,
            headRefOid,
            reviewDecision,
            fileCount,
            reviewsCount,
            threadCount,
            commentCount,
            activeReviewCount,
            eligible
          }
      ] as $items
      | ($items
         | sort_by(.headRefOid // "")
         | group_by(.headRefOid // "")
         | map(select(length > 1) | {(.[0].headRefOid // ""): length})
         | add // {}) as $duplicates
      | $items
      | map(. + {duplicateCount: ($duplicates[.headRefOid // ""] // 1)})
    '
)"

candidate_count="$(printf '%s' "$candidates" | jq 'length')"
eligible_count="$(printf '%s' "$candidates" | jq '[.[] | select(.eligible)] | length')"

echo "Repository: $REPO"
echo "Scan: open draft PRs, author=$AUTHOR, title-prefix=$TITLE_PREFIX, files.totalCount=0, limit=$LIMIT, min-age-hours=$MIN_AGE_HOURS"

if [ "$candidate_count" -eq 0 ]; then
  echo "No zero-diff Copilot WIP draft PRs found."
  exit 0
fi

table="$(
  printf '%s' "$candidates" | jq -r '
    (["status", "pr", "updated", "files", "reviews", "threads", "comments", "dups", "head", "title", "url"] | @tsv),
    (.[] | [
      (if .eligible then "ELIGIBLE" else "SKIP_ACTIVE" end),
      ("#" + (.number | tostring)),
      .updatedAt,
      (.fileCount | tostring),
      (.reviewsCount | tostring),
      (.threadCount | tostring),
      (.commentCount | tostring),
      (.duplicateCount | tostring),
      .headRefName,
      .title,
      .url
    ] | @tsv)
  '
)"

if command -v column >/dev/null 2>&1; then
  tab="$(printf '\t')"
  printf '%s\n' "$table" | column -t -s "$tab"
else
  printf '%s\n' "$table"
fi

echo ""
echo "Summary: candidates=$candidate_count eligible=$eligible_count skipped_active=$((candidate_count - eligible_count))"

if [ "$CLOSE" -ne 1 ]; then
  echo "Dry run only. Re-run with --close to close ELIGIBLE rows."
  exit 0
fi

if [ "$eligible_count" -eq 0 ]; then
  echo "No ELIGIBLE rows to close."
  exit 0
fi

printf '%s' "$candidates" | jq -r '.[] | select(.eligible) | .number' |
while IFS= read -r pr_number; do
  [ -n "$pr_number" ] || continue
  echo "Closing #$pr_number"
  gh pr close "$pr_number" --repo "$REPO" --comment "$COMMENT"
done
