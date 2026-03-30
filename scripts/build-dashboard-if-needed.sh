#!/usr/bin/env bash
# build-dashboard-if-needed.sh — Rebuild dashboard SPA only when sources changed.
# Called by `make build`. Compares source mtime against build output.
# Skips when: no package.json, pnpm/corepack missing, or sources unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$REPO_ROOT/dashboard"
OUTPUT_DIR="$REPO_ROOT/assets/dashboard"
STAMP="$OUTPUT_DIR/.build-stamp"

# No dashboard source — nothing to do
if [ ! -f "$DASHBOARD_DIR/package.json" ]; then
  exit 0
fi

dashboard_pm=()
dashboard_pm_label=""
if command -v pnpm >/dev/null 2>&1; then
  dashboard_pm=(pnpm)
elif command -v corepack >/dev/null 2>&1; then
  dashboard_pm=(corepack pnpm)
else
  echo "[dashboard] pnpm/corepack not found, skipping." >&2
  exit 0
fi
dashboard_pm_label="${dashboard_pm[*]}"

# Check if rebuild is needed: any source file newer than stamp
needs_rebuild() {
  # No stamp or no output → must build
  [ ! -f "$STAMP" ] && return 0
  [ ! -f "$OUTPUT_DIR/index.html" ] && return 0

  # Any .ts/.tsx/.css/.html source newer than stamp → rebuild
  if find "$DASHBOARD_DIR/src" \
       -newer "$STAMP" \( -name '*.ts' -o -name '*.tsx' -o -name '*.css' -o -name '*.html' \) \
       2>/dev/null | head -1 | grep -q .; then
    return 0
  fi

  # Root index.html newer than stamp → rebuild
  if [ "$DASHBOARD_DIR/index.html" -nt "$STAMP" ]; then
    return 0
  fi

  # package.json changed → rebuild (deps may have changed)
  if [ "$DASHBOARD_DIR/package.json" -nt "$STAMP" ]; then
    return 0
  fi

  return 1
}

if needs_rebuild; then
  echo "[dashboard] Sources changed, rebuilding SPA..." >&2
  temp_root="${TMPDIR:-/tmp}"
  temp_root="${temp_root%/}"
  if [ ! -d "$temp_root" ] || [ ! -w "$temp_root" ]; then
    temp_root="/tmp"
  fi
  if ! log_file="$(TMPDIR="$temp_root" mktemp "$temp_root/masc-dashboard-build.XXXXXX" 2>/dev/null)"; then
    echo "[dashboard] Unable to create temp log file; falling back to stderr-less logging." >&2
    log_file="/dev/null"
  fi
  if [ -d "$DASHBOARD_DIR/node_modules" ]; then
    if (cd "$DASHBOARD_DIR" && "${dashboard_pm[@]}" run build >"$log_file" 2>&1); then
      tail -n 3 "$log_file" >&2 || true
      if [ "$log_file" != "/dev/null" ]; then
        rm -f "$log_file"
      fi
      touch "$STAMP"
      echo "[dashboard] Build complete." >&2
      exit 0
    fi
    echo "[dashboard] Existing deps build failed, retrying after ${dashboard_pm_label} install..." >&2
  fi

  if ! (cd "$DASHBOARD_DIR" && "${dashboard_pm[@]}" install --frozen-lockfile --prefer-offline >"$log_file" 2>&1 && "${dashboard_pm[@]}" run build >>"$log_file" 2>&1); then
    tail -n 20 "$log_file" >&2 || true
    if [ "$log_file" != "/dev/null" ]; then
      rm -f "$log_file"
    fi
    echo "[dashboard] Build failed (non-fatal)." >&2
    exit 0
  fi
  tail -n 6 "$log_file" >&2 || true
  if [ "$log_file" != "/dev/null" ]; then
    rm -f "$log_file"
  fi
  touch "$STAMP"
  echo "[dashboard] Build complete." >&2
else
  echo "[dashboard] Up to date, skipping." >&2
fi
