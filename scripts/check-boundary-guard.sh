#!/usr/bin/env bash
# Boundary ratchet: counts known MASC/OAS boundary violations.
# Fails if any count exceeds its baseline, preventing new violations.
# Lower baselines as violations are fixed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

check() {
  local label="$1" baseline="$2" pattern="$3" path="$4"
  if [[ ! -e "$REPO_ROOT/$path" ]]; then
    echo "BOUNDARY ERROR: $label — path $path does not exist"
    rc=1
    return
  fi
  local count
  count="$(grep -rn --include='*.ml' --include='*.mli' "$pattern" "$REPO_ROOT/$path" 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [[ "$count" -gt "$baseline" ]]; then
    echo "BOUNDARY FAIL: $label — found $count (baseline $baseline)"
    grep -rn --include='*.ml' --include='*.mli' "$pattern" "$REPO_ROOT/$path" 2>/dev/null | head -5
    rc=1
  elif [[ "$count" -lt "$baseline" ]]; then
    echo "BOUNDARY INFO: $label — found $count (baseline $baseline) — consider lowering baseline"
  fi
}

# V2: MASC-specific importance_scores in keeper working_context wrapper
# These wrap OAS Context.t with domain-specific scoring that should
# be handled by OAS custom closures instead.
check "V2-importance-scores" 8 \
  'importance_scores' \
  "lib/keeper/"

# V4: MASC domain marker constant definitions (message content pollution)
# Allowed: keeper_working_context.ml (goal_prefix, state_block_start),
#          context_compact_oas.ml (memory_summary_prefix),
#          tool_goals.ml (goal_prefix)
check "V4-marker-definitions" 5 \
  'let goal_prefix\|let memory_summary_prefix\|let state_block_start' \
  "lib/"

# V5: Direct OAS Memory.store calls from MASC bridge code
# Allowed: memory_oas_bridge.ml (2 actual calls + 5 comments/docs)
check "V5-memory-store-bypass" 5 \
  'Memory\.store[^_]' \
  "lib/memory_oas_bridge.ml"

# V6: OAS lifecycle orchestration from keeper_agent_run
# Memory_oas_bridge + Oas_worker.run_named calls should be isolated
# to a thin bridge; currently spread in keeper_agent_run.ml.
check "V6-oas-orchestration" 4 \
  'Memory_oas_bridge\|Oas_worker\.run_named' \
  "lib/keeper/keeper_agent_run.ml"

# V7: MASC-specific safety gates in OAS hook layer
# Eval_gate destructive detection and keeper deny list should be
# injected via OAS hook config, not hardcoded in hook callbacks.
check "V7-masc-hook-gates" 6 \
  'Eval_gate\.detect_destructive\|keeper_denied_tools' \
  "lib/keeper/keeper_hooks_oas.ml"

# V8: Direct OAS Agent.state mutation from keeper code
# Allowed: keeper_extend_turns.ml (2 occurrences)
check "V8-agent-state-mutation" 2 \
  'Agent\.set_state\|Agent_sdk\.Agent\.state[^_]' \
  "lib/keeper/"

# V9: MASC_LLAMA env var coupling (should migrate to MASC_LOCAL_*)
# 7 remaining: 6 backward-compat fallbacks in env_config_runtime.ml
# + 1 Deprecated registry entry in feature_flag_registry.ml.
check "V9-masc-llama-envvar" 7 \
  'MASC_LLAMA' \
  "lib/"

if [[ "$rc" -eq 0 ]]; then
  echo "BOUNDARY: all checks within baseline"
fi
exit "$rc"
