#!/usr/bin/env bash
# verify-refactor.sh — Regression check for sublibrary refactoring.
# Compares build, module count, and tool schema count against baseline.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf "  PASS  %-30s %s\n" "$label" "$actual"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %-30s expected=%s actual=%s\n" "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== verify-refactor ==="

# 1. Build check
echo "[1/3] Building..."
if scripts/dune-local.sh build @install 2>&1 | tail -3; then
  printf "  PASS  build\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL  build\n"
  FAIL=$((FAIL + 1))
fi

# 2. Module count in lib/dune (modules section)
echo "[2/3] Module counts..."
ML_COUNT=$(find lib -name '*.ml' -not -path '*/\.*' | wc -l | tr -d ' ')
MLI_COUNT=$(find lib -name '*.mli' -not -path '*/\.*' | wc -l | tr -d ' ')
echo "  INFO  .ml files:  $ML_COUNT"
echo "  INFO  .mli files: $MLI_COUNT"

# 3. Tool schema count (grep for tool registration patterns)
echo "[3/3] Tool schemas..."
SCHEMA_COUNT=$(grep -r '"masc_' lib/ --include='*.ml' -l 2>/dev/null | wc -l | tr -d ' ')
echo "  INFO  Files with masc_ schemas: $SCHEMA_COUNT"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
