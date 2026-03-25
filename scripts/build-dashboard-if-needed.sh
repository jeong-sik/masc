#!/usr/bin/env bash
# build-dashboard-if-needed.sh — Rebuild dashboard SPA only when sources changed.
# Called by `make build`. Compares source mtime against build output.
# Skips when: no package.json, npm missing, or sources unchanged.

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

# No npm — skip silently
if ! command -v npm >/dev/null 2>&1; then
  echo "[dashboard] npm not found, skipping." >&2
  exit 0
fi

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
  (cd "$DASHBOARD_DIR" && npm install --prefer-offline --no-audit 2>&1 | tail -1 >&2 && npm run build 2>&1 | tail -3 >&2) || {
    echo "[dashboard] Build failed (non-fatal)." >&2
    exit 0
  }
  touch "$STAMP"
  echo "[dashboard] Build complete." >&2
else
  echo "[dashboard] Up to date, skipping." >&2
fi
