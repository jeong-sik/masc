#!/usr/bin/env bash
# ci_verify_linked_modules.sh — Verify that listed OCaml modules are actually
# linked into a built executable.
#
# OCaml's dead-code elimination / selective linking can drop whole modules if
# no live reference reaches them from the program entry point. This script
# uses nm(1) to confirm that expected module symbols are present in the
# binary, catching "merged in source but absent from the binary" regressions.
#
# Usage:
#   scripts/ci_verify_linked_modules.sh [path/to/binary.exe]
#
# Default binary: _build/default/bin/main_eio.exe

set -euo pipefail

BINARY="${1:-_build/default/bin/main_eio.exe}"

if [ ! -f "$BINARY" ]; then
  echo "ERROR: binary not found: $BINARY" >&2
  echo "Run 'dune build bin/main_eio.exe' first." >&2
  exit 1
fi

# Modules that must be present in the binary. Add more module basenames here
# as the "merged but not linked" risk grows.
REQUIRED_MODULES=(
  keeper_memory_os_types
  keeper_memory_os_policy
  keeper_memory_os_io
  keeper_memory_os_consolidator
  keeper_memory_os_recall
)

MISSING=()

# OCaml emits symbols such as camlKeeper_memory_os_policy__entry or
# camlKeeper_memory_os_policy__foo. A case-insensitive grep for the module
# basename is sufficient to prove linkage.
#
# Note: macOS grep -q on a large symbol table can return 1 even when matches
# exist (observed with ~13MB nm output).  Use grep -c and compare the count.
symbols=$(nm "$BINARY" 2>/dev/null || true)
for mod in "${REQUIRED_MODULES[@]}"; do
  count=$(echo "$symbols" | grep -ic -- "${mod}")
  if [ "$count" -eq 0 ]; then
    MISSING+=("$mod")
  fi
done

if [ "${#MISSING[@]}" -ne 0 ]; then
  echo "ERROR: the following modules are NOT linked into $BINARY:" >&2
  for mod in "${MISSING[@]}"; do
    echo "  - $mod" >&2
  done
  echo "They may be declared in lib/dune but never referenced from the entry point." >&2
  exit 1
fi

echo "OK: all ${#REQUIRED_MODULES[@]} required modules are linked into $BINARY."
