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

check_forbidden_active() {
  local label="$1" pattern="$2"
  shift 2
  local hits=()
  local path
  for path in "$@"; do
    if [[ ! -e "$REPO_ROOT/$path" ]]; then
      echo "BOUNDARY ERROR: $label — path $path does not exist"
      rc=1
      continue
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] || hits+=("$line")
    done < <(
      grep -rnE \
        --include='*.ml' --include='*.mli' \
        --include='*.ts' --include='*.tsx' \
        --include='*.py' --include='*.rs' \
        --include='*.md' --include='*.json' \
        "$pattern" "$REPO_ROOT/$path" 2>/dev/null || true
    )
  done

  if [[ "${#hits[@]}" -gt 0 ]]; then
    echo "BOUNDARY FAIL: $label — found ${#hits[@]} forbidden active-source match(es)"
    printf '%s\n' "${hits[@]:0:8}"
    rc=1
  else
    echo "BOUNDARY INFO: $label — no forbidden active-source matches"
  fi
}

# V2: MASC-specific importance_scores in keeper working_context wrapper
# These wrap OAS Context.t with domain-specific scoring that should
# be handled by OAS custom closures instead.
check "V2-importance-scores" 0 \
  'importance_scores' \
  "lib/keeper/"

# V4: MASC domain marker constant definitions (message content pollution)
# Allowed: keeper_working_context.ml (goal_prefix),
#          context_compact_oas.ml (memory_summary_prefix),
#          tool_goals.ml (goal_prefix)
check "V4-marker-definitions" 2 \
  'let goal_prefix\|let memory_summary_prefix' \
  "lib/"

# V4b: retired model-authored state and introspection protocols are zero-pinned.
# Decision-history RFC tombstones and negative regression tests are intentionally
# outside this active product-source scan.
check_forbidden_active "V4b-retired-state-protocol-zero-pin" \
  '\[STATE\]|NEXT Constraints|OpenQuestions|SOCIAL_MODEL|MASC_STRUCTURED_STATE|state_block_start|keeper_working_state|keeper_state_block_prompt|meta_cognition|continuity_judgment|continuity_verdict|continuity_similarity|auto_rules|(^|[^[:alnum:]_])BDI([^[:alnum:]_]|$)' \
  "lib/" \
  "bin/" \
  "dashboard/src/" \
  "dashboard_bonsai/src/" \
  "sidecars/" \
  "viewer/src/" \
  "config/prompts/" \
  "config/personas/"

# V6: OAS lifecycle orchestration from keeper_agent_run
# Oas_worker.run_named calls should be isolated to a thin bridge.
check "V6-oas-orchestration" 0 \
  'Oas_worker\.run_named' \
  "lib/keeper/keeper_agent_run.ml"

# V7: retired command-semantics authorization must not return.
check_forbidden_active "V7-retired-command-semantics-gates" \
  'Eval_gate|Destructive_ops_policy|Shell_safety_types|keeper_denied_tools' \
  "lib/" \
  "bin/" \
  "config/"

# V7b: retired authorization hierarchy and its derived floors must stay gone.
check_forbidden_active "V7b-retired-authorization-hierarchy" \
  'hard_forbidden|auto_approval_hard_forbidden|R0_Read|R1_Reversible|R2_Irreversible|Destructive_protected|requires_operator_authorization|requires_separate_human_grant|risk_floor|max_risk|privileged_floor|destructive_floor|catastrophic_floor|operator_only_floor|automatic_eligibility' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/" \
  "dashboard_bonsai/src/" \
  "sidecars/" \
  "viewer/src/"

# V7c: Task completion is a full-input LLM judgment, not a local substring
# advisory or arbitrary byte-window judgment.
check_forbidden_active "V7c-task-completion-semantic-heuristics" \
  'excuse_pattern|excuse-pattern|gate2_advisory|Advisory_to_llm|utf8_safe.*(303|503)' \
  "lib/task/" \
  "test/" \
  "config/prompts/" \
  "dashboard/src/"

# V7d: observed reputation data must not be converted into an authorization
# rank or a read-vs-mutate verifier shortcut.
check_forbidden_active "V7d-retired-derived-autonomy-and-effect-classes" \
  'Reputation_autonomy|autonomy_level|Effect_class|effect_class_for_tool_name' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/"

# V7e: pre-tool hooks observe timing only. Tool-name aliases and caller
# callbacks must not form a second authorization boundary ahead of Gate.
check_forbidden_active "V7e-retired-pre-tool-alias-blocker" \
  'Keeper_guards|pre_tool_use_guard|public_alias_pre_tool_use_guard|public_alias_guidance_for_internal_call|custom_guard|reject_by_default|mark_turn_gate_rejected_by_name|Decision_gate_rejected|Action_gate_rejected|Turn_gate_rejected|GuardsFailures|TurnGateRejectedTerminal' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/"

# V7f: rendered subprocess output is evidence, never a retry classifier.
# Typed Unix.EINTR handling remains in the process I/O layer and is not matched
# by this ratchet.
check_forbidden_active "V7f-retired-subprocess-text-retry" \
  'max_eintr_retries|retry_eintr|filter_environment_c_messages|interrupted system call' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/"

check_forbidden_active "V7g-retired-subprocess-message-locale-pin" \
  'LC_MESSAGES=C' \
  "lib/" \
  "bin/" \
  "config/"

# V7h: tool failures remain exact producer outcomes. No local failure-class
# streak, cooling window, prompt injection, or display-state hierarchy.
check_forbidden_active "V7h-retired-keeper-failure-circuit-breaker" \
  'Keeper_failure_circuit_breaker|keeper_failure_circuit_breaker|KeeperCircuitBreaker|CircuitBreakerTrips' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/" \
  "specs/"

# V7i: dispatch never invents tool-search rankings or typo suggestions. Tool
# search is provided by an injected session index or reports unavailable.
check_forbidden_active "V7i-retired-dispatch-tool-search-heuristics" \
  'score_tool_schema|static_schema_fallback|default_tool_search_fn|tutor_alias_of_requested_name|tool_tutor_for_unknown_name|did_you_mean' \
  "lib/keeper/"

# V7j: one failed call cannot create state that blocks, suppresses, or rewrites
# a later tool call. Exact results remain independent observations.
check_forbidden_active "V7j-retired-consecutive-tool-failure-guard" \
  'Keeper_tool_retry_state|keeper_tool_retry_state|MASC_KEEPER_MAX_CONSECUTIVE_TOOL_FAILURES|max_consecutive_tool_failures|workflow_rejection_recovery_fields|workflow_rejection_recovery_instruction|self_correction_required|retry_skipped|ToolsOasDeterministicFailures|transient_mutex_contention_error_class' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/" \
  "specs/"

# V8: Direct OAS Agent.state mutation from keeper code
# Baseline 0: legacy keeper_extend_turns.ml was removed.
check "V8-agent-state-mutation" 0 \
  'Agent\.set_state\|Agent_sdk\.Agent\.state[^_]' \
  "lib/keeper/"

# V9: MASC_LLAMA env var coupling (should migrate to MASC_LOCAL_*)
# The compatibility surface is fully removed; pin it at zero.
check "V9-masc-llama-envvar" 0 \
  'MASC_LLAMA' \
  "lib/"

# V10: OAS-owned provider filters must not be re-owned outside compatibility loaders/scrubbers.
# The .mli of keeper_meta_json_scrub is the public interface for the already-allowed
# .ml; the doc-comment legitimately surfaces the legacy key name in its API contract.
check_forbidden_outside "V10-provider-filter-ownership" \
  'allowed_providers' \
  "lib/" \
  "lib/keeper_types/keeper_types.ml" \
  "lib/keeper_types/keeper_types.mli" \
  "lib/keeper/keeper_meta_json_scrub.ml" \
  "lib/keeper/keeper_meta_json_scrub.mli" \
  "lib/keeper/keeper_config.ml" \
  "lib/keeper/keeper_config_text.ml" \
  "lib/keeper/keeper_config_text.mli"

# V11: proof-store layout knowledge must stay inside the contract proof-store owner
# and proof reader adapter.
check_forbidden_outside "V11-proof-store-layout" \
  'Filename\.concat .*"proofs"' \
  "lib/" \
  "lib/cdal_runtime/proof_store.ml" \
  "lib/cdal_runtime/proof_store.mli" \
  "lib/cdal/proof_artifact_reader.ml" \
  "lib/cdal/proof_artifact_reader.mli"

# V12: oas-runtime session root literal must stay inside the runtime path adapter.
check_forbidden_outside "V12-oas-runtime-layout" \
  '"oas-runtime"' \
  "lib/" \
  "lib/local/worker_container.ml"

if [[ "$rc" -eq 0 ]]; then
  echo "BOUNDARY: all checks within baseline"
fi
exit "$rc"
