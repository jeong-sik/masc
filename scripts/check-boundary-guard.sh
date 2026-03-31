#!/usr/bin/env bash
# Boundary ratchet: counts known MASC/OAS boundary violations.
# Fails if any count exceeds its baseline, preventing new violations.
# Lower baselines as violations are fixed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

check() {
  local label="$1" baseline="$2" pattern="$3" path="$4"
  local count
  count="$(grep -rn "$pattern" "$REPO_ROOT/$path" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -gt "$baseline" ]]; then
    echo "BOUNDARY FAIL: $label — found $count (baseline $baseline)"
    grep -rn "$pattern" "$REPO_ROOT/$path" 2>/dev/null | head -5
    rc=1
  elif [[ "$count" -lt "$baseline" ]]; then
    echo "BOUNDARY INFO: $label — found $count (baseline $baseline) — consider lowering baseline"
  fi
}

# V8: Direct OAS Agent.state mutation from keeper code
# Allowed: keeper_extend_turns.ml (2 occurrences)
check "V8-agent-state-mutation" 2 \
  'Agent\.set_state\|Agent_sdk\.Agent\.state ' \
  "lib/keeper/"

# V4: MASC domain marker constant definitions (message content pollution)
# Allowed: keeper_working_context.ml (goal_prefix, state_block_start),
#          context_compact_oas.ml (memory_summary_prefix)
check "V4-marker-definitions" 5 \
  'let goal_prefix\|let memory_summary_prefix\|let state_block_start' \
  "lib/"

# V5: Direct OAS Memory.store calls from MASC bridge code
# Allowed: memory_oas_bridge.ml (2 actual calls + 5 comments/docs)
check "V5-memory-store-bypass" 7 \
  'Memory\.store' \
  "lib/memory_oas_bridge.ml"

if [[ "$rc" -eq 0 ]]; then
  echo "BOUNDARY: all checks within baseline"
fi
exit "$rc"
