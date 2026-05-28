#!/usr/bin/env bash
# CI gate: fail when new timeout/tuning env vars are added to the
# Dashboard module without an RFC.
#
# Background (report 2026-05-19 Phase 4 Action 15):
# The Dashboard module in [env_config_runtime.ml] accumulates env knobs
# that operators use to tune timeout/cache/threshold behaviour.  Each
# new knob widens the configuration surface and can mask structural
# issues (cap/cooldown anti-pattern, sw-dev §Symptom 억제).
# New knobs require an RFC that documents the retire criterion.
#
# Usage:
#   scripts/lint-timeout-env-count.sh          # advisory (exit 0 always)
#   scripts/lint-timeout-env-count.sh --strict  # exit 1 if count > baseline
#
# To bump the baseline after an approved RFC:
#   1. Update DASHBOARD_BASELINE below
#   2. Add the RFC number to the comment

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

TARGET="lib/config/env_config_runtime.ml"
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$TARGET" ]]; then
  echo "SKIP: $TARGET not found" >&2
  exit 0
fi

# Count get_float/get_int calls inside the Dashboard module.
# The module starts with "module Dashboard" and ends with a bare "end".
DASHBOARD_COUNT=$(sed -n '/^module Dashboard/,/^end$/p' "$TARGET" \
  | grep -cE 'get_(float|int)\b' || true)

# Baseline as of 2026-05-28 (17 env vars).
# Each bump requires an RFC reference in the comment below.
DASHBOARD_BASELINE=17
# RFC-0138 Phase 4: 13 Dashboard env vars + 4 full_health/orchestrator

echo "Dashboard env var count: $DASHBOARD_COUNT (baseline: $DASHBOARD_BASELINE)"

if [[ "$DASHBOARD_COUNT" -gt "$DASHBOARD_BASELINE" ]]; then
  delta=$((DASHBOARD_COUNT - DASHBOARD_BASELINE))
  echo "WARN: $delta new env var(s) added since baseline." >&2
  echo "New timeout/tuning env vars require an RFC (sw-dev §Symptom 억제)." >&2
  echo "Bump DASHBOARD_BASELINE in this script with the RFC number." >&2
  if [[ "$STRICT" -eq 1 ]]; then
    exit 1
  fi
fi

if [[ "$DASHBOARD_COUNT" -lt "$DASHBOARD_BASELINE" ]]; then
  echo "NOTE: count decreased — consider lowering baseline to $DASHBOARD_COUNT."
fi
