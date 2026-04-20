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

check_forbidden_outside() {
  local label="$1" pattern="$2" path="$3"
  shift 3
  local allowed=("$@")
  if [[ ! -e "$REPO_ROOT/$path" ]]; then
    echo "BOUNDARY ERROR: $label — path $path does not exist"
    rc=1
    return
  fi
  local hits=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local file="${line%%:*}"
    local allowed_hit=0
    local rel_file="${file#$REPO_ROOT/}"
    for allow in "${allowed[@]}"; do
      if [[ "$rel_file" == "$allow" ]]; then
        allowed_hit=1
        break
      fi
    done
    if [[ "$allowed_hit" -eq 0 ]]; then
      hits+=("$line")
    fi
  done < <(grep -rn --include='*.ml' --include='*.mli' "$pattern" "$REPO_ROOT/$path" 2>/dev/null || true)

  if [[ "${#hits[@]}" -gt 0 ]]; then
    echo "BOUNDARY FAIL: $label — found ${#hits[@]} forbidden match(es)"
    printf '%s\n' "${hits[@]:0:5}"
    rc=1
  else
    echo "BOUNDARY INFO: $label — no forbidden matches"
  fi
}

# V2: MASC-specific importance_scores in keeper working_context wrapper
# These wrap OAS Context.t with domain-specific scoring that should
# be handled by OAS custom closures instead.
check "V2-importance-scores" 0 \
  'importance_scores' \
  "lib/keeper/"

# V4: MASC domain marker constant definitions (message content pollution)
# Allowed: keeper_working_context.ml (goal_prefix, state_block_start),
#          context_compact_oas.ml (memory_summary_prefix),
#          tool_goals.ml (goal_prefix)
check "V4-marker-definitions" 2 \
  'let goal_prefix\|let memory_summary_prefix\|let state_block_start' \
  "lib/"

# V5: Direct OAS Memory.store calls from MASC bridge code
# Allowed: memory_oas_bridge.ml (2 actual calls + 5 comments/docs)
check "V5-memory-store-bypass" 1 \
  'Memory\.store[^_]' \
  "lib/memory_oas_bridge.ml"

# V6: OAS lifecycle orchestration from keeper_agent_run
# Memory_oas_bridge + Oas_worker.run_named calls should be isolated
# to a thin bridge; currently spread in keeper_agent_run.ml.
check "V6-oas-orchestration" 5 \
  'Memory_oas_bridge\|Oas_worker\.run_named' \
  "lib/keeper/keeper_agent_run.ml"

# V7: MASC-specific safety gates in OAS hook layer
# Eval_gate destructive detection and keeper deny list should be
# injected via OAS hook config, not hardcoded in hook callbacks.
check "V7-masc-hook-gates" 4 \
  'Eval_gate\.detect_destructive\|keeper_denied_tools' \
  "lib/keeper/keeper_hooks_oas.ml"

# V8: Direct OAS Agent.state mutation from keeper code
# Allowed: keeper_extend_turns.ml (2 occurrences)
check "V8-agent-state-mutation" 1 \
  'Agent\.set_state\|Agent_sdk\.Agent\.state[^_]' \
  "lib/keeper/"

# V9: MASC_LLAMA env var coupling (should migrate to MASC_LOCAL_*)
# 4 remaining after backward-compat fallbacks were trimmed; surface is
# contained to env_config_runtime.ml + the Deprecated registry entry.
check "V9-masc-llama-envvar" 4 \
  'MASC_LLAMA' \
  "lib/"

# V10: OAS-owned provider filters must not be re-owned outside compatibility loaders.
check_forbidden_outside "V10-provider-filter-ownership" \
  'allowed_providers' \
  "lib/" \
  "lib/keeper/keeper_types.ml"

# V11: proof-store layout knowledge must stay inside the proof reader adapter.
check_forbidden_outside "V11-proof-store-layout" \
  'Filename\.concat .*"proofs"' \
  "lib/" \
  "lib/proof_artifact_reader.ml"

# V12: oas-runtime session root literal must stay inside the runtime path adapter.
check_forbidden_outside "V12-oas-runtime-layout" \
  '"oas-runtime"' \
  "lib/" \
  "lib/local/worker_container.ml"

if [[ "$rc" -eq 0 ]]; then
  echo "BOUNDARY: all checks within baseline"
fi
exit "$rc"
