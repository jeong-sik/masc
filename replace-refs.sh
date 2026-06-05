#!/bin/bash
set -e
cd "$1"

PATTERNS='
s/masc\.keeper_accountability_claim_types/masc.keeper_core_types/g;
s/masc\.keeper_approval_queue_rules_types/masc.keeper_core_types/g;
s/masc\.keeper_failure_circuit_breaker_types/masc.keeper_core_types/g;
s/masc\.keeper_registry_types_compaction/masc.keeper_core_types/g;
s/masc\.keeper_registry_types_decision/masc.keeper_core_types/g;
s/masc\.keeper_registry_types_kill_class/masc.keeper_core_types/g;
s/masc\.keeper_registry_types_turn_phase/masc.keeper_core_types/g;
s/masc\.keeper_transition_audit_types/masc.keeper_core_types/g;
s/masc\.keeper_turn_slot_types/masc.keeper_core_types/g;
s/masc\.keeper_types\b/masc.keeper_core_types/g;
s/masc\.keeper_types_profile_sandbox/masc.keeper_core_types/g;
s/masc\.keeper_id\b/masc.keeper_core_types/g;
s/masc\.keeper_attempt_liveness/masc.keeper_lifecycle/g;
s/masc\.keeper_binding_health_config/masc.keeper_lifecycle/g;
s/masc\.keeper_lifecycle_events/masc.keeper_lifecycle/g;
s/masc\.keeper_event_bus\b/masc.keeper_lifecycle/g;
s/masc\.keeper_event_queue\b/masc.keeper_lifecycle/g;
s/masc\.keeper_failure_taxonomy/masc.keeper_failure/g;
s/masc\.keeper_failure_policy\b/masc.keeper_failure/g;
s/masc\.keeper_path_rejection/masc.keeper_failure/g;
s/masc\.keeper_terminal_reason/masc.keeper_failure/g;
s/masc\.keeper_internal_error\b/masc.keeper_failure/g;
s/masc\.keeper_invariant\b/masc.keeper_failure/g;
s/masc\.keeper_recording_error_state/masc.keeper_failure/g;
s/masc\.keeper_runtime_config/masc.keeper_runtime/g;
s/masc\.keeper_runtime_manifest_types/masc.keeper_runtime/g;
s/masc\.keeper_toml_loader/masc.keeper_runtime/g;
s/masc\.keeper_toml_parser/masc.keeper_runtime/g;
s/masc\.keeper_metrics\b/masc.keeper_telemetry/g;
s/masc\.keeper_measurement\b/masc.keeper_telemetry/g;
s/masc\.keeper_timing\b/masc.keeper_telemetry/g;
s/masc\.keeper_token_count/masc.keeper_telemetry/g;
s/masc\.keeper_usage_trust/masc.keeper_telemetry/g;
s/masc\.keeper_benchmark_canary/masc.keeper_telemetry/g;
s/masc\.keeper_outcome_taxonomy/masc.keeper_outcome/g;
s/masc\.keeper_oas_timeout_message/masc.keeper_outcome/g;
s/masc\.keeper_social_model_types/masc.keeper_world/g;
s/masc\.keeper_synthetic_marker/masc.keeper_world/g;
s/masc\.keeper_prompt_names/masc.keeper_world/g;
s/masc\.keeper_world_observation_turn_types/masc.keeper_world/g;
s/masc\.keeper_workspace_op/masc.keeper_workspace/g;
s/masc\.keeper_provider_error_class/masc.keeper_workspace/g;
s/masc\.keeper_hooks_oas_types/masc.keeper_workspace/g;
s/masc\.keeper_sandbox_error/masc.keeper_workspace/g;
s/masc\.keeper_pressure\b/masc.keeper_workspace/g;
s/masc\.keeper_voice_local/masc.keeper_workspace/g;
s/masc\.keeper_discovered_tools/masc.keeper_tooling/g;
s/masc\.keeper_tool_command_parse/masc.keeper_tooling/g;
s/masc\.keeper_tool_execute_shell_ir/masc.keeper_tooling/g;
s/masc\.keeper_tool_execute_timeout/masc.keeper_tooling/g;
s/masc\.keeper_tool_hook_error_state/masc.keeper_tooling/g;
s/masc\.keeper_tool_name\b/masc.keeper_tooling/g;
s/masc\.keeper_tool_response/masc.keeper_tooling/g;
s/masc\.keeper_tool_retry_state/masc.keeper_tooling/g;
s/masc\.keeper_skill_routing/masc.keeper_tooling/g;
'

find lib/ bin/ -name 'dune' -print0 | xargs -0 perl -pi -e "$PATTERNS"

echo "References updated."
