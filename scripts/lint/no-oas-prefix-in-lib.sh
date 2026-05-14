#!/usr/bin/env bash
# RFC-0047 Phase 7: prevent reintroduction of `oas_*` prefix in masc-mcp lib/.
#
# Why this gate exists:
#   Real OAS lives in a separate repository (~/me/workspace/yousleepwhen/oas)
#   exposed as the agent_sdk opam library. masc-mcp is a *consumer* of
#   agent_sdk. The `oas_*` prefix in masc-mcp's own lib/ historically
#   accumulated as a dumping ground that conflated three concerns
#   (Agent SDK invocation / cascade strategy / keeper bookkeeping) into
#   a single layer. RFC-0047 retired the prefix across 9 phases (16
#   files redistributed to lib/cascade/, lib/keeper/, or renamed to
#   agent_sdk_*). This gate prevents recurrence.
#
# Signal:
#   Any tracked source file matching `lib/oas_*.{ml,mli}`. Such a file
#   would imply masc-mcp consumer code is being labeled as if it were
#   OAS itself.
#
# Allowed location for OAS code: ~/me/workspace/yousleepwhen/oas/ (separate repo).
# Allowed prefixes in masc-mcp lib/ for agent_sdk-adjacent code:
#   agent_sdk_call.ml (Phase 4b-split target, deferred)
#   agent_sdk_response.ml
#   agent_sdk_log_bridge.ml
#   agent_sdk_metrics_bridge.ml
#
# RFC: docs/rfc/RFC-0047-oas-adapter-decomposition.md

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

violations=$(ls lib/oas_*.ml lib/oas_*.mli 2>/dev/null || true)

if [ -n "$violations" ]; then
  echo "ERROR: lib/oas_*.{ml,mli} files reintroduced. The oas_* prefix in"
  echo "masc-mcp/lib/ was retired by RFC-0047. Real OAS lives in a separate"
  echo "repository (~/me/workspace/yousleepwhen/oas, agent_sdk opam library)."
  echo ""
  echo "Violating files:"
  echo "$violations" | sed 's/^/  - /'
  echo ""
  echo "Move into the layer where the file actually belongs:"
  echo "  - Cascade strategy           -> lib/cascade/cascade_*.ml"
  echo "  - Keeper bookkeeping         -> lib/keeper/keeper_*.ml"
  echo "  - Pure agent_sdk wrapping    -> lib/agent_sdk_*.ml"
  echo ""
  echo "See docs/rfc/RFC-0047-oas-adapter-decomposition.md."
  exit 1
fi

echo "OK: no lib/oas_*.{ml,mli} files (RFC-0047 prefix retirement preserved)."
