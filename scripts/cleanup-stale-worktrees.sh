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
#   - a detached worktree has no branch to leave its commit on, so the commit
#     is tagged archive/worktree/<name>-<sha> before the directory goes
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
      # The header up to its first blank line, so help stays whole when the
      # header grows. A line count here goes stale the next time it does.
      sed -n '1,/^$/p' "$0"; exit 0 ;;
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
archived=0

# `git worktree list --porcelain` emits one stanza per worktree, separated by
# blank lines. Stanzas always start with `worktree <path>`. Process via
# substitution (not pipe) so loop runs in the current shell — pipes spawn a
# subshell and counter increments are lost.
while read -r wt_path; do
  [ -z "$wt_path" ] && continue
  [ "$wt_path" = "$REPO_ROOT" ] && continue

  # Last-commit timestamp (Unix epoch). A detached HEAD answers this as well
  # as a branch does, so a detached worktree is processed like any other; only
  # an unreadable HEAD is skipped.
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
  # other worktrees (memory: feedback_masc-nested-worktree-containers).
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

  # What holds this worktree's commit after the directory goes. A branch does,
  # which is why removal is safe for one. A detached worktree whose commit sits
  # on no ref at all has only this directory holding it, so removing it leaves
  # the commit unreachable -- work lost by a script that promises above to
  # leave commits alone. Measured 2026-09-20: 19 of 265 worktrees in this repo
  # were detached with their commit on no other ref.
  archive_tag=""
  head_sha=""
  if ! git -C "$wt_path" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    head_sha=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$head_sha" ] \
       && [ -z "$(git for-each-ref --contains "$head_sha" --format='%(refname)' \
                    refs/heads refs/remotes refs/tags 2>/dev/null)" ]; then
      archive_tag="archive/worktree/$(basename "$wt_path")-${head_sha:0:10}"
    fi
  fi

  if [ "$APPLY" -eq 1 ]; then
    if [ -n "$archive_tag" ]; then
      if ! git tag -a "$archive_tag" "$head_sha" \
             -m "detached worktree $wt_path archived on cleanup; its commit was on no other ref" \
             2>/dev/null; then
        echo "SKIP    $wt_path (detached commit could not be archived, so it stays)"
        skipped=$((skipped+1))
        continue
      fi
      archived=$((archived+1))
    fi
    if git worktree remove "$wt_path" 2>/dev/null; then
      if [ -n "$archive_tag" ]; then
        echo "REMOVED $wt_path (last commit ${age_days}d ago, commit kept at $archive_tag)"
      else
        echo "REMOVED $wt_path (last commit ${age_days}d ago)"
      fi
      removed=$((removed+1))
    else
      echo "SKIP    $wt_path (remove failed -- likely locked)"
      skipped=$((skipped+1))
    fi
  else
    if [ -n "$archive_tag" ]; then
      echo "CANDID  $wt_path (last commit ${age_days}d ago, detached -- would tag $archive_tag)"
    else
      echo "CANDID  $wt_path (last commit ${age_days}d ago)"
    fi
  fi
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

if [ "$APPLY" -eq 1 ]; then
  git worktree prune
  echo ""
  echo "Summary (--days $DAYS --apply): stale=$stale removed=$removed archived=$archived dirty=$dirty nested=$nested active=$active skipped=$skipped"
else
  echo ""
  echo "Summary (--days $DAYS dry-run): stale=$stale dirty=$dirty nested=$nested active=$active skipped=$skipped"
  echo "Pass --apply to remove the listed candidates."
fi
