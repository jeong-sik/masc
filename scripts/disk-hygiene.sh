#!/usr/bin/env bash
#
# disk-hygiene.sh — inspect (and optionally fix) the main disk-growth
# culprits observed in this repo:
#   - TLC artefacts under specs/
#   - global Dune cache drift under ~/.cache/dune
#   - stray isolated build dirs (_build_*)
#   - large worktree fan-out counts
#
# Safe defaults:
#   - no deletion unless an explicit fix flag is passed
#   - repo-local TLC cleanup is part of --fix
#   - global Dune cache reset requires --reset-dune-cache
#   - extra isolated build dir cleanup requires --clean-extra-build-dirs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPECS_DIR="$REPO_ROOT/specs"
WORKTREES_DIR="$REPO_ROOT/.worktrees"
DUNE_CACHE_DIR="${DUNE_CACHE_DIR:-$HOME/.cache/dune}"
DUNE_CACHE_TRIM_SIZE="${DUNE_CACHE_TRIM_SIZE:-20GB}"

WARN_DUNE_CACHE_MB="${MASC_DISK_HYGIENE_DUNE_CACHE_WARN_MB:-20480}"
WARN_DUNE_CACHE_MISMATCH_MB="${MASC_DISK_HYGIENE_DUNE_CACHE_MISMATCH_WARN_MB:-4096}"
WARN_TLC_ARTIFACTS_MB="${MASC_DISK_HYGIENE_TLC_WARN_MB:-2048}"
WARN_EXTRA_BUILD_MB="${MASC_DISK_HYGIENE_EXTRA_BUILD_WARN_MB:-1024}"
WARN_WORKTREE_COUNT="${MASC_DISK_HYGIENE_WORKTREE_WARN_COUNT:-100}"

DO_FIX=0
DO_RESET_DUNE_CACHE=0
DO_CLEAN_EXTRA_BUILDS=0

usage() {
  cat <<'EOF'
Usage: scripts/disk-hygiene.sh [options]

Inspect repo-local disk growth hotspots and optionally apply targeted cleanup.

Options:
  --fix                     Apply safe fixes (TLC artefact cleanup + dune cache trim)
  --reset-dune-cache        Remove ~/.cache/dune after trim (explicit only)
  --clean-extra-build-dirs  Remove top-level _build_* dirs (keeps _build/)
  --trim-size=SIZE          Dune cache trim target (default: 20GB)
  --help                    Show this help

Environment overrides:
  DUNE_CACHE_DIR
  DUNE_CACHE_TRIM_SIZE
  MASC_DISK_HYGIENE_DUNE_CACHE_WARN_MB
  MASC_DISK_HYGIENE_DUNE_CACHE_MISMATCH_WARN_MB
  MASC_DISK_HYGIENE_TLC_WARN_MB
  MASC_DISK_HYGIENE_EXTRA_BUILD_WARN_MB
  MASC_DISK_HYGIENE_WORKTREE_WARN_COUNT
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) DO_FIX=1 ;;
    --reset-dune-cache) DO_RESET_DUNE_CACHE=1 ;;
    --clean-extra-build-dirs) DO_CLEAN_EXTRA_BUILDS=1 ;;
    --trim-size=*) DUNE_CACHE_TRIM_SIZE="${1#*=}" ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "disk-hygiene: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

kb_of_path() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo 0
    return 0
  fi
  du -sk "$path" 2>/dev/null | awk '{print $1}'
}

human_kb() {
  local kb="${1:-0}"
  awk -v kb="$kb" '
    BEGIN {
      bytes = kb * 1024.0
      split("B KiB MiB GiB TiB", units, " ")
      idx = 1
      while (bytes >= 1024.0 && idx < 5) {
        bytes /= 1024.0
        idx++
      }
      if (idx == 1 || bytes >= 10.0) printf "%.0f%s", bytes, units[idx]
      else printf "%.1f%s", bytes, units[idx]
    }'
}

parse_size_to_bytes() {
  local raw
  raw="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  if [ -z "$raw" ]; then
    echo 0
    return 0
  fi

  local number unit factor
  number="$(printf '%s' "$raw" | sed -E 's/^([0-9]+([.][0-9]+)?).*/\1/')"
  unit="$(printf '%s' "$raw" | sed -E 's/^[0-9]+([.][0-9]+)?([A-Za-z]+)$/\2/')"

  case "$unit" in
    B) factor=1 ;;
    kB) factor=1000 ;;
    MB) factor=1000000 ;;
    GB) factor=1000000000 ;;
    TB) factor=1000000000000 ;;
    KiB) factor=1024 ;;
    MiB) factor=$((1024 * 1024)) ;;
    GiB) factor=$((1024 * 1024 * 1024)) ;;
    TiB) factor=$((1024 * 1024 * 1024 * 1024)) ;;
    *) echo 0; return 0 ;;
  esac

  awk -v n="$number" -v f="$factor" 'BEGIN { printf "%.0f", n * f }'
}

sum_find_kb() {
  local sum=0
  local path kb
  while IFS= read -r -d '' path; do
    kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
    kb="${kb:-0}"
    sum=$((sum + kb))
  done
  echo "$sum"
}

status_ok=0
status_warn=0

record_item() {
  local name="$1"
  local status="$2"
  local size_kb="$3"
  local detail="$4"
  printf '%-20s %-4s %8s  %s\n' "$name" "$status" "$(human_kb "$size_kb")" "$detail"
  case "$status" in
    ok) status_ok=$((status_ok + 1)) ;;
    warn) status_warn=$((status_warn + 1)) ;;
  esac
}

collect_metrics() {
  status_ok=0
  status_warn=0

  local dune_actual_kb dune_actual_mb dune_logical_raw dune_logical_bytes dune_delta_mb
  local dune_status dune_detail
  dune_actual_kb="$(kb_of_path "$DUNE_CACHE_DIR")"
  dune_actual_mb=$((dune_actual_kb / 1024))
  dune_logical_raw=""
  dune_logical_bytes=0
  if command -v dune >/dev/null 2>&1; then
    dune_logical_raw="$(dune cache size 2>/dev/null || true)"
    dune_logical_bytes="$(parse_size_to_bytes "$dune_logical_raw")"
  fi
  dune_delta_mb=0
  if [ "$dune_logical_bytes" -gt 0 ]; then
    local actual_bytes
    actual_bytes=$((dune_actual_kb * 1024))
    if [ "$actual_bytes" -gt "$dune_logical_bytes" ]; then
      dune_delta_mb=$(((actual_bytes - dune_logical_bytes) / 1024 / 1024))
    fi
  fi
  dune_status="ok"
  if [ "$dune_actual_mb" -ge "$WARN_DUNE_CACHE_MB" ] \
    || [ "$dune_delta_mb" -ge "$WARN_DUNE_CACHE_MISMATCH_MB" ]; then
    dune_status="warn"
  fi
  if [ "$dune_logical_bytes" -gt 0 ]; then
    dune_detail="path=$DUNE_CACHE_DIR logical=${dune_logical_raw:-unknown} delta=${dune_delta_mb}MB"
  else
    dune_detail="path=$DUNE_CACHE_DIR logical=unavailable"
  fi
  record_item "dune_cache" "$dune_status" "$dune_actual_kb" "$dune_detail"

  local tlc_states_kb tlc_trace_kb tlc_total_kb tlc_status tlc_detail
  tlc_states_kb=0
  tlc_trace_kb=0
  if [ -d "$SPECS_DIR" ]; then
    tlc_states_kb="$(
      find "$SPECS_DIR" -type d -name states -print0 2>/dev/null | sum_find_kb
    )"
    tlc_trace_kb="$(
      find "$SPECS_DIR" -type f \
        \( -name '*_TTrace_*.bin' -o -name '*_TTrace_*.tla' -o -name 'TraceData.tla' \) \
        -print0 2>/dev/null | sum_find_kb
    )"
  fi
  tlc_total_kb=$((tlc_states_kb + tlc_trace_kb))
  tlc_status="ok"
  if [ $((tlc_total_kb / 1024)) -ge "$WARN_TLC_ARTIFACTS_MB" ]; then
    tlc_status="warn"
  fi
  tlc_detail="states=$(human_kb "$tlc_states_kb") traces=$(human_kb "$tlc_trace_kb") path=$SPECS_DIR"
  record_item "tlc_artifacts" "$tlc_status" "$tlc_total_kb" "$tlc_detail"

  local build_main_kb extra_build_kb extra_build_count extra_build_status extra_build_detail path
  build_main_kb="$(kb_of_path "$REPO_ROOT/_build")"
  extra_build_kb=0
  extra_build_count=0
  while IFS= read -r -d '' path; do
    extra_build_count=$((extra_build_count + 1))
    extra_build_kb=$((extra_build_kb + $(du -sk "$path" 2>/dev/null | awk '{print $1}')))
  done < <(find "$REPO_ROOT" -maxdepth 1 -type d -name '_build_*' -print0 2>/dev/null)
  extra_build_status="ok"
  if [ $((extra_build_kb / 1024)) -ge "$WARN_EXTRA_BUILD_MB" ] || [ "$extra_build_count" -gt 0 ]; then
    extra_build_status="warn"
  fi
  extra_build_detail="main=$(human_kb "$build_main_kb") extra_dirs=$extra_build_count"
  record_item "build_dirs" "$extra_build_status" "$extra_build_kb" "$extra_build_detail"

  local worktree_count worktree_kb worktree_status worktree_detail
  worktree_count=0
  if [ -d "$WORKTREES_DIR" ]; then
    worktree_count="$(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  fi
  worktree_kb="$(kb_of_path "$WORKTREES_DIR")"
  worktree_status="ok"
  if [ "$worktree_count" -ge "$WARN_WORKTREE_COUNT" ]; then
    worktree_status="warn"
  fi
  worktree_detail="count=$worktree_count path=$WORKTREES_DIR"
  record_item "worktrees" "$worktree_status" "$worktree_kb" "$worktree_detail"
}

run_fixes() {
  echo
  echo "Applying fixes..."

  "$REPO_ROOT/scripts/cleanup-tlc-artifacts.sh"

  if command -v dune >/dev/null 2>&1; then
    dune cache trim --size="$DUNE_CACHE_TRIM_SIZE" || true
  else
    echo "disk-hygiene: dune not found; skipping dune cache trim" >&2
  fi

  if [ "$DO_RESET_DUNE_CACHE" -eq 1 ] && [ -e "$DUNE_CACHE_DIR" ]; then
    rm -rf "$DUNE_CACHE_DIR"
    echo "disk-hygiene: reset dune cache at $DUNE_CACHE_DIR"
  fi

  if [ "$DO_CLEAN_EXTRA_BUILDS" -eq 1 ]; then
    find "$REPO_ROOT" -maxdepth 1 -type d -name '_build_*' -exec rm -rf {} +
    echo "disk-hygiene: removed stray _build_* dirs under $REPO_ROOT"
  fi
}

echo "disk-hygiene: repo=$REPO_ROOT"
collect_metrics

if [ "$DO_FIX" -eq 1 ] || [ "$DO_RESET_DUNE_CACHE" -eq 1 ] || [ "$DO_CLEAN_EXTRA_BUILDS" -eq 1 ]; then
  run_fixes
  echo
  echo "Post-fix:"
  collect_metrics
fi

echo
printf 'summary ok=%d warn=%d\n' "$status_ok" "$status_warn"

if [ "$status_warn" -gt 0 ]; then
  echo "notes: TLC artefacts can be cleaned safely; extra worktrees/build dirs need explicit review."
  exit 1
fi

exit 0
