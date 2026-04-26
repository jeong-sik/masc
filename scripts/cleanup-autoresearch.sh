#!/usr/bin/env bash
# Quarantine stale autoresearch worktree directories.
#
# Each autoresearch run leaves a per-job dir under
# $MASC_BASE_PATH/.masc/autoresearch/ar-<id>/ (~91 MB). There is no
# lifecycle hook that removes it after the job finishes, so disk usage
# grows monotonically. Until #10892 lands a proper Switch.on_release
# cleanup, this script provides a TTL-based quarantine.
#
# Quarantine, not delete: stale dirs move to
# $MASC_BASE_PATH/.tmp/leak-quarantine-<YYYY-MM-DD>/ so the user can
# inspect or restore them. They can be removed permanently with `rm -rf`
# after confirmation.
#
# Usage:
#   scripts/cleanup-autoresearch.sh                 # dry run, list candidates
#   scripts/cleanup-autoresearch.sh --apply         # quarantine candidates
#   TTL_DAYS=14 scripts/cleanup-autoresearch.sh --apply  # custom TTL
#
# Environment:
#   MASC_BASE_PATH  base path (default: $HOME/me)
#   TTL_DAYS        days a dir must be untouched to qualify (default: 7)
#
# Refuses to quarantine a dir that any process holds an open FD to.
# Per-dir lsof check catches both the autoresearch service holding work
# files and unrelated tools that happen to be reading the dir.

set -euo pipefail

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

BASE="${MASC_BASE_PATH:-$HOME/me}"
TTL_DAYS="${TTL_DAYS:-7}"
AR_DIR="$BASE/.masc/autoresearch"
QUARANTINE_DIR="$BASE/.tmp/leak-quarantine-$(date +%Y-%m-%d)"

if [ ! -d "$AR_DIR" ]; then
  echo "no autoresearch dir at $AR_DIR — nothing to do"
  exit 0
fi

candidates=()
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  candidates+=("$dir")
done < <(find "$AR_DIR" -maxdepth 1 -type d -name 'ar-*' -mtime "+$TTL_DAYS" 2>/dev/null)

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "no autoresearch dirs older than ${TTL_DAYS}d in $AR_DIR"
  exit 0
fi

echo "candidates older than ${TTL_DAYS}d (${#candidates[@]}):"
for d in "${candidates[@]}"; do
  size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
  printf '  %s\t%s\n' "$size" "$d"
done

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "(dry run; pass --apply to quarantine into $QUARANTINE_DIR)"
  exit 0
fi

mkdir -p "$QUARANTINE_DIR"

moved=0
skipped=0
for d in "${candidates[@]}"; do
  # Per-dir guard: refuse if any process holds an open FD.
  if lsof "$d" >/dev/null 2>&1; then
    echo "skip (FD held): $d" >&2
    skipped=$((skipped + 1))
    continue
  fi
  if mv "$d" "$QUARANTINE_DIR/" 2>&1; then
    moved=$((moved + 1))
    echo "quarantined: $(basename "$d")"
  else
    echo "failed to move: $d" >&2
    skipped=$((skipped + 1))
  fi
done

echo
echo "moved: $moved, skipped: $skipped, dest: $QUARANTINE_DIR"
