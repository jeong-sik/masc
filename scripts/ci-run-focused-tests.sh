#!/usr/bin/env bash
# The two environment-specific groups intentionally use subshells so their
# test knobs cannot leak into the following group.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

cd "$(git rev-parse --show-toplevel)" || exit

# One Dune graph evaluation per environment contract. The previous workflow
# launched one Dune process for nearly every focused suite, spending minutes
# repeatedly loading the same already-built graph. DUNE_JOBS=1 preserves the
# existing serial execution contract for fixed ports and shared test fixtures.
export CI_TEST_HEARTBEAT_SEC="${CI_TEST_HEARTBEAT_SEC:-15}"
export DUNE_JOBS="${DUNE_JOBS:-1}"
export ME_ROOT="${ME_ROOT:-/tmp/me}"
mkdir -p "${ME_ROOT}"

run_group() {
  local label="$1"
  shift
  local target_args=""
  local status=0
  printf -v target_args ' %q' "$@"
  echo "::group::focused tests: ${label}"
  scripts/ci-run-tests.sh "opam exec -- dune build --root .${target_args}" || status=$?
  echo "::endgroup::"
  return "${status}"
}

run_group_with_timeout() {
  local label="$1"
  local timeout_sec="$2"
  shift 2
  local target_args=""
  local status=0
  printf -v target_args ' %q' "$@"
  echo "::group::focused tests: ${label}"
  timeout \
    --foreground \
    --signal=TERM \
    --kill-after=15s \
    "${timeout_sec}s" \
    scripts/ci-run-tests.sh \
      "opam exec -- dune build --root .${target_args}" \
    || status=$?
  if [[ "${status}" -eq 124 || "${status}" -eq 137 ]]; then
    echo "::error::focused test target timed out label=${label} timeout_sec=${timeout_sec}"
  fi
  echo "::endgroup::"
  return "${status}"
}

paused_targets=(
  @test/runtest-test_keeper_turn_outcome
  @test/runtest-test_keeper_paused_work_transfer_transaction
  @test/runtest-test_keeper_paused_work_source_terminal_transaction
  @test/runtest-test_keeper_paused_work_operator
)

normal_targets=(
  @test/runtest-test_keeper_autonomous_turn_source
  @test/runtest-test_keeper_autoboot_single_owner
  @test/runtest-test_keeper_meta_current_schema
  @test/runtest-dashboard-http-behavior-contracts
  @test/runtest-test_model_inference_metrics
  @test/runtest-test_channel_gate_content_length_knob
  @test/runtest-test_keeper_decision_audit_dated_store
  @test/runtest-test_observability_redact
  @test/runtest-test_keeper_approval_queue
  @test/runtest-test_keeper_hitl_resolution_prompt
  @test/runtest-test_keeper_approval_audit_timeline
  @test/runtest-test_keeper_approval_queue_rules
  @test/runtest-test_keeper_approval_queue_rules_types
  @test/runtest-test_keeper_approval_resolved_history
  @test/runtest-test_keeper_gate_effect_coverage
  @test/runtest-test_keeper_gate_replay
  @test/runtest-test_workspace
  @test/runtest-test_verification
  @test/runtest-test_tool_schema_constraint_enforcement
  @test/runtest-test_keeper_artifact_read_request
  @test/runtest-test_tool_input_validation
  @test/runtest-test_tool_schema_agent_core_boundary
  @test/runtest-test_tool_call_quality_benchmark
  @test/runtest-test_client_identity
  @test/runtest-test_mcp_session_task_lifecycle
  @test/runtest-test_keeper_sandbox_docker_cwd_response
  @test/runtest-test_goal_store
  @test/runtest-test_keeper_goal_phase_projection
  @test/runtest-test_keeper_tool_descriptor_registry_integrity
  @test/runtest-test_schedule_runner
  @test/runtest-test_schedule_store
  @test/runtest-test_schedule_consumer_dispatch
  @test/runtest-test_keeper_registry_hardening
  @test/runtest-test_keeper_unified_verification_surface
  @test/runtest-test_schedule_tool_wiring
  @test/runtest-test_keeper_system_prompt_bytes
  @test/runtest-test_keeper_tool_schema_bytes
  @test/runtest-test_keeper_prompt_metrics
  @test/runtest-test_keeper_surface_presence_prompt
  @test/runtest-test_keeper_board_attention_worker
  @test/runtest-test_keeper_board_attention_partition
  @test/runtest-test_keeper_board_attention_candidate
  @test/runtest-test_keeper_lifecycle_global_gate
  @test/runtest-test_tool_blob_store
  @test/runtest-test_keeper_tool_call_log
  @test/runtest-test_keeper_external_resource_lease
  @test/runtest-test_keeper_wire_capture
  @test/runtest-test_runtime_provider_auth_headers
  @test/runtest-test_keeper_official_client_host
  @test/runtest-test_runtime_codex_app_server
  @test/runtest-test_runtime_antigravity
  @test/runtest-test_runtime_antigravity_home
  @test/runtest-test_runtime_official_client_mcp_http
  @test/runtest-test_official_client_session_store
  @test/runtest-test_runtime_claude_code
  @test/runtest-test_runtime_claude_code_config
  @test/runtest-test_dashboard_keeper_feature_proof
  @test/runtest-test_keeper_antigravity_runtime
  @test/runtest-test_keeper_claude_code_runtime
  @test/runtest-test_server_dashboard_official_client_probe
  @test/runtest-test_compaction_exact_output_conformance
  @test/runtest-test_operator_control_actions
  @test/runtest-test_masc_log
  @test/runtest-test_schema_surface_index
  @test/runtest-test_exec_policy_cwd_hint
  @test/runtest-test_server_runtime_startup_maintenance
  @test/runtest-test_runtime_per_keeper_routing
  @test/runtest-test_ide_bridge
  @test/runtest-test_dashboard_workspace
  @test/runtest-test_host_fd_pressure_poller
  @test/runtest-test_keeper_turn_driver_failover
  @test/runtest-test_keeper_turn_driver_accept
  @test/runtest-test_keeper_vision_tool
  @test/runtest-test_runtime_modality_reroute
  @test/runtest-test_runtime_model_input_tail_window
  @test/runtest-test_keeper_context_overflow_shrink
  @test/runtest-test_keeper_provider_call_deadline
  @test/runtest-test_keeper_runtime_resolved_observability
  @test/runtest-test_runtime_toml_overrides
  @test/runtest-test_keeper_wake_turn_context
  @test/runtest-test_warn_root_causes
  @test/runtest-test_workspace_heartbeat_outcome
  @test/runtest-test_agent_api_query_params
  @test/runtest-test_h2_mode_vocabulary
  @test/runtest-test_agent_transport_vocabulary
  @test/runtest-test_keeper_catchup_digest
  @test/runtest-test_workspace_root_state_parity
  @test/runtest-test_dashboard_keeper_name
  @test/runtest-test_dashboard_briefing
  @test/runtest-test_keeper_model_input_demotion
  @test/runtest-test_tool_type_label
  @test/runtest-test_telemetry_eio_pbt
  @test/runtest-test_process_eio_coverage
  @test/runtest-test_keeper_secret_redaction
)

agent_core_targets=(
  @packages/agent_core/test/runtest
  @test/runtest-test_keeper_hooks_agent_core_introspection
  @test/runtest-test_keeper_execution_join
  @test/runtest-test_hitl_summary_worker
)

operator_targets=(
  @test/runtest-test_operator_control_snapshot_state
  @test/runtest-test_operator_control_snapshot
  @test/runtest-test_operator_control_snapshot_cache
  @test/runtest-test_model_map_of_keeper_rows
)

sse_targets=(
  @test/runtest-test_sse_coverage
  @test/runtest-test_ag_ui_coverage
  @test/runtest-test_sse_storm_e2e
)

overall_status=0

(
  export ALCOTEST_QUICK_TESTS=1
  run_group paused-work "${paused_targets[@]}"
) || overall_status=1

echo "::group::focused tests: host-fd-health-paths"
if ! bash test/test_monitor_system_health_paths.sh; then
  overall_status=1
fi
echo "::endgroup::"

# Keep the ordinary suites independently attributable and bounded. A single
# wedged executable previously hid inside one batched Dune invocation for more
# than 30 minutes while the observer could report only that the group was
# alive. The 150s boundary is above the slowest healthy target in recent CI
# history and names the exact target that failed to terminate.
for target in "${normal_targets[@]}"; do
  label="normal:${target#@test/runtest-}"
  if run_group_with_timeout "${label}" 150 "${target}"; then
    :
  else
    overall_status=1
    break
  fi
done

if [[ "${RUN_AGENT_CORE:-false}" == "true" ]]; then
  run_group agent-core "${agent_core_targets[@]}" || overall_status=1
else
  echo "::notice::focused tests: agent-core skipped by changed-surface scope"
fi

(
  export ALCOTEST_QUICK_TESTS=1
  export MASC_LOCAL_RUNTIMES_JSON='[{"base_url":"http://127.0.0.1:8085","max_concurrency":4}]'
  export MASC_E2E_TESTS=true
  run_group operator-control "${operator_targets[@]}"
) || overall_status=1

(
  export MASC_E2E_TESTS=true
  run_group sse "${sse_targets[@]}"
) || overall_status=1

exit "${overall_status}"
