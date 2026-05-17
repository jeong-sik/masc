#!/usr/bin/env bash
# RFC-0004 Phase A0.2 PR-1 — generate TypeScript decoders from sse_event.atd.
#
# This script runs atdts (ahrefs/atd's TypeScript codegen) on the
# OCaml-side SSOT (lib/sse_event/sse_event.atd) and writes the result
# to dashboard/src/schemas/sse_event_generated.ts.
#
# The generated file is committed.  Drift between the .atd and the
# committed .ts is caught by re-running this script in CI and diffing
# against HEAD (wired in PR-2).
#
# Requires: atdts (opam install atdts) on PATH.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ATD_SOURCE="$REPO_ROOT/lib/sse_event/sse_event.atd"
OUT_DIR="$REPO_ROOT/dashboard/src/schemas"
OUT_FILE="$OUT_DIR/sse_event_generated.ts"

if ! command -v atdts >/dev/null 2>&1; then
  echo "error: atdts not found on PATH. Install with: opam install atdts" >&2
  exit 1
fi

if [[ ! -f "$ATD_SOURCE" ]]; then
  echo "error: ATD source not found at $ATD_SOURCE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# atdts writes <input>.ts next to the input.  Copy to a temp scratch
# dir, run atdts there, then move the result to the target path.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cp "$ATD_SOURCE" "$SCRATCH/sse_event_generated.atd"
( cd "$SCRATCH" && atdts sse_event_generated.atd )
mv "$SCRATCH/sse_event_generated.ts" "$OUT_FILE"

echo "wrote $OUT_FILE"
