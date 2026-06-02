#!/usr/bin/env bash
# retro-clean-keeper-continuity.sh — one-shot cleanup of stale
# continuity_summary fields in .masc/keepers/*.json.
#
# Context: Issue #7613. PR #7612 restored RFC-MASC-001 Phase 1
# read/save symmetry for Checkpoint.working_context, but existing
# keeper.json files still carry 370–1039 char accumulated narrative in
# continuity_summary. That text survives the checkpoint-less fallback
# path and feeds the resonance loop.
#
# This script:
#   1. Scans .masc/keepers/*.json, reports continuity_summary size
#      per keeper.
#   2. With --apply, backs up each file to
#      .masc/keepers/_backup-retro-clean-<ts>/ and sets
#      continuity_summary = "". All other fields (including
#      last_continuity_update_ts and runtime) are preserved.
#
# Usage:
#   scripts/retro-clean-keeper-continuity.sh                # dry-run
#   scripts/retro-clean-keeper-continuity.sh --apply        # write
#   scripts/retro-clean-keeper-continuity.sh --base-path /path/to/me --apply
#
# Restore:
#   cp .masc/keepers/_backup-retro-clean-<ts>/*.json .masc/keepers/

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

APPLY=0
BASE_PATH="${PWD}"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --base-path) shift; BASE_PATH="${1:?}" ;;
    --base-path=*) BASE_PATH="${1#--base-path=}" ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

KEEPER_DIR="${BASE_PATH}/.masc/keepers"
if [ ! -d "$KEEPER_DIR" ]; then
  echo "ERROR: $KEEPER_DIR not found" >&2
  exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${KEEPER_DIR}/_backup-retro-clean-${TS}"

if [ "$APPLY" -eq 1 ]; then
  mkdir -p "$BACKUP_DIR"
  echo "Backup dir: $BACKUP_DIR"
fi

total=0
nonempty=0
cleared=0
chars_freed=0

shopt -s nullglob
for f in "$KEEPER_DIR"/*.json; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .json)
  case "$name" in
    _backup*) continue ;;
  esac

  # wc -c counts a trailing newline that jq adds to -r output;
  # subtract 1 to get the actual string length.
  raw_len=$(jq -r '.continuity_summary // ""' "$f" | wc -c | tr -d ' ')
  len=$(( raw_len > 0 ? raw_len - 1 : 0 ))

  total=$((total + 1))

  if [ "$len" -le 0 ]; then
    printf "  skip  %-24s (empty)\n" "$name"
    continue
  fi

  nonempty=$((nonempty + 1))
  printf "  clear %-24s %5d chars\n" "$name" "$len"

  if [ "$APPLY" -eq 1 ]; then
    cp "$f" "$BACKUP_DIR/$name.json"
    tmp=$(mktemp)
    jq '.continuity_summary = ""' "$f" > "$tmp"
    mv "$tmp" "$f"
    cleared=$((cleared + 1))
    chars_freed=$((chars_freed + len))
  fi
done

echo ""
echo "Total keepers:         $total"
echo "With non-empty summary: $nonempty"
if [ "$APPLY" -eq 1 ]; then
  echo "Cleared:                $cleared"
  echo "Chars freed:            $chars_freed"
  echo "Backup:                 $BACKUP_DIR"
else
  echo "Would clear:            $nonempty"
  echo "Run with --apply to modify files."
fi
