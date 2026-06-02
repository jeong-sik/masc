#!/usr/bin/env bash
# Clean up TLC model-checker disk artefacts that Makefile's -cleanup flag misses.
# Safe: only touches paths matched by specs/.gitignore rules.
# Idempotent: no-op if already clean.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SPECS_DIR="$REPO_ROOT/specs"

if [ ! -d "$SPECS_DIR" ]; then
  echo "cleanup-tlc-artifacts: no specs/ dir, skipping"
  exit 0
fi

before_kb=$(du -sk "$SPECS_DIR" 2>/dev/null | awk '{print $1}')

# specs/states/ (top-level MC export) — entirely gitignored
rm -rf "$SPECS_DIR/states" 2>/dev/null || true

# specs/**/states/ — per-spec MC state dir (gitignored)
find "$SPECS_DIR" -type d -name states -prune -exec rm -rf {} + 2>/dev/null || true

# specs/**/*_TTrace_*.bin|.tla and TraceData.tla — gitignored
find "$SPECS_DIR" -type f \( \
  -name '*_TTrace_*.bin' -o \
  -name '*_TTrace_*.tla' -o \
  -name 'TraceData.tla' \
  \) -delete 2>/dev/null || true

after_kb=$(du -sk "$SPECS_DIR" 2>/dev/null | awk '{print $1}')
freed_mb=$(( (before_kb - after_kb) / 1024 ))

if [ "$freed_mb" -gt 0 ]; then
  echo "cleanup-tlc-artifacts: freed ${freed_mb} MB"
else
  echo "cleanup-tlc-artifacts: no artefacts to clean"
fi
