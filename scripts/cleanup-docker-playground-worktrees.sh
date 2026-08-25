#!/usr/bin/env bash
# Conservatively remove stale keeper Docker playground worktrees.
#
# Docker Desktop on macOS can retain a large FD set for shared files under
# .masc/playground/docker. Stale repo worktrees amplify that into a
# per-process host FD hotspot even when MASC's own process FD count is low.
#
# Dry-run is the default. Use --apply only after reviewing CANDID lines.

set -euo pipefail

APPLY=0
DAYS=7
ROOT=""
KEEPER_FILTER=""
REPO_FILTER=""
INCLUDE_BROKEN=0

usage() {
  cat <<'EOF'
cleanup-docker-playground-worktrees.sh - stale Docker playground worktree GC

Usage:
  scripts/cleanup-docker-playground-worktrees.sh [--root PATH] [--days N]
  scripts/cleanup-docker-playground-worktrees.sh --apply [--root PATH] [--days N]

Options:
  --root PATH     Docker playground root. Defaults to
                  $MASC_BASE_PATH/.masc/playground/docker, then
                  $PWD/.masc/playground/docker.
  --days N        Candidate age threshold from last git commit. Default: 7.
  --keeper NAME   Limit to one keeper directory under the Docker playground.
  --repo NAME     Limit to one repo under <keeper>/repos/. Example: masc.
  --apply         Remove candidates with git worktree remove.
  --include-broken
                  Also consider broken/non-git directories under
                  <keeper>/repos/<repo>/.worktrees/ using filesystem mtime.
                  Requires the same dry-run review flow; clean git worktrees
                  still use git worktree remove.

Safety:
  - dry-run by default
  - skips dirty worktrees and runtime-referenced paths
  - skips broken git roots unless --include-broken is passed
  - clean git worktrees remove through git worktree remove
  - broken directories remove only with --apply --include-broken
  - leaves branches intact
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --keeper) KEEPER_FILTER="${2:-}"; shift 2 ;;
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    --include-broken) INCLUDE_BROKEN=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "--days must be a non-negative integer (got: $DAYS)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/worktree-cleanup-guards.sh" ]; then
  # shellcheck source=scripts/lib/worktree-cleanup-guards.sh
  . "$SCRIPT_DIR/lib/worktree-cleanup-guards.sh"
else
  worktree_cleanup_is_runtime_referenced() { return 1; }
fi

if [ -z "$ROOT" ]; then
  BASE="${MASC_BASE_PATH:-$(pwd)}"
  ROOT="$BASE/.masc/playground/docker"
fi

ROOT="${ROOT%/}"
# Containment is checked against the resolved root: every candidate path is
# canonicalised before the comparison, so both sides must be realpaths.
ROOT_REAL="$(cd "$ROOT" 2>/dev/null && pwd -P || echo "$ROOT")"
NOW_TS=$(date +%s)
CUTOFF_TS=$(( NOW_TS - DAYS * 86400 ))

scanned=0
candidates=0
removed=0
recent=0
dirty=0
active=0
broken=0
broken_candidates=0
broken_removed=0
failed=0

if [ ! -d "$ROOT" ]; then
  echo "Docker playground root missing: $ROOT"
  echo "Summary (--root $ROOT --days $DAYS dry-run): scanned=0 candidates=0 removed=0 recent=0 dirty=0 active=0 broken=0 broken_candidates=0 broken_removed=0 failed=0"
  exit 0
fi

path_mtime_ts() {
  local path="$1"
  if stat -f '%m' "$path" >/dev/null 2>&1; then
    stat -f '%m' "$path"
  else
    stat -c '%Y' "$path"
  fi
}

canonical_path() {
  local path="$1"
  (cd "$path" 2>/dev/null && pwd -P)
}

# Candidates are found by what they are, not by where they sit.
#
# A linked git worktree has a regular file at <dir>/.git holding a gitdir:
# pointer; a primary checkout has a directory there. Selecting only the file
# form means this script can never propose removing a primary checkout — a
# stronger guarantee than the previous path-shape guard, which would have
# accepted any directory under <keeper>/repos/<x>/.worktrees/ including a
# clone someone put there.
#
# The old shape also stopped matching: nothing creates repos/ any more, so the
# three nested loops would have scanned zero entries and exited 0, reporting
# success while cleaning nothing.
#
# -maxdepth bounds the walk; keepers place worktrees at depths 2-4 below the
# root in the live playground (2026-08-13), and the primary checkouts they
# hang off are found at 1-3.
while IFS= read -r git_pointer; do
  wt_path="$(dirname "$git_pointer")"
  [ -d "$wt_path" ] || continue

  # A linked worktree's .git holds a "gitdir:" pointer. dune leaves a
  # zero-byte .git under _build/.sandbox, which is a build artifact, not a
  # worktree — measured 13 of them in the live playground. Without this they
  # reach the --include-broken path and become removal candidates, which would
  # put this script inside dune's own directory.
  case "$(head -c 7 "$git_pointer" 2>/dev/null)" in
    "gitdir:") ;;
    *) continue ;;
  esac

  rel="${wt_path#"$ROOT"/}"
  keeper_name="${rel%%/*}"
  if [ -n "$KEEPER_FILTER" ] && [ "$keeper_name" != "$KEEPER_FILTER" ]; then
    continue
  fi

  # The repository a worktree belongs to is what its own git metadata says,
  # not what its path spells. The primary checkout is also where
  # `git worktree remove` has to run from, so it is kept, not just its name.
  common_dir="$(git -C "$wt_path" rev-parse --git-common-dir 2>/dev/null || true)"
  main_checkout=""
  if [ -n "$common_dir" ]; then
    common_real="$(canonical_path "$common_dir" 2>/dev/null || echo "$common_dir")"
    main_checkout="$(dirname "$common_real")"
  fi
  repo_name="unknown"
  if [ -n "$main_checkout" ]; then
    repo_name="$(basename "$main_checkout")"
  fi
  if [ -n "$REPO_FILTER" ] && [ "$repo_name" != "$REPO_FILTER" ]; then
    continue
  fi

  scanned=$((scanned + 1))

  # Containment: the resolved path must still be under ROOT. Everything below
  # removes directories, so this is checked against the realpath rather than
  # the spelling that reached us.
  wt_canonical="$(canonical_path "$wt_path" 2>/dev/null || true)"
  case "$wt_canonical" in
    "$ROOT_REAL"/*) ;;
    *)
      echo "BROKEN  $wt_path -- skipped (resolves outside the playground root)"
      broken=$((broken + 1))
      continue
      ;;
  esac

      if git -C "$wt_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_top="$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null || true)"
        wt_real="$(canonical_path "$wt_path" || true)"
        git_top_real=""
        if [ -n "$git_top" ] && [ -d "$git_top" ]; then
          git_top_real="$(canonical_path "$git_top" || true)"
        fi
      else
        git_top_real=""
        wt_real="$(canonical_path "$wt_path" || true)"
      fi

      if [ -z "$wt_real" ] || [ "$git_top_real" != "$wt_real" ]; then
        if [ "$INCLUDE_BROKEN" -ne 1 ]; then
          echo "BROKEN  $wt_path -- skipped (not a standalone readable git worktree; pass --include-broken to consider it)"
          broken=$((broken + 1))
          continue
        fi

        if ! last_ts="$(path_mtime_ts "$wt_path" 2>/dev/null)" || [ -z "$last_ts" ]; then
          echo "BROKEN  $wt_path -- skipped (cannot read filesystem mtime)"
          broken=$((broken + 1))
          continue
        fi

        if [ "$last_ts" -ge "$CUTOFF_TS" ]; then
          recent=$((recent + 1))
          continue
        fi

        if worktree_cleanup_is_runtime_referenced "$wt_path"; then
          echo "ACTIVE  keeper=$keeper_name repo=$repo_name path=$wt_path -- skipped"
          active=$((active + 1))
          continue
        fi

        age_days=$(( ( NOW_TS - last_ts ) / 86400 ))
        broken_candidates=$((broken_candidates + 1))
        if [ "$APPLY" -eq 1 ]; then
          if rm -rf "$wt_path"; then
            echo "BROKEN_REMOVED keeper=$keeper_name repo=$repo_name age_days=$age_days path=$wt_path"
            broken_removed=$((broken_removed + 1))
          else
            echo "FAILED  keeper=$keeper_name repo=$repo_name path=$wt_path -- broken directory remove failed"
            failed=$((failed + 1))
          fi
        else
          echo "BROKEN_CANDID keeper=$keeper_name repo=$repo_name age_days=$age_days path=$wt_path"
        fi
        continue
      fi

      if ! last_ts="$(git -C "$wt_path" log -1 --format='%ct' 2>/dev/null)" \
        || [ -z "$last_ts" ]; then
        echo "BROKEN  $wt_path -- skipped (cannot read HEAD timestamp)"
        broken=$((broken + 1))
        continue
      fi
      if wt_mtime_ts="$(path_mtime_ts "$wt_path" 2>/dev/null)" \
        && [ -n "$wt_mtime_ts" ] \
        && [ "$wt_mtime_ts" -gt "$last_ts" ]; then
        last_ts="$wt_mtime_ts"
      fi

      if [ "$last_ts" -ge "$CUTOFF_TS" ]; then
        recent=$((recent + 1))
        continue
      fi

      if [ -n "$(git -C "$wt_path" status --porcelain --untracked-files=normal --ignore-submodules=dirty 2>/dev/null)" ]; then
        echo "DIRTY   keeper=$keeper_name repo=$repo_name path=$wt_path -- skipped"
        dirty=$((dirty + 1))
        continue
      fi

      if worktree_cleanup_is_runtime_referenced "$wt_path"; then
        echo "ACTIVE  keeper=$keeper_name repo=$repo_name path=$wt_path -- skipped"
        active=$((active + 1))
        continue
      fi

      age_days=$(( ( NOW_TS - last_ts ) / 86400 ))
      candidates=$((candidates + 1))

      if [ "$APPLY" -eq 1 ]; then
        if [ -n "$main_checkout" ] \
           && git -C "$main_checkout" worktree remove "$wt_path" 2>/dev/null; then
          git -C "$main_checkout" worktree prune 2>/dev/null || true
          echo "REMOVED keeper=$keeper_name repo=$repo_name age_days=$age_days path=$wt_path"
          removed=$((removed + 1))
        else
          echo "FAILED  keeper=$keeper_name repo=$repo_name path=$wt_path -- git worktree remove failed"
          failed=$((failed + 1))
        fi
      else
        echo "CANDID  keeper=$keeper_name repo=$repo_name age_days=$age_days path=$wt_path"
      fi
done < <(find "$ROOT" -mindepth 2 -maxdepth 7 -name .git -type f 2>/dev/null)

mode="dry-run"
if [ "$APPLY" -eq 1 ]; then
  mode="--apply"
fi

echo ""
echo "Summary (--root $ROOT --days $DAYS $mode): scanned=$scanned candidates=$candidates removed=$removed recent=$recent dirty=$dirty active=$active broken=$broken broken_candidates=$broken_candidates broken_removed=$broken_removed failed=$failed"
if [ "$APPLY" -ne 1 ]; then
  echo "Pass --apply to remove the listed candidates."
fi
