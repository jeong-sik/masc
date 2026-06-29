#!/usr/bin/env bash
# check-feature-flag-consistency.sh — CI lint for MASC feature flags.
#
# Detects:
#   1. Duplicate get_bool calls for the same MASC_* env var with different defaults
#   2. Boolean flags in env_config modules not registered in Feature_flag_registry
#
# Exit codes:
#   0 = clean
#   1 = inconsistency found
#
# @since v2.162.0
# @see docs/design/inventory-gap-analysis-rfc.md H5

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/lib/config"
REGISTRY="$CONFIG_DIR/feature_flag_registry.ml"
ERRORS=0

echo "=== Feature Flag Consistency Check ==="

# ── Step 1: Find all get_bool calls with MASC_* env vars ──────────────
# Extract: default_value env_var_name file:line
CALLS=\"\"

# ── Step 2: Check for duplicate env vars with different defaults ──────
echo ""
echo "--- Checking for default value conflicts ---"
# Get unique env var names
ENV_VARS=$(echo "$CALLS" | awk '{print $2}' | sort -u)

for var in $ENV_VARS; do
  DEFAULTS=$(echo "$CALLS" | grep " $var$" | awk '{print $1}' | sort -u)
  NUM_DEFAULTS=$(echo "$DEFAULTS" | wc -l | tr -d ' ')
  if [ "$NUM_DEFAULTS" -gt 1 ]; then
    echo "CONFLICT: $var has multiple defaults: $(echo "$DEFAULTS" | tr '\n' ' ')"
    # Show where
    grep -rn "get_bool.*\"$var\"" "$CONFIG_DIR" | grep -v feature_flag_registry.ml
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "$ERRORS" -eq 0 ]; then
  echo "OK: No default value conflicts found."
fi

# ── Step 3: Check registry coverage ──────────────────────────────────
echo ""
echo "--- Checking registry coverage ---"

if [ ! -f "$REGISTRY" ]; then
  echo "WARNING: Feature_flag_registry not found at $REGISTRY"
  exit 0
fi

# Extract registered env var names from registry
REGISTERED=$(grep -o '"MASC_[A-Z_]*"' "$REGISTRY" \
  | grep -v 'get_bool' \
  | tr -d '"' \
  | sort -u)

# Extract boolean env vars from config modules (excluding registry itself).
# grep exits 1 when a pattern has zero matches; that is a valid "none here"
# result (e.g. env_config_core.ml legitimately has no boolean MASC_* flag once
# the last one is retired). The trailing `|| true` keeps that empty case from
# crashing the check under `set -e`/`pipefail`. Real errors are not silenced:
# missing files surface via grep's stderr and the explicit REGISTRY -f guard.
CONFIG_BOOLS=$( ( \
    { grep -rh "Feature_flag_registry.get_bool \"MASC_" "$CONFIG_DIR" || true; } | grep -o "\"MASC_[A-Z_]*\"" | tr -d "\"" ; \
    { grep -rh "get_bool ~default:\(true\|false\) \"MASC_" "$CONFIG_DIR/env_config_core.ml" || true; } | grep -o "\"MASC_[A-Z_]*\"" | tr -d "\"" \
  ) | sort -u || true)

MISSING=0
for var in $CONFIG_BOOLS; do
  if ! echo "$REGISTERED" | grep -q "^${var}$"; then
    echo "UNREGISTERED: $var (in config modules but not in Feature_flag_registry)"
    MISSING=$((MISSING + 1))
  fi
done

if [ "$MISSING" -eq 0 ]; then
  echo "OK: All boolean flags are registered."
else
  echo ""
  echo "WARNING: $MISSING unregistered flag(s). Add them to Feature_flag_registry.all_flags."
  ERRORS=$((ERRORS + MISSING))
fi

# ── Step 4: Check for registry entries not in config ──────────────────
echo ""
echo "--- Checking for stale registry entries ---"
STALE=0
for var in $REGISTERED; do
  if ! echo "$CONFIG_BOOLS" | grep -q "^${var}$"; then
    echo "STALE: $var (in registry but not found in config modules)"
    STALE=$((STALE + 1))
  fi
done

if [ "$STALE" -eq 0 ]; then
  echo "OK: No stale registry entries."
else
  echo ""
  echo "WARNING: $STALE stale registry entry(ies)."
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
TOTAL_CONFIG=$(echo "$CONFIG_BOOLS" | wc -l | tr -d ' ')
TOTAL_REGISTERED=$(echo "$REGISTERED" | wc -l | tr -d ' ')
echo "Summary: $TOTAL_CONFIG config flags, $TOTAL_REGISTERED registered, $ERRORS error(s), $STALE stale"

if [ "$ERRORS" -gt 0 ]; then
  echo "FAIL: Feature flag consistency check failed."
  exit 1
fi

echo "PASS: Feature flag consistency check passed."
exit 0
