#!/usr/bin/env bash
# CI gate: MASC->OAS boundary violation detection (BND).
# Meta-issue: #9519
#
# CONTRACT:
#   - OAS must not reference masc_ prefix or MASC modules.
#   - MASC must use OAS public APIs (Agent.run, context_injector, etc.)
#     rather than reimplementing lifecycle/retry/budget logic.
#   - MASC must not touch OAS internal modules (Oas_worker internals,
#     Oas_response raw constructors, etc.)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exit_code=0

# 1. OAS files referencing masc_ prefix (forbidden)
echo "=== Scan: OAS -> MASC back-reference ==="
oas_matches=$(
  rg -n 'masc_\|MASC' lib/oas_*.ml lib/oas_*.mli \
  --type ml 2>/dev/null || true
)
if [ -n "$oas_matches" ]; then
  echo "FAIL: OAS module references MASC (boundary violation):"
  echo "$oas_matches" | head -20
  exit_code=1
else
  echo "PASS"
fi

# 2. MASC files that reimplement OAS patterns (heuristic)
#    We look for OAS lifecycle patterns inside MASC modules that should
#    instead call Oas_agent.run or similar.
echo "=== Scan: MASC lifecycle reimplementation heuristic ==="
# List of patterns that indicate MASC is doing OAS's job
masc_matches=$(
  rg -n 'retry_count\|backoff_ms\|budget_remaining\|context_window\|token_budget' \
    lib/keeper/ lib/masc_*.ml --type ml 2>/dev/null || true
)
if [ -n "$masc_matches" ]; then
  echo "WARN: MASC files contain OAS-reserved concepts (verify they call OAS, not reimplement):"
  echo "$masc_matches" | head -20
fi

# 3. MASC using Oas_worker internal constructors instead of public API
echo "=== Scan: MASC -> Oas_worker internal constructor use ==="
internal_matches=$(
  rg -n 'Oas_response\.\|Oas_worker\.run_raw\|Oas_worker\.internal' \
    lib/keeper/ lib/masc_*.ml --type ml 2>/dev/null || true
)
if [ -n "$internal_matches" ]; then
  echo "WARN: MASC uses Oas_worker internal-looking identifiers:"
  echo "$internal_matches" | head -20
fi

if [ "$exit_code" -eq 0 ]; then
  echo "=== BND gate: PASS ==="
else
  echo "=== BND gate: FAIL ==="
fi

exit "$exit_code"
