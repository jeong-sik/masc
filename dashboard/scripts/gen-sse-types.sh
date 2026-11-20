#!/usr/bin/env bash
# RFC-0004 Phase A0.2 — generate TypeScript decoders from sse_event.atd.
#
# Runs atdts (ahrefs/atd's TypeScript codegen) on the OCaml-side SSOT
# (lib/sse_event/sse_event.atd) and writes the result to
# dashboard/src/schemas/sse_event_generated.ts.
#
# The generated file is committed; CI invokes this script with --check
# to fail on drift between the .atd source and the committed .ts.
#
# Usage:
#   dashboard/scripts/gen-sse-types.sh           # write OUT_FILE
#   dashboard/scripts/gen-sse-types.sh --check   # diff vs committed,
#                                                # exit 0 ok / 1 drift / 2 error
#
# Requires: atdts (opam install atdts) on PATH.
set -euo pipefail

MODE="write"
case "${1:-}" in
  --check) MODE="check" ;;
  "") ;;
  *)
    echo "error: unknown argument: $1" >&2
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel)"
ATD_SOURCE="$REPO_ROOT/lib/sse_event/sse_event.atd"
OUT_DIR="$REPO_ROOT/dashboard/src/schemas"
OUT_FILE="$OUT_DIR/sse_event_generated.ts"

if ! command -v atdts >/dev/null 2>&1; then
  echo "error: atdts not found on PATH. Install with: opam install atdts" >&2
  exit 2
fi

if [[ ! -f "$ATD_SOURCE" ]]; then
  echo "error: ATD source not found at $ATD_SOURCE" >&2
  exit 2
fi

# atdts writes <input>.ts next to the input.  Use a scratch dir so the
# tool stays away from the source tree and we control the final name.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cp "$ATD_SOURCE" "$SCRATCH/sse_event_generated.atd"
( cd "$SCRATCH" && atdts sse_event_generated.atd )
GENERATED="$SCRATCH/sse_event_generated.ts"

case "$MODE" in
  write)
    mkdir -p "$OUT_DIR"
    mv "$GENERATED" "$OUT_FILE"
    echo "wrote $OUT_FILE"
    ;;
  check)
    if [[ ! -f "$OUT_FILE" ]]; then
      echo "error: $OUT_FILE missing — run $0 (no flags) to regenerate" >&2
      exit 1
    fi
    if ! diff -u "$OUT_FILE" "$GENERATED" >/dev/null; then
      echo "error: $OUT_FILE is out of date relative to $ATD_SOURCE" >&2
      echo "       run $0 (no flags) and commit the regenerated file" >&2
      echo "       diff (first 40 lines):" >&2
      diff -u "$OUT_FILE" "$GENERATED" | head -40 >&2 || true
      exit 1
    fi
    echo "ok: $OUT_FILE in sync with $ATD_SOURCE"
    ;;
esac
