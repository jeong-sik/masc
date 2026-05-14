#!/usr/bin/env bash
# pr-sync-body.sh — keep a managed "commit lineage" block in a PR body in sync
# with the actual commit stack.
#
# Why this exists: an agent (or human in a hurry) writes a PR body describing
# the first revision, then keeps pushing commits — the body now describes
# code that no longer exists, and review bots (Copilot/CodeRabbit) raise
# "PR description does not match the code" findings. Run this after every
# push to refresh a small managed table of commits so the body always points
# at the current state.
#
# The script edits ONLY the region between the markers:
#   <!-- COMMIT-LINEAGE:START --> ... <!-- COMMIT-LINEAGE:END -->
# Everything else in the body is left byte-for-byte untouched. If the markers
# are absent, the block is appended to the end of the body.
#
# Usage:
#   pr-sync-body.sh <repo|.> <pr>
#   pr-sync-body.sh <repo|.> <pr> --dry-run    # print the new body, don't push
#
# Exit codes: 0 ok (pushed or dry-run) · 1 usage/precondition error.
#
# Requires: gh, jq
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

REPO="${1:-}"; PR="${2:-}"; MODE="${3:-}"
[ -n "$REPO" ] && [ -n "$PR" ] || die "usage: $0 <repo|.> <pr> [--dry-run]"
[ -z "$MODE" ] || [ "$MODE" = "--dry-run" ] || die "unknown arg: $MODE"

if [ "$REPO" = "." ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "cannot infer repo from cwd"
fi

PR_JSON="$(gh pr view "$PR" --repo "$REPO" --json body,commits,headRefName,baseRefName)"
OLD_BODY="$(echo "$PR_JSON" | jq -r '.body // ""')"
HEAD_REF="$(echo "$PR_JSON" | jq -r '.headRefName')"
BASE_REF="$(echo "$PR_JSON" | jq -r '.baseRefName')"

# Build the commit table (oldest → newest, as GitHub returns them).
TABLE="$(echo "$PR_JSON" | jq -r '
  .commits[]
  | "| `\(.oid[0:9])` | \(.messageHeadline | gsub("\\|";"\\\\|")) | \(.committedDate[0:10]) |"
')"
N="$(echo "$PR_JSON" | jq -r '.commits | length')"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

BLOCK="$(cat <<EOF
<!-- COMMIT-LINEAGE:START -->
### Commit lineage (auto-synced)

\`$HEAD_REF\` → \`$BASE_REF\` · $N commit(s) · synced $TS

| sha | subject | date |
|---|---|---|
$TABLE

<sub>Managed by \`scripts/pr-sync-body.sh\` — do not hand-edit between these markers. The code of record is the diff, not prose above this block.</sub>
<!-- COMMIT-LINEAGE:END -->
EOF
)"

START_MARK='<!-- COMMIT-LINEAGE:START -->'
END_MARK='<!-- COMMIT-LINEAGE:END -->'

# Match the markers on a whole line only — `index()`/`grep -F` substring
# matching would trip on body prose that merely *mentions* the marker
# (e.g. inside backticks), duplicating the block and deleting real content.
if printf '%s\n' "$OLD_BODY" | grep -qxF -- "$START_MARK"; then
  # A START without a matching END line would make awk drop everything after
  # START (skip stays 1 forever). Bail rather than truncate someone's body —
  # this only happens if the markers were hand-mangled.
  if ! printf '%s\n' "$OLD_BODY" | grep -qxF -- "$END_MARK"; then
    echo "pr-sync-body: PR body has '$START_MARK' but no matching '$END_MARK' line — refusing to rewrite (fix the body by hand first)" >&2
    exit 1
  fi
  # Replace the existing managed block. The block is passed via a temp file,
  # not `awk -v`, because BSD awk (macOS) rejects newlines in -v assignments.
  TMPBLOCK="$(mktemp)"
  trap 'rm -f "$TMPBLOCK"' EXIT
  printf '%s\n' "$BLOCK" > "$TMPBLOCK"
  NEW_BODY="$(
    awk -v start="$START_MARK" -v end="$END_MARK" -v blockfile="$TMPBLOCK" '
      $0 == start { while ((getline line < blockfile) > 0) print line; close(blockfile); skip=1; next }
      skip && $0 == end { skip=0; next }
      !skip { print }
    ' <<<"$OLD_BODY"
  )"
  rm -f "$TMPBLOCK"; trap - EXIT
else
  # Append, separated by a blank line.
  NEW_BODY="$(printf '%s\n\n%s\n' "$OLD_BODY" "$BLOCK")"
fi

if [ "$MODE" = "--dry-run" ]; then
  printf '%s\n' "$NEW_BODY"
  exit 0
fi

if [ "$NEW_BODY" = "$OLD_BODY" ]; then
  echo "$REPO#$PR — body already in sync (no change)"
  exit 0
fi

printf '%s' "$NEW_BODY" | gh pr edit "$PR" --repo "$REPO" --body-file - \
  && echo "$REPO#$PR — commit-lineage block synced ($N commits)" \
  || die "gh pr edit failed"
