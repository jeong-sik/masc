#!/usr/bin/env bash
# check-feature-flag-consistency.sh — registry/consumer consistency lint.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
REGISTRY="$LIB_DIR/config/feature_flag_registry.ml"
ERRORS=0

echo "=== Feature Flag Consistency Check ==="

if [ ! -f "$REGISTRY" ]; then
  echo "ERROR: Feature_flag_registry not found at $REGISTRY"
  exit 1
fi

REGISTERED=$(sed -n \
  's/.*env_name = "\(MASC_[A-Z_]*\)".*/\1/p' \
  "$REGISTRY" | sort -u)

# Registry-backed reads exist in config modules and in runtime gates. Scan the
# complete library and accept the typed [get_bool*] accessor family so a strict
# security reader is not misreported as a stale registry entry.
CONSUMED=$(
  { grep -rh 'Feature_flag_registry.get_bool' "$LIB_DIR" || true; } \
    | grep -o '"MASC_[A-Z_]*"' \
    | tr -d '"' \
    | sort -u \
    || true
)

echo ""
echo "--- Checking consumer coverage ---"
MISSING=0
for var in $CONSUMED; do
  if ! echo "$REGISTERED" | grep -q "^${var}$"; then
    echo "UNREGISTERED: $var"
    MISSING=$((MISSING + 1))
  fi
done

if [ "$MISSING" -eq 0 ]; then
  echo "OK: All literal registry consumers are registered."
else
  ERRORS=$((ERRORS + MISSING))
fi

echo ""
echo "--- Checking for stale literal registry entries ---"
STALE=0
for var in $REGISTERED; do
  if ! echo "$CONSUMED" | grep -q "^${var}$"; then
    echo "STALE: $var"
    STALE=$((STALE + 1))
  fi
done

if [ "$STALE" -eq 0 ]; then
  echo "OK: Every literal registry entry has a runtime consumer."
else
  ERRORS=$((ERRORS + STALE))
fi

echo ""
TOTAL_CONSUMED=$(echo "$CONSUMED" | sed '/^$/d' | wc -l | tr -d ' ')
TOTAL_REGISTERED=$(echo "$REGISTERED" | sed '/^$/d' | wc -l | tr -d ' ')
echo "Summary: $TOTAL_CONSUMED literal consumers, $TOTAL_REGISTERED registry entries, $ERRORS error(s)"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: Feature flag consistency check failed."
  exit 1
fi

echo "PASS: Feature flag consistency check passed."
