#!/usr/bin/env bash
# CI gate: String-based dispatch vs type-safe variant enforcement (STR).
# Meta-issue: #9521
#
# Anti-patterns:
#   1. String comparison chains where a variant type already exists
#   2. String.lowercase_ascii + string equality for category dispatch
#   3. json_string_opt on known enum fields without validation
#
# CONTRACT: Prefer OCaml variant types for internal dispatch. String matching
# is acceptable only at system boundaries (CLI args, JSON parsing, external APIs).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

# 1. Flag String.lowercase_ascii + equality chains in non-parsing code
#    Heuristic: three or more consecutive string comparisons on the same variable
echo "=== Scan: repeated string equality dispatch ==="
matches=$(rg -n 'String\.lowercase_ascii.*=\s*"' lib/ --type ml -g '!test/' || true)
if [ -n "$matches" ]; then
  echo "WARN: String.lowercase_ascii + literal comparison found (consider variant):"
  echo "$matches" | head -20
fi

# 2. json_string_opt on fields that should be enum-constrained
#    This is a heuristic: we flag raw json_string_opt where a typed parser exists.
echo "=== Scan: raw json_string_opt on potentially enum fields ==="
matches=$(
  rg -n 'json_string_opt\s+"(status|state|kind|type|action|mode|profile)"' \
    lib/ --type ml -g '!test/' || true
)
if [ -n "$matches" ]; then
  echo "WARN: json_string_opt on enum-like field (consider strict enum parser):"
  echo "$matches" | head -20
fi

# 3. List.mem + string literals for category dispatch
echo "=== Scan: List.mem string literal dispatch ==="
matches=$(rg -n 'List\.mem.*\[.*"' lib/ --type ml -g '!test/' || true)
if [ -n "$matches" ]; then
  echo "WARN: List.mem with string literals (consider variant + List.mem on variant):"
  echo "$matches" | head -20
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== STR gate: PASS ==="
fi

exit "$exit_code"
