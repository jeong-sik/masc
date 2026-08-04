#!/usr/bin/env bash
# pr-review-thread-carryover.sh — carry unresolved review threads across merge.
#
# When a PR merges with unresolved review threads, those threads stop being
# anyone's context: the branch is deleted, the PR leaves every board, and the
# finding evaporates unless a human happens to remember it. This script makes
# the record reach the next actor instead of blocking the merge: it opens one
# issue per merged PR listing every unresolved thread (path:line, author,
# excerpt, thread id) and cross-links it from the PR.
#
# This is deliberately not a merge gate. Root rationale:
# instructions/masc-workflow.md "강제 장치보다 자기 관측" — repair the
# observation path first, leave judgment to the actor. GitHub's native
# "require conversation resolution" branch protection remains the operator's
# backstop if observation alone proves insufficient.
#
# Usage:
#   pr-review-thread-carryover.sh <repo|.> <pr>   # carry threads of a merged PR
#   pr-review-thread-carryover.sh --render-only   # stdin: threads JSON → stdout: issue body
#
# --render-only consumes the exact JSON shape fetch_threads emits and renders
# the issue body for unresolved threads only; it performs no API calls, which
# is what the test contract exercises.
#
# Exit codes: 0 ok (including "nothing to carry") · 1 usage/API error.
#
# Requires: gh, jq
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

LABEL="review-carryover"
EXCERPT_LIMIT=300

render_body() {
  # stdin: threads JSON document; arguments: repo, pr (display only).
  local repo="$1" pr="$2"
  jq -r --arg repo "$repo" --arg pr "$pr" --argjson limit "$EXCERPT_LIMIT" '
    [ .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved | not) ] as $threads
    | if ($threads | length) == 0 then empty else
        "Merged \($repo)#\($pr) left \($threads | length) unresolved review thread(s). Each entry below is an unaddressed finding or an unanswered question; close it with a fix PR, or resolve the thread with grounds via scripts/pr-resolve-thread.sh.\n\n" +
        ( [ $threads[]
            | "- **\(.path // "?"):\(.line // "?")** by \(.comments.nodes[0].author.login // "?") — thread `\(.id)`\n  > \(.comments.nodes[0].body | gsub("[\r\n]+"; " ") | .[0:$limit])"
          ] | join("\n") ) +
        "\n\ncarryover-marker:pr-\($pr)"
      end
  '
}

if [ "${1:-}" = "--render-only" ]; then
  render_body "${2:-repo}" "${3:-0}"
  exit 0
fi

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

REPO="${1:-}"; PR="${2:-}"
[ -n "$REPO" ] && [ -n "$PR" ] || die "usage: $0 <repo|.> <pr>  (or --render-only < threads.json)"

if [ "$REPO" = "." ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "cannot infer repo from cwd"
fi
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
[ -n "$OWNER" ] && [ -n "$NAME" ] && [ "$OWNER" != "$NAME" ] || die "repo must be owner/name, got: $REPO"

STATE="$(gh pr view "$PR" --repo "$REPO" --json state -q .state)" || die "cannot read PR state for $REPO#$PR"
if [ "$STATE" != "MERGED" ]; then
  # Threads of a closed-unmerged PR die with the code they annotate; carrying
  # them would resurrect findings about deleted lines.
  echo "PR $REPO#$PR state is $STATE (not MERGED) — nothing to carry"
  exit 0
fi

fetch_threads() {
  # Same paginated walk as scripts/pr-resolve-thread.sh: gh injects
  # $endCursor and follows pageInfo until exhausted, then the per-page
  # documents are slurped back into one document.
  # shellcheck disable=SC2016
  gh api graphql --paginate -f query='
    query($owner:String!, $name:String!, $pr:Int!, $endCursor:String) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          reviewThreads(first:100, after:$endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id isResolved path line
              comments(first:1) { nodes { author { login } body } }
            }
          }
        }
      }
    }' -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
    | jq -s '{data:{repository:{pullRequest:{reviewThreads:{nodes:
        [ .[].data.repository.pullRequest.reviewThreads.nodes[] ]}}}}}'
}

THREADS_JSON="$(fetch_threads)" || die "review thread query failed for $REPO#$PR"
UNRESOLVED="$(echo "$THREADS_JSON" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length')"

if [ "$UNRESOLVED" -eq 0 ]; then
  echo "PR $REPO#$PR merged with 0 unresolved review threads — nothing to carry"
  exit 0
fi

BODY="$(echo "$THREADS_JSON" | render_body "$REPO" "$PR")"
TITLE="[review-carryover] PR #$PR merged with $UNRESOLVED unresolved review thread(s)"

# One carryover issue per PR: a re-fired close event appends instead of
# duplicating.
EXISTING="$(gh issue list --repo "$REPO" --search "carryover-marker:pr-$PR in:body" --state all --json number -q '.[0].number // empty')"
if [ -n "$EXISTING" ]; then
  gh issue comment "$EXISTING" --repo "$REPO" --body "$BODY" >/dev/null \
    || die "failed to append carryover to existing issue #$EXISTING"
  echo "appended carryover for $REPO#$PR to existing issue #$EXISTING"
  ISSUE_URL="$(gh issue view "$EXISTING" --repo "$REPO" --json url -q .url)"
else
  gh label create "$LABEL" --repo "$REPO" \
    --description "unresolved review threads carried across a merge" \
    --color D93F0B --force >/dev/null
  ISSUE_URL="$(gh issue create --repo "$REPO" --title "$TITLE" --label "$LABEL" --body "$BODY")" \
    || die "failed to create carryover issue for $REPO#$PR"
  echo "created carryover issue: $ISSUE_URL"
fi

gh pr comment "$PR" --repo "$REPO" \
  --body "이 PR은 미해소 리뷰 스레드 $UNRESOLVED 건과 함께 머지되어 $ISSUE_URL 로 이월되었습니다." >/dev/null \
  || die "failed to cross-link carryover issue on PR #$PR"
