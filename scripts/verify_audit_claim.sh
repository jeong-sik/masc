#!/usr/bin/env bash
# verify_audit_claim.sh — deterministic verifier for audit count claims.
#
# Purpose
#   Audits posted by keepers / external reports often state quantitative
#   claims like "16 silent-empty antipatterns in lib/keeper/keeper_tool_policy.ml"
#   or "3 sites in lib/relay.ml".  Without independent measurement those
#   numbers cascade through cross-citation.  Real measurements observed
#   2026-05-06: claimed 16 → actual 2 (8x drift); claimed 3 → actual 1.
#
# This script forces measurement against the working tree before the
# claim is acted on (sprint planning, PR scoping, RFC drafting).
#
# Usage
#   verify_audit_claim.sh <expected_count> <pattern> <path...>
#
# Example
#   verify_audit_claim.sh 16 'match !policy_config with' lib/keeper/keeper_tool_policy.ml
#   verify_audit_claim.sh 3  'match !'                    lib/relay.ml
#
# Exit code 0 = match, 1 = mismatch, 2 = invocation error.
# stdout: actual count + commit hash + per-file breakdown.

set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <expected_count> <pattern> <path...>" >&2
  exit 2
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: ripgrep (rg) is required" >&2
  exit 2
fi

EXPECTED="$1"; shift
PATTERN="$1"; shift
PATHS=("$@")

# Force measurement against committed working tree, not stale assumption.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git status --porcelain 2>/dev/null | head -1)

ACTUAL=0
echo "=== verify_audit_claim ==="
echo "  commit:    $COMMIT$([ -n "$DIRTY" ] && echo " (dirty)" || true)"
echo "  pattern:   $PATTERN"
echo "  expected:  $EXPECTED"
echo "  per-path:"
for p in "${PATHS[@]}"; do
  if [ ! -e "$p" ]; then
    echo "    $p: <missing>"
    continue
  fi
  N=$(rg -c -- "$PATTERN" "$p" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
  ACTUAL=$((ACTUAL + N))
  echo "    $p: $N"
done
echo "  actual:    $ACTUAL"

if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "  result:    OK"
  exit 0
fi

if [ "$ACTUAL" -lt "$EXPECTED" ]; then
  RATIO=$(awk -v a="$ACTUAL" -v e="$EXPECTED" 'BEGIN{ if(a==0) print "inf"; else printf "%.1fx\n", e/a }')
  echo "  result:    MISMATCH — claim overstated by $RATIO"
else
  echo "  result:    MISMATCH — actual exceeds claim (under-counted audit)"
fi
exit 1
