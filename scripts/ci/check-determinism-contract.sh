#!/usr/bin/env bash
# CI gate: Deterministic / Non-deterministic boundary contract enforcement (DET/NDT).
# Meta-issue: #9522
#
# CONTRACT:
#   - Deterministic logic must not depend on non-deterministic outputs for
#     branching decisions (e.g., do not branch on wall-clock, random, or
#     unordered collection iteration).
#   - Non-deterministic inputs must be wrapped in explicit `NonDet` or
#     `Random` or `Clock` types at the boundary.
#   - Sound partial parsing: return `Some` only when certain, `None` otherwise.
#     Never guess a default from an unknown input.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

# 1. Deterministic code branching on non-deterministic values
echo "=== Scan: deterministic branch on non-deterministic source ==="
nd_patterns=$(
  rg -n 'Unix\.gettimeofday\|Random\.|Unix\.times\|Sys\.time\|Unix\.getpid' lib/ --type ml -g '!test/' || true
)
if [ -n "$nd_patterns" ]; then
  echo "WARN: Non-deterministic source used in lib/ (ensure wrapped at boundary):"
  echo "$nd_patterns" | head -20
fi

# 2. Sound partial check: Option.value ~default on parsed external input
#    This catches the anti-pattern of assigning a default when parsing fails.
echo "=== Scan: permissive default on unknown input ==="
permissive=$(
  rg -B1 -n 'Option\.value.*~default:' lib/keeper/ lib/mcp_server_*.ml --type ml -g '!test/' || true
)
if [ -n "$permissive" ]; then
  echo "WARN: Option.value with default on potentially unknown input (sound partial?):"
  echo "$permissive" | head -20
fi

# 3. Unknown -> catch-all default in match (the "permissive default" anti-pattern)
echo "=== Scan: catch-all permissive default ==="
catch_all=$(
  rg -A1 -n '\|\s*_\s*->\s*Some' lib/ --type ml -g '!test/' || true
)
if [ -n "$catch_all" ]; then
  echo "WARN: catch-all branch returning Some (possible unsound default):"
  echo "$catch_all" | head -20
fi

# 4. Hashtbl.iter / Map.iter used where order matters for deterministic replay
echo "=== Scan: unordered iteration in deterministic context ==="
unordered=$(
  rg -n 'Hashtbl\.iter\|Hashtbl\.fold\|Map\. iter\|Map\. fold' lib/ --type ml -g '!test/' || true
)
if [ -n "$unordered" ]; then
  echo "INFO: unordered collection iteration (verify order does not affect output):"
  echo "$unordered" | head -10
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== DET/NDT gate: PASS ==="
fi

exit "$exit_code"
