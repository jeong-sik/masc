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
check "V4-marker-definitions" 0 \
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
  'hard_forbidden|auto_approval_hard_forbidden|R0_Read|R1_Reversible|R2_Irreversible|Destructive_protected|requires_operator_authorization|requires_separate_human_grant|risk_floor|max_risk|privileged_floor|destructive_floor|catastrophic_floor|operator_only_floor|automatic_eligibility|External_only|external_only_board_route' \
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
  'Keeper_tool_retry_state|keeper_tool_retry_state|Keeper_tool_hook_error_state|keeper_tool_hook_error_state|MASC_KEEPER_MAX_CONSECUTIVE_TOOL_FAILURES|max_consecutive_tool_failures|workflow_rejection_recovery_fields|workflow_rejection_recovery_instruction|self_correction_required|retry_skipped|ToolsOasDeterministicFailures|transient_mutex_contention_error_class' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/" \
  "specs/"

# V7k: dispatch and failover must use exact producer outcomes. Read-only,
# idempotency, inferred path keys, or a generic mutation boundary must not be
# reintroduced as behavioral retry/authorization classifiers.
check_forbidden_active "V7k-retired-dispatch-effect-inference" \
  'read_only_retry|readonly_retry|MASC_TOOL_READONLY_RETRY_LIMIT|masc_path_blocked|oas_descriptor_of_masc_tool|MutationBoundaryReached|mutation_boundary_reached|is_idempotent.*is_read_only|idempotent[[:space:]]*=[[:space:]]*readonly|Tool_capability\.Idempotent,[[:space:]]*Some[[:space:]]+true' \
  "lib/" \
  "bin/" \
  "test/" \
  "config/" \
  "dashboard/src/"

# V7l: the generic Gate/dispatch bridge receives opaque operation identities.
# Product and CLI names belong to connector/tool adapters, never this boundary.
check_forbidden_active "V7l-generic-gate-product-knowledge" \
  'GitHub|github_app|github-app|(^|[^[:alnum:]_])gh([^[:alnum:]_]|$)' \
  "lib/keeper/keeper_gate.ml" \
  "lib/keeper/keeper_gate.mli" \
  "lib/keeper/keeper_tool_shared_runtime.ml" \
  "lib/keeper/keeper_tool_shared_runtime.mli" \
  "lib/keeper/keeper_tool_dispatch_runtime.ml" \
  "lib/keeper/keeper_tool_dispatch_runtime.mli" \
  "lib/tool_bridge.ml" \
  "lib/tool_bridge.mli"

# V7m: MCP transport projects the producer's typed Tool_result. Free-form
# message prose must not synthesize follow-up actions, quality verdicts, or
# recovery instructions in the model-facing response.
check_forbidden_active "V7m-mcp-message-semantics" \
  'contains_casefold|Masc_error_recovery|parse_status_from_message|quality_from_result|required_follow_up|Recovery:' \
  "lib/mcp_server_eio_call_tool.ml" \
  "lib/mcp_server_eio_call_tool.mli" \
  "lib/mcp_server_eio_protocol.ml" \
  "lib/mcp_server_eio_protocol.mli"

# V7n: the generic IDE/filesystem annotation boundary stores opaque
# relation/reference pairs. Product route identifiers belong to their owning
# adapters and must not return to this transport/storage path.
check_forbidden_active "V7n-generic-ide-product-routes" \
  'board_post_id|comment_id|pr_id|git_ref|log_id|session_id|operation_id|worker_run_id|(^|[^[:alnum:]_])Board([^[:alnum:]_]|$)|GitHub|github' \
  "lib/tool_surface/tool_shard_types_schemas_filesystem.ml" \
  "lib/keeper/keeper_tool_ide_runtime.ml" \
  "lib/agent_observation/agent_observation.ml" \
  "lib/agent_observation/agent_observation.mli" \
  "lib/ide/ide_annotation_types.ml" \
  "lib/ide/ide_annotation_types.mli" \
  "lib/ide/ide_annotations.ml" \
  "lib/ide/ide_annotations.mli" \
  "lib/ide/ide_bridge.ml" \
  "lib/server/lsp_overlay_provider.ml" \
  "lib/server/server_ide_http.ml" \
  "dashboard/src/api/schemas/ide-annotations.ts" \
  "dashboard/src/api/ide.ts" \
  "dashboard/src/components/ide/ide-annotation-rail.ts" \
  "dashboard/src/components/ide/ide-editor-annotation-ui.ts" \
  "dashboard/src/components/ide/ide-lsp-client.ts"

# Dashboard annotation consumers may display opaque reference pairs, but may
# not recover retired product routes by inspecting relation names or legacy
# annotation fields. Other IDE activity/event models retain their own typed
# product context and are intentionally outside this annotation-only ratchet.
check_forbidden_active "V7n-dashboard-annotation-reference-semantics" \
  'annotation\.(board_post_id|comment_id|pr_id|git_ref|log_id|session_id|operation_id|worker_run_id)|annotation\.references\.(find|filter|some)|reference\.relation[[:space:]]*(===|!==|==|!=)' \
  "dashboard/src/components/ide/"

# V7o: Keeper dispatch consumes producer-owned typed outcomes. Opaque output
# payloads must never be parsed or shape-tagged to reconstruct success/failure.
check_forbidden_active "V7o-retired-keeper-payload-outcome-classifier" \
  'classify_tool_result_payload|looks_like_structured_payload|inferred_outcome_of_result|payload_shape' \
  "lib/keeper/keeper_tool_dispatch_runtime.ml" \
  "lib/keeper/keeper_tool_dispatch_runtime.mli"

# V7p: the MASC/OAS tool-result bridge receives an opaque typed result. Tool
# identity and message JSON must not override externalization or failure class.
check_forbidden_active "V7p-tool-bridge-message-and-product-semantics" \
  'Board_post_get|masc_board_post_get|success_result_preserves_full_content|tool_error_metadata_from_json_message|tool_error_class_of_string|json_recoverable|json_error_class' \
  "lib/tool_bridge.ml" \
  "lib/tool_bridge.mli"

# V7q: timeout control flow comes from Agent SDK/provider constructors and
# typed timeout phases, never diagnostics embedded in message prose.
check_forbidden_active "V7q-timeout-message-semantics" \
  'Keeper_oas_timeout_message|is_structural_oas_timeout_message|api_error_oas_agent_execution_timeout' \
  "lib/keeper/" \
  "lib/keeper_runtime/"

# V7r: terminal reason decoding accepts canonical producer wires. Arbitrary
# text containing config/auth words must remain the typed unknown route.
check_forbidden_active "V7r-terminal-config-auth-substring-semantics" \
  'contains_config_or_auth|lowercase_ascii[[:space:]]+receipt\.terminal_reason_code|String_util\.contains_substring[^;]*(config|auth)' \
  "lib/keeper_runtime/keeper_terminal_reason.ml" \
  "lib/keeper_runtime/keeper_terminal_reason.mli" \
  "lib/keeper/keeper_execution_receipt.ml"

# V7s: schema families are an immutable catalog organization, never a second
# runtime authorization system. Keepers see the complete catalog and the Gate
# decides external effects.
check_forbidden_active "V7s-retired-runtime-tool-family-authorization" \
  'Mod_shard|masc_shard_|masc_tool_(list|grant|revoke)|get_agent_shards|set_agent_shards|remove_agent_shards|grant_shard|revoke_shard|recovery_minimum_shard_names|default_shard_names|tools_of_shards|agent_shards|read_only_tools[[:space:]]*:|removable[[:space:]]*:' \
  "lib/" \
  "bin/" \
  "config/"

# V7t: the withdrawn completion-trust hierarchy must not return as a public
# fixed-threshold CLI or its dedicated deterministic corpus.
check_forbidden_active "V7t-retired-completion-trust-cli" \
  'masc_completion_trust_eval|masc-completion-trust-eval|data/eval/completion_trust' \
  "bin/" \
  "data/" \
  "lib/" \
  "test/"

# V7u: dashboards expose typed runtime/FSM state, not the retired Thompson,
# recovery-floor, or runtime-shard worldview.
check_forbidden_active "V7u-retired-decision-pipeline-diagram" \
  'decision_pipeline_to_mermaid|decision_pipeline_mermaid|decision_pipeline_diagram' \
  "lib/" \
  "dashboard/src/"

# V7v: generic Tool_result constructors keep messages opaque. Structure and
# failure classes come only from explicitly typed producer fields.
check_forbidden_active "V7v-retired-tool-result-message-inference" \
  'structured_payload_of_message|classify_from_structured_failure_message' \
  "lib/" \
  "test/" \
  "dashboard/src/"

# V7w: dashboard presentation may pretty-print an outer JSON envelope but may
# not recover hidden structure from newline suffixes or nested string fields.
check_forbidden_active "V7w-retired-dashboard-embedded-json-coercion" \
  'extractEmbeddedJson|extractEmbeddedJsonSuffix|coerceEmbeddedJson|parseJsonContainer|ensureObject|prettyJsonDeep' \
  "dashboard/src/components/tool-call-shared.ts" \
  "dashboard/src/components/tool-call-shared.test.ts"

# V7x: task evidence, CAS retries, and recording outcomes remain typed producer
# facts. Free-form placeholders, prefixes, and local outcome classifiers stay
# retired.
check_forbidden_active "V7x-retired-task-and-recording-message-heuristics" \
  'placeholder_evidence_refs|is_placeholder_evidence_ref|max_cas_retries|version_mismatch_prefix|Keeper_recording_error_state\.classify_error|classify_outcome' \
  "lib/task/" \
  "lib/keeper_runtime/keeper_recording_error_state.ml" \
  "lib/keeper_runtime/keeper_recording_error_state.mli" \
  "test/"

# V7y: Keeper execution carries producer-owned typed data. The OAS/MCP
# projection must never reconstruct it from raw output strings or revive the
# retired product-marker/workflow parsers.
check_forbidden_active "V7y-retired-keeper-raw-output-reinterpretation" \
  'structured_error_payload|metadata_from_assoc|nested_payload_of_json|tool_exec_result_markers|Keeper_tools_oas_(markers|workflow|json)|data:[[:space:]]*\(`String result\.raw_output\)' \
  "lib/keeper/" \
  "lib/mcp_server_eio_execute.ml" \
  "test/"

# V7z: Connector ingress commits every exact producer event to its Keeper lane.
# Feature flags, time windows, channel activity, and Board wake-dedup state must
# not suppress durable Connector delivery.
check_forbidden_active "V7z-retired-connector-wake-suppression" \
  'MASC_CONNECTOR_AMBIENT_WAKE_ENABLED|connector_reactive_debounce_sec|connector_reactive_wakeup_allowed|connector_reactive_wake_throttle' \
  "lib/" \
  "test/" \
  "config/"

# V7aa: image/audio/document tool artifacts are normal typed Keeper data.
# Default-off rollout flags must not silently sever capture or wire-in.
check_forbidden_active "V7aa-retired-multimodal-rollout-gates" \
  'MASC_TOOL_EMISSION|MASC_MULTIMODAL|masc_tool_emission_enabled|masc_multimodal_enabled' \
  "lib/" \
  "config/" \
  "test/"

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
