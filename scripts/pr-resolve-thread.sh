#!/usr/bin/env bash
# pr-resolve-thread.sh — reply to a GitHub PR review thread AND resolve it atomically.
#
# Why this exists: GitHub PR review threads have a 3-tier comment surface —
# (1) PR-level issue comment, (2) review-level summary comment, (3) review
# thread comment anchored to a file/line. `gh pr comment` adds only (1),
# which does NOT resolve the review thread (isResolved stays false), so
# review bots (Copilot / CodeRabbit) keep the thread open and may re-fire.
# Resolving requires the GraphQL resolveReviewThread mutation; replying
# inside the thread requires the REST /pulls/N/comments/{id}/replies
# endpoint. Doing these two steps by hand is consistently error-prone —
# this script makes it one command and verifies the resolved state.
#
# Usage:
#   # list unresolved threads (thread_id + path:line + first comment preview)
#   pr-resolve-thread.sh <repo|.> <pr>
#
#   # reply in-thread + resolve
#   pr-resolve-thread.sh <repo|.> <pr> <thread_id> <reply_body>
#
#   # resolve only (no reply) — pass an empty string for the body
#   pr-resolve-thread.sh <repo|.> <pr> <thread_id> ""
#
# <repo> is owner/name (e.g. jeong-sik/masc-mcp). Pass "." to infer it from
# the current directory via `gh repo view`.
#
# Exit codes: 0 ok · 1 usage/precondition error · 2 resolve not confirmed.
#
# Requires: gh, jq
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

REPO="${1:-}"; PR="${2:-}"
[ -n "$REPO" ] && [ -n "$PR" ] || die "usage: $0 <repo|.> <pr> [thread_id] [reply_body]"

if [ "$REPO" = "." ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "cannot infer repo from cwd"
fi
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
[ -n "$OWNER" ] && [ -n "$NAME" ] && [ "$OWNER" != "$NAME" ] || die "repo must be owner/name, got: $REPO"

fetch_threads() {
  gh api graphql -f query='
    query($owner:String!, $name:String!, $pr:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes {
              id isResolved path line
              comments(first:1) { nodes { databaseId author { login } body } }
            }
          }
        }
      }
    }' -F owner="$OWNER" -F name="$NAME" -F pr="$PR"
}

THREAD_ID="${3:-}"; REPLY_BODY="${4-}"

# ── list mode ────────────────────────────────────────────────────────────
if [ -z "$THREAD_ID" ]; then
  COUNT="$(fetch_threads | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length')"
  echo "$REPO#$PR — $COUNT unresolved review thread(s)"
  fetch_threads | jq -r '
    .data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved | not)
    | "── \(.id)\n   \(.path // "?"):\(.line // "?")  by \(.comments.nodes[0].author.login // "?")\n   \(.comments.nodes[0].body | gsub("[\r\n]+";" ") | .[0:200])"
  '
  exit 0
fi

# ── resolve mode ─────────────────────────────────────────────────────────
THREADS_JSON="$(fetch_threads)"
THREAD_NODE="$(echo "$THREADS_JSON" | jq --arg tid "$THREAD_ID" '.data.repository.pullRequest.reviewThreads.nodes[] | select(.id == $tid)')"
[ -n "$THREAD_NODE" ] || die "thread $THREAD_ID not found in $REPO#$PR"

ALREADY="$(echo "$THREAD_NODE" | jq -r '.isResolved')"
if [ "$ALREADY" = "true" ] && [ -z "${REPLY_BODY}" ]; then
  echo "already resolved: $THREAD_ID (no-op)"
  exit 0
fi

if [ -n "${REPLY_BODY}" ]; then
  COMMENT_ID="$(echo "$THREAD_NODE" | jq -r '.comments.nodes[0].databaseId')"
  [ -n "$COMMENT_ID" ] && [ "$COMMENT_ID" != "null" ] || die "thread $THREAD_ID has no comment to reply to"
  gh api -X POST "repos/$OWNER/$NAME/pulls/$PR/comments/$COMMENT_ID/replies" \
    -f body="$REPLY_BODY" >/dev/null || die "in-thread reply failed for $THREAD_ID"
  echo "reply posted in thread $THREAD_ID"
fi

RESULT="$(gh api graphql -f query='
  mutation($tid:ID!) {
    resolveReviewThread(input:{threadId:$tid}) { thread { isResolved } }
  }' -F tid="$THREAD_ID" | jq -r '.data.resolveReviewThread.thread.isResolved')"

if [ "$RESULT" = "true" ]; then
  echo "resolved: $THREAD_ID"
else
  echo "WARNING: resolve not confirmed (isResolved=$RESULT) for $THREAD_ID — unresolved 1" >&2
  exit 2
fi
