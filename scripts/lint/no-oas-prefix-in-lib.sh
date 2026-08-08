#!/usr/bin/env bash
# RFC-0047 Phase 7: prevent reintroduction of `oas_*` prefix in masc lib/.
#
# Why this gate exists:
#   The internal agent engine lives under packages/agent_core and exposes the
#   masc.agent_core library. The `oas_*` prefix in masc's coordinator lib/
#   historically accumulated as a dumping ground that conflated agent-core
#   invocation, runtime strategy, and Keeper bookkeeping. RFC-0047 retired
#   that prefix across 9 phases. This gate prevents recurrence.
#
# Signal:
#   Any tracked source file matching `lib/**/oas_*.{ml,mli}`. Such a file
#   would imply masc consumer code is being labeled as if it were
#   OAS itself.
#
# Allowed location for the internal engine: packages/agent_core/.
# Coordinator adapters use explicit masc_agent_core_* names.
#
# RFC: docs/rfc/RFC-0047-oas-adapter-decomposition.md

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Any depth under lib/, not just its top level. The prefix came back twice
# after RFC-0047 closed — lib/oas_compat/ (2026-07-03) and
# lib/server/oas_diag_sink.ml (2026-07-19) — because `ls lib/oas_*` never
# looked into a subdirectory.
violations=$(find lib -type f \( -name 'oas_*.ml' -o -name 'oas_*.mli' \) 2>/dev/null | sort || true)

if [ -n "$violations" ]; then
  echo "ERROR: lib/**/oas_*.{ml,mli} files reintroduced. The oas_* prefix in"
  echo "masc/lib/ was retired by RFC-0047. The agent engine lives under"
  echo "packages/agent_core and is owned by the masc.agent_core library."
  echo ""
  echo "Violating files:"
  echo "$violations" | sed 's/^/  - /'
  echo ""
  echo "Move into the layer where the file actually belongs:"
  echo "  - Runtime strategy           -> lib/runtime/runtime_*.ml"
  echo "  - Keeper bookkeeping         -> lib/keeper/keeper_*.ml"
  echo "  - Agent-core wrapping        -> an explicit coordinator bridge"
  echo ""
  echo "See docs/rfc/RFC-0047-oas-adapter-decomposition.md."
  exit 1
fi

echo "OK: no lib/**/oas_*.{ml,mli} files (RFC-0047 prefix retirement preserved)."
