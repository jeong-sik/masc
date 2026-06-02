#!/usr/bin/env bash
# Safely remove worktrees whose branch is already merged into main.
# Never uses --force. Respects uncommitted changes, nested worktrees, and
# runtime-pinned paths.
#
# Usage:
#   ./scripts/cleanup-merged-worktrees.sh          # dry run, shows candidates
#   ./scripts/cleanup-merged-worktrees.sh --apply  # actually remove

set -euo pipefail

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      sed -n '1,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/worktree-cleanup-guards.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

git fetch origin main --quiet

# Two merged sources:
#  (1) `git branch --merged origin/main` — catches fast-forward / non-squash merges
#  (2) `gh pr list --state merged` — catches squash-merges (common case on this repo)
# Union both so squash-merged worktrees are actually cleaned.
FF_MERGED="$(git branch --merged origin/main | sed 's/^[* ]*//' | grep -v '^main$' || true)"

if command -v gh >/dev/null 2>&1; then
  SQUASH_MERGED="$(gh pr list --state merged --limit 500 --json headRefName --jq '.[].headRefName' 2>/dev/null || true)"
else
  SQUASH_MERGED=""
fi

MERGED_BRANCHES="$(printf '%s\n%s\n' "$FF_MERGED" "$SQUASH_MERGED" | awk 'NF' | sort -u)"
if [ -z "$MERGED_BRANCHES" ]; then
  echo "No merged branches to clean."
  exit 0
fi

removed=0
skipped=0
dirty=0
nested=0
active=0

while read -r branch; do
  [ -z "$branch" ] && continue
  wt_path="$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')"
  [ -z "$wt_path" ] && continue
  [ "$wt_path" = "$REPO_ROOT" ] && continue

  # Skip if worktree has uncommitted changes
  if ! git -C "$wt_path" diff --quiet 2>/dev/null || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
    echo "DIRTY  $wt_path (branch $branch) — skipped"
    dirty=$((dirty+1))
    continue
  fi

  if [ -d "$wt_path/.worktrees" ]; then
    echo "NESTED $wt_path (branch $branch) — skipped"
    nested=$((nested+1))
    continue
  fi

  if worktree_cleanup_is_runtime_referenced "$wt_path"; then
    echo "ACTIVE $wt_path (branch $branch) — skipped (referenced by tmux/process/launchd)"
    active=$((active+1))
    continue
  fi

  if [ "$APPLY" -eq 1 ]; then
    if git worktree remove "$wt_path" 2>/dev/null; then
      echo "REMOVED $wt_path (branch $branch)"
      removed=$((removed+1))
      git branch -d "$branch" 2>/dev/null || true
    else
      echo "SKIP    $wt_path (remove failed — likely locked or submodule state)"
      skipped=$((skipped+1))
    fi
  else
    echo "CANDID  $wt_path (branch $branch)"
    removed=$((removed+1))
  fi
done <<< "$MERGED_BRANCHES"

if [ "$APPLY" -eq 1 ]; then
  git worktree prune
  echo ""
  echo "Summary: removed=$removed skipped=$skipped dirty=$dirty nested=$nested active=$active"
else
  echo ""
  echo "Summary: $removed candidates (dry run — pass --apply to remove; dirty=$dirty nested=$nested active=$active)"
fi
