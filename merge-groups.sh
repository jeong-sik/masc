#!/bin/bash
set -e
WT="$1"
cd "$WT"

# Group: keeper_core_types
mkdir -p lib/keeper_core_types
for src in keeper_accountability_claim_types keeper_approval_queue_rules_types keeper_failure_circuit_breaker_types keeper_registry_types_compaction keeper_registry_types_decision keeper_registry_types_kill_class keeper_registry_types_turn_phase keeper_transition_audit_types keeper_turn_slot_types keeper_types keeper_types_profile_sandbox keeper_id; do
  cp lib/$src/*.ml lib/keeper_core_types/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_core_types/ 2>/dev/null || true
done
cat > lib/keeper_core_types/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_core_types)
 (public_name masc.keeper_core_types)
 (wrapped false)
 (modules
  keeper_accountability_claim_types
  keeper_approval_queue_rules_types
  keeper_failure_circuit_breaker_types
  keeper_registry_types_compaction
  keeper_registry_types_decision
  keeper_registry_types_kill_class
  keeper_registry_types_turn_phase
  keeper_transition_audit_types
  keeper_turn_slot_types
  keeper_types
  keeper_types_profile_sandbox
  keeper_id)
 (libraries
  agent_sdk
  eio
  masc.config
  masc.exec_policy
  masc.keeper_measurement
  masc.keeper_path_rejection
  masc.keeper_state
  masc.masc_core
  masc.masc_types
  unix
  uuidm
  yojson)
 (preprocess
  (pps ppx_tla ppx_deriving_yojson ppx_deriving.show ppx_deriving.eq)))
DUNE
for src in keeper_accountability_claim_types keeper_approval_queue_rules_types keeper_failure_circuit_breaker_types keeper_registry_types_compaction keeper_registry_types_decision keeper_registry_types_kill_class keeper_registry_types_turn_phase keeper_transition_audit_types keeper_turn_slot_types keeper_types keeper_types_profile_sandbox keeper_id; do
  rm -rf lib/$src
done

# Group: keeper_lifecycle
mkdir -p lib/keeper_lifecycle
for src in keeper_attempt_liveness keeper_binding_health_config keeper_lifecycle_events keeper_event_bus keeper_event_queue; do
  cp lib/$src/*.ml lib/keeper_lifecycle/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_lifecycle/ 2>/dev/null || true
done
cat > lib/keeper_lifecycle/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_lifecycle)
 (public_name masc.keeper_lifecycle)
 (wrapped false)
 (modules
  keeper_attempt_liveness
  keeper_attempt_liveness_config
  keeper_attempt_liveness_observer
  keeper_binding_health_config
  keeper_lifecycle_events
  keeper_event_bus
  keeper_event_queue)
 (libraries
  agent_sdk
  agent_sdk.llm_provider
  eio
  masc.config
  masc.keeper_state
  masc.types_boundary
  masc_core
  masc_log
  time_compat
  unix
  uri))
DUNE
for src in keeper_attempt_liveness keeper_binding_health_config keeper_lifecycle_events keeper_event_bus keeper_event_queue; do
  rm -rf lib/$src
done

# Group: keeper_failure
mkdir -p lib/keeper_failure
for src in keeper_failure_taxonomy keeper_failure_policy keeper_path_rejection keeper_terminal_reason keeper_internal_error keeper_invariant keeper_recording_error_state; do
  cp lib/$src/*.ml lib/keeper_failure/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_failure/ 2>/dev/null || true
done
cat > lib/keeper_failure/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_failure)
 (public_name masc.keeper_failure)
 (wrapped false)
 (modules
  keeper_alert_persist_kind
  keeper_approval_queue_failure_site
  keeper_bookkeeping_failure_kind
  keeper_checkpoint_failure_operation
  keeper_checkpoint_store_failure_site
  keeper_compact_audit_failure_site
  keeper_crash_persistence_failure_site
  keeper_execution_receipt_failure_site
  keeper_fs_failure_site
  keeper_generation_lineage_failure_site
  keeper_metric_emit_dropped_site
  keeper_metrics_sse_failure_kind
  keeper_paused_state_persist_phase
  keeper_post_turn_wirein_failure_site
  keeper_profile_load_failure_site
  keeper_supervisor_cleanup_failure_site
  keeper_turn_cleanup_failure_site
  keeper_turn_metrics_snapshot_failure_site
  keeper_turn_up_update_failure_site
  keeper_write_meta_cycle_failure_site
  keeper_failure_policy
  keeper_path_rejection
  keeper_terminal_reason
  keeper_internal_error
  keeper_invariant
  keeper_recording_error_state)
 (libraries
  masc.bounded_event_dedupe
  masc.json_field
  masc.masc_core
  masc.masc_types
  masc.prometheus
  agent_sdk
  yojson)
 (preprocess
  (pps ppx_deriving_yojson ppx_deriving.show ppx_deriving.eq))
 (flags (:standard -w +4)))
DUNE
for src in keeper_failure_taxonomy keeper_failure_policy keeper_path_rejection keeper_terminal_reason keeper_internal_error keeper_invariant keeper_recording_error_state; do
  rm -rf lib/$src
done

# Group: keeper_runtime
mkdir -p lib/keeper_runtime
for src in keeper_runtime_config keeper_runtime_manifest_types keeper_toml_loader keeper_toml_parser; do
  cp lib/$src/*.ml lib/keeper_runtime/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_runtime/ 2>/dev/null || true
done
cat > lib/keeper_runtime/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_runtime)
 (public_name masc.keeper_runtime)
 (wrapped false)
 (modules
  keeper_runtime_config
  keeper_runtime_manifest_types
  keeper_toml_loader
  keeper_toml_parser)
 (libraries
  eio
  fs_compat
  masc.config
  masc.config_dir_resolver
  masc.masc_core
  yojson)
 (preprocess (pps ppx_tla)))
DUNE
for src in keeper_runtime_config keeper_runtime_manifest_types keeper_toml_loader keeper_toml_parser; do
  rm -rf lib/$src
done

# Group: keeper_telemetry
mkdir -p lib/keeper_telemetry
for src in keeper_metrics keeper_measurement keeper_timing keeper_token_count keeper_usage_trust; do
  if [ -d "lib/$src" ]; then
    cp lib/$src/*.ml lib/keeper_telemetry/ 2>/dev/null || true
    cp lib/$src/*.mli lib/keeper_telemetry/ 2>/dev/null || true
  fi
done
if [ -f "lib/keeper_benchmark_canary.ml" ]; then cp lib/keeper_benchmark_canary.ml lib/keeper_telemetry/ 2>/dev/null || true; fi
if [ -f "lib/keeper_benchmark_canary.mli" ]; then cp lib/keeper_benchmark_canary.mli lib/keeper_telemetry/ 2>/dev/null || true; fi
cat > lib/keeper_telemetry/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_telemetry)
 (public_name masc.keeper_telemetry)
 (wrapped false)
 (modules
  keeper_metrics
  keeper_measurement
  keeper_timing
  keeper_token_count
  keeper_usage_trust
  keeper_benchmark_canary)
 (libraries
  agent_sdk
  yojson
  time_compat))
DUNE
rm -rf lib/keeper_metrics lib/keeper_measurement lib/keeper_timing lib/keeper_token_count lib/keeper_usage_trust
rm -f lib/keeper_benchmark_canary.ml lib/keeper_benchmark_canary.mli

# Group: keeper_outcome
mkdir -p lib/keeper_outcome
for src in keeper_outcome_taxonomy keeper_oas_timeout_message; do
  cp lib/$src/*.ml lib/keeper_outcome/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_outcome/ 2>/dev/null || true
done
cat > lib/keeper_outcome/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_outcome)
 (public_name masc.keeper_outcome)
 (wrapped false)
 (modules
  keeper_chat_store_operation
  keeper_compact_audit_retention_outcome
  keeper_execution_receipt_outcome_kind
  keeper_oas_execution_error_phase
  keeper_operator_compact_result
  keeper_tool_outcome
  keeper_oas_timeout_message)
 (libraries
  masc_core
  yojson))
DUNE
for src in keeper_outcome_taxonomy keeper_oas_timeout_message; do
  rm -rf lib/$src
done

# Group: keeper_world
mkdir -p lib/keeper_world
for src in keeper_social_model_types keeper_synthetic_marker keeper_prompt_names keeper_world_observation_turn_types; do
  cp lib/$src/*.ml lib/keeper_world/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_world/ 2>/dev/null || true
done
cat > lib/keeper_world/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_world)
 (public_name masc.keeper_world)
 (wrapped false)
 (modules
  keeper_social_model_types
  keeper_synthetic_marker
  keeper_prompt_names
  keeper_world_observation_turn_types)
 (libraries
  masc_core))
DUNE
for src in keeper_social_model_types keeper_synthetic_marker keeper_prompt_names keeper_world_observation_turn_types; do
  rm -rf lib/$src
done

# Group: keeper_workspace
mkdir -p lib/keeper_workspace
for src in keeper_workspace_op keeper_provider_error_class keeper_hooks_oas_types keeper_sandbox_error keeper_pressure; do
  if [ -d "lib/$src" ]; then
    cp lib/$src/*.ml lib/keeper_workspace/ 2>/dev/null || true
    cp lib/$src/*.mli lib/keeper_workspace/ 2>/dev/null || true
  fi
done
if [ -f "lib/keeper_voice_local.ml" ]; then cp lib/keeper_voice_local.ml lib/keeper_workspace/ 2>/dev/null || true; fi
if [ -f "lib/keeper_voice_local.mli" ]; then cp lib/keeper_voice_local.mli lib/keeper_workspace/ 2>/dev/null || true; fi
cat > lib/keeper_workspace/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_workspace)
 (public_name masc.keeper_workspace)
 (wrapped false)
 (modules
  keeper_workspace_op
  keeper_provider_error_class
  keeper_hooks_oas_types
  keeper_sandbox_error
  keeper_fd_pressure
  keeper_disk_pressure
  keeper_voice_local)
 (libraries
  agent_sdk
  masc.masc_core
  masc.types_boundary
  masc.keeper_tool_name
  unix
  str
  yojson
  eio
  masc_config
  masc_cancel_safe
  masc_process
  masc_log
  time_compat)
 (foreign_stubs
  (language c)
  (names nofile_stubs)))
DUNE
rm -rf lib/keeper_workspace_op lib/keeper_provider_error_class lib/keeper_hooks_oas_types lib/keeper_sandbox_error lib/keeper_pressure
rm -f lib/keeper_voice_local.ml lib/keeper_voice_local.mli

# Group: keeper_tooling
mkdir -p lib/keeper_tooling
for src in keeper_discovered_tools keeper_tool_command_parse keeper_tool_execute_shell_ir keeper_tool_execute_timeout keeper_tool_hook_error_state keeper_tool_name keeper_tool_response keeper_tool_retry_state keeper_skill_routing; do
  cp lib/$src/*.ml lib/keeper_tooling/ 2>/dev/null || true
  cp lib/$src/*.mli lib/keeper_tooling/ 2>/dev/null || true
done
cat > lib/keeper_tooling/dune <<'DUNE'
(include_subdirs no)
(library
 (name masc_keeper_tooling)
 (public_name masc.keeper_tooling)
 (wrapped false)
 (modules
  keeper_discovered_tools
  keeper_tool_execute_command_parse
  keeper_tool_execute_command_words
  keeper_tool_execute_shell_ir
  keeper_tool_execute_timeout
  keeper_tool_hook_error_state
  keeper_tool_name
  keeper_tool_response
  keeper_tool_retry_state
  keeper_skill_routing)
 (libraries
  agent_sdk
  masc.bounded_event_dedupe
  masc.config
  masc.exec_policy
  masc.masc_core
  masc.masc_exec
  masc.masc_exec_command_gate
  masc_core
  yojson)
 (flags (:standard -w +4)))
DUNE
for src in keeper_discovered_tools keeper_tool_command_parse keeper_tool_execute_shell_ir keeper_tool_execute_timeout keeper_tool_hook_error_state keeper_tool_name keeper_tool_response keeper_tool_retry_state keeper_skill_routing; do
  rm -rf lib/$src
done

echo "Groups merged."
