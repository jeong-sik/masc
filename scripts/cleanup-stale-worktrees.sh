#!/usr/bin/env bash
# Remove worktrees whose last commit is older than N days (default 7).
#
# Complements scripts/cleanup-merged-worktrees.sh — that script only handles
# branches that already merged into main. This one targets the larger leak:
# stale autocoder/feature worktrees whose PR was abandoned, closed without
# merge, or never opened. Without explicit removal these accumulate
# indefinitely (#11040: 539 worktrees, 53x over guideline).
#
# Conservative by design:
#   - dry-run by default; --apply required to actually remove
#   - skips dirty worktrees (uncommitted or staged changes)
#   - skips worktrees containing nested worktrees (.worktrees/ inside)
#   - skips worktrees referenced by tmux, running processes, or launchd plists
#   - never uses --force
#   - leaves the branch in place (only removes the worktree directory)
#
# Usage:
#   ./scripts/cleanup-stale-worktrees.sh                # dry run, 7-day threshold
#   ./scripts/cleanup-stale-worktrees.sh --days 14      # 14-day threshold
#   ./scripts/cleanup-stale-worktrees.sh --apply        # actually remove

set -euo pipefail

APPLY=0
DAYS=7

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/worktree-cleanup-guards.sh"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "--days must be a non-negative integer (got: $DAYS)" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CUTOFF_TS=$(( $(date +%s) - DAYS * 86400 ))

stale=0
dirty=0
nested=0
active=0
removed=0
skipped=0

# `git worktree list --porcelain` emits one stanza per worktree, separated by
# blank lines. Stanzas always start with `worktree <path>`. Process via
# substitution (not pipe) so loop runs in the current shell — pipes spawn a
# subshell and counter increments are lost.
while read -r wt_path; do
  [ -z "$wt_path" ] && continue
  [ "$wt_path" = "$REPO_ROOT" ] && continue

  # Last-commit timestamp (Unix epoch). If the working tree is broken or
  # detached, skip — operator should diagnose manually.
  if ! last_ts=$(git -C "$wt_path" log -1 --format='%ct' 2>/dev/null); then
    echo "BROKEN  $wt_path (cannot read HEAD) — skipped"
    skipped=$((skipped+1))
    continue
  fi
  [ -z "$last_ts" ] && continue

  if [ "$last_ts" -ge "$CUTOFF_TS" ]; then
    continue
  fi

  # Dirty check — unstaged or staged changes
  if ! git -C "$wt_path" diff --quiet 2>/dev/null \
     || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
    echo "DIRTY   $wt_path — skipped (has uncommitted changes)"
    dirty=$((dirty+1))
    continue
  fi

  # Nested-worktree guard: never remove a directory that itself contains
  # other worktrees (memory: feedback_masc-mcp-nested-worktree-containers).
  if [ -d "$wt_path/.worktrees" ]; then
    echo "NESTED  $wt_path — skipped (contains nested .worktrees/)"
    nested=$((nested+1))
    continue
  fi

  if worktree_cleanup_is_runtime_referenced "$wt_path"; then
    echo "ACTIVE  $wt_path — skipped (referenced by tmux/process/launchd)"
    active=$((active+1))
    continue
  fi

  age_days=$(( ( $(date +%s) - last_ts ) / 86400 ))
  stale=$((stale+1))

  if [ "$APPLY" -eq 1 ]; then
    if git worktree remove "$wt_path" 2>/dev/null; then
      echo "REMOVED $wt_path (last commit ${age_days}d ago)"
      removed=$((removed+1))
    else
      echo "SKIP    $wt_path (remove failed — likely locked)"
      skipped=$((skipped+1))
    fi
  else
    echo "CANDID  $wt_path (last commit ${age_days}d ago)"
  fi
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

if [ "$APPLY" -eq 1 ]; then
  git worktree prune
  echo ""
  echo "Summary (--days $DAYS --apply): stale=$stale removed=$removed dirty=$dirty nested=$nested active=$active skipped=$skipped"
else
  echo ""
  echo "Summary (--days $DAYS dry-run): stale=$stale dirty=$dirty nested=$nested active=$active skipped=$skipped"
  echo "Pass --apply to remove the listed candidates."
fi
