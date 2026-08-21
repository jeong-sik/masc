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

# Which groups failed, recorded through a file rather than a shell array: two
# groups run inside subshells so their test knobs cannot leak, and a subshell
# cannot append to its parent's array. Without this the step exited 1 while
# every group in the log reported success, and the only way to find the failing
# one was to re-run the suites by hand (masc#28502).
failed_groups_file="$(mktemp)"
trap 'rm -f "${failed_groups_file}"' EXIT

record_group_failure() {
  local label="$1"
  local status="$2"
  printf '%s (exit %s)\n' "${label}" "${status}" >>"${failed_groups_file}"
  # Emitted after ::endgroup:: on purpose: an annotation written inside a
  # collapsed group is only visible to someone who already knows to expand it,
  # which is the thing that was missing.
  echo "::error::focused tests: ${label} failed (exit ${status})"
}

run_group() {
  local label="$1"
  local timeout_sec="$2"
  shift 2
  local target_args=""
  local status=0
  printf -v target_args ' %q' "$@"
  echo "::group::focused tests: ${label}"
  CI_TEST_TIMEOUT_SEC="${timeout_sec}" \
    scripts/ci-run-tests.sh "opam exec -- dune build --root .${target_args}" || status=$?
  echo "::endgroup::"
  if [ "${status}" -ne 0 ]; then
    record_group_failure "${label}" "${status}"
  fi
  return "${status}"
}

# A group that runs a shell test rather than dune targets. Shares the
# announcement so a shell test cannot fail more quietly than a dune suite —
# which it did: [host-fd-health-paths] prints nothing when it passes, so a
# silent group and a silent failure looked identical in the log.
run_shell_group() {
  local label="$1"
  local script_path="$2"
  local status=0
  echo "::group::focused tests: ${label}"
  bash "${script_path}" || status=$?
  echo "::endgroup::"
  if [ "${status}" -ne 0 ]; then
    record_group_failure "${label}" "${status}"
  fi
  return "${status}"
}

# Sourced rather than executed: stop here and expose only the definitions
# above. Standard bash idiom, and it changes nothing when the script runs
# normally ([BASH_SOURCE[0]] equals [$0] then). It exists so the failure
# announcement can be tested without a dune build, which is the only way to
# show that a change whose entire purpose is "name the failing group" actually
# names it.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

paused_targets=(
  @test/runtest-test_keeper_turn_outcome
  @test/runtest-test_keeper_shutdown_blocked_purge_release
  @test/runtest-test_keeper_paused_work_transfer_transaction
  @test/runtest-test_keeper_paused_work_source_terminal_transaction
  @test/runtest-test_keeper_paused_work_operator
  @test/runtest-test_keeper_event_queue_health_actionable
)

normal_targets=(
  @test/runtest-test_board_dispatch
  @test/runtest-test_keeper_latched_reason_wiring
  @test/runtest-test_keeper_status_bridge
  @test/runtest-test_dedup_rules
  @test/runtest-test_exec_command_gate_log_sink
  @test/runtest-test_file_kind_vocabulary
  @test/runtest-test_http_auth_strict_flag
  @test/runtest-test_keeper_chat_broadcast
  @test/runtest-test_keeper_chat_slack
  @test/runtest-test_keeper_chat_tool_trail
  @test/runtest-test_keeper_memory_lane
  @test/runtest-test_server_dashboard_http_keeper_chat_page
  @test/runtest-test_keeper_codex_effort_clamp
  @test/runtest-test_keeper_codex_error_carriage
  @test/runtest-test_keeper_persistence_span_history
  @test/runtest-test_keeper_rotation_eligibility_census
  @test/runtest-test_keeper_shutdown_ownerless_admission_release
  @test/runtest-test_keeper_create_admission_transaction
  @test/runtest-test_keeper_task_create_typed_failure
  @test/runtest-test_keeper_task_outcomes
  @test/runtest-test_keeper_toml_accessor_matrix
  @test/runtest-test_keeper_tool_execute_stream_close
  @test/runtest-test_keeper_turn_dispatch_authority
  @test/runtest-test_keeper_turn_interrupt
  @test/runtest-test_runtime_quota_window
  @test/runtest-test_subsystem_health_state
  @test/runtest-test_trailing_slash_rules
  @test/runtest-test_verification_run_registry
  @test/runtest-test_verifier_exact_lane
  @test/runtest-test_keeper_canary_facts
  @test/runtest-test_keeper_canary_evidence
  @test/runtest-test_keeper_canary_judge
  @test/runtest-test_keeper_canary_failover
  @test/runtest-test_keeper_canary_serving
  @test/runtest-test_slack_user_directory
  @test/runtest-test_sidecar_lifecycle_routes
  @test/runtest-test_cancel_safe
  @test/runtest-test_cancel_wall_bucket
  @test/runtest-test_cap_blocker_structured_error
  @test/runtest-test_capability_registry
  @test/runtest-test_channel_gate
  @test/runtest-test_channel_gate_binding_store
  @test/runtest-test_channel_gate_connector_routes
  @test/runtest-test_channel_gate_discord_state
  @test/runtest-test_channel_gate_imessage_state
  @test/runtest-test_channel_gate_metrics
  @test/runtest-test_channel_gate_slack_state
  @test/runtest-test_client_registry_eio
  @test/runtest-test_code_navigation_eio
  @test/runtest-test_common
  @test/runtest-test_compaction_exact_output_entrypoint_clockless
  @test/runtest-test_compaction_llm_summarizer
  @test/runtest-test_compression
  @test/runtest-test_concurrency_stress
  @test/runtest-test_config_coverage
  @test/runtest-test_config_dir_resolver
  @test/runtest-test_console_sink
  @test/runtest-test_context_max_observed_9953
  @test/runtest-test_cost_token_decouple
  @test/runtest-test_cost_usd_source_attribution_10318
  @test/runtest-test_credential_alias_10440
  @test/runtest-test_cross_context_mutex
  @test/runtest-test_dashboard_agent_core_bridge
  @test/runtest-test_dashboard_attribution
  @test/runtest-test_dashboard_briefing_sections
  @test/runtest-test_dashboard_cache
  @test/runtest-test_dashboard_continuity_briefs
  @test/runtest-test_dashboard_coverage
  @test/runtest-test_dashboard_execute_output
  @test/runtest-test_dashboard_feature_health
  @test/runtest-test_dashboard_gate_metrics
  @test/runtest-test_dashboard_goal_id_projection
  @test/runtest-test_goal_timeline_projection
  @test/runtest-test_dashboard_k2_feeds
  @test/runtest-test_dashboard_keeper_cost_aggregates
  @test/runtest-test_dashboard_keeper_metrics_10286
  @test/runtest-test_dashboard_labels
  @test/runtest-test_dashboard_librarian_metric
  @test/runtest-test_dashboard_link_preview
  @test/runtest-test_dashboard_nav_event
  @test/runtest-test_dashboard_perf
  @test/runtest-test_dashboard_recent_terminal_tasks
  @test/runtest-test_server_dashboard_runtime_observables
  @test/runtest-test_auth_ambiguous_lookup_9786
  @test/runtest-test_auth_credential_hash_collision
  @test/runtest-test_mcp_auth_reject_observability
  @test/runtest-test_auth_load_credential_of
  @test/runtest-test_auth_token_uniqueness_audit
  @test/runtest-test_grpc_workspace
  @test/runtest-test_activity_graph
  @test/runtest-test_adaptive_cache_ttl
  @test/runtest-test_agent_card_action_mirror
  @test/runtest-test_agent_core_adapters
  @test/runtest-test_agent_core_empty_response_diagnostic
  @test/runtest-test_agent_observation_bridge
  @test/runtest-test_anti_rationalization_empty_reject
  @test/runtest-test_artifacts_endpoint
  @test/runtest-test_attempt_state
  @test/runtest-test_attribution
  @test/runtest-test_audit_projection
  @test/runtest-test_auth_bearer_mismatch_9786
  @test/runtest-test_auth_credential_index_cache
  @test/runtest-test_auth_error_kind
  @test/runtest-test_auth_error_kind_dashboard_fallback
  @test/runtest-test_auth_login
  @test/runtest-test_auth_rotate_shared_tokens_10304
  @test/runtest-test_auth_strict_mode
  @test/runtest-test_backend
  @test/runtest-test_backend_coverage
  @test/runtest-test_blocker_class_exhaustiveness
  @test/runtest-test_board_author_identity_10297
  @test/runtest-test_board_collect_pause_gate
  @test/runtest-test_board_context_inference_resolution
  @test/runtest-test_board_core_payload
  @test/runtest-test_transport_integration
  @test/runtest-test_keeper_playground_checkout_discovery
  @test/runtest-test_keeper_autonomous_turn_source
  @test/runtest-test_keeper_autoboot_single_owner
  @test/runtest-test_keeper_list_truncation
  @test/runtest-test_keeper_meta_current_schema
  @test/runtest-test_keeper_meta_invalid_recovery
  @test/runtest-dashboard-http-behavior-contracts
  @test/runtest-test_dashboard_composite_claim_window
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
  @test/runtest-test_http_server_eio
  @test/runtest-test_verification
  @test/runtest-test_review_prompt_sections_reach_the_model
  @test/runtest-test_prompt_templates_render
  @test/runtest-test_dashboard_verification
  @test/runtest-test_tool_schema_constraint_enforcement
  @test/runtest-test_keeper_artifact_read_request
  @test/runtest-test_tool_input_validation
  @test/runtest-test_tool_schema_agent_core_boundary
  @test/runtest-test_tool_call_quality_benchmark
  @test/runtest-test_client_identity
  @test/runtest-test_mcp_session_task_lifecycle
  @test/runtest-test_mcp_server_eio
  @test/runtest-test_keeper_sandbox_docker_cwd_response
  @test/runtest-test_keeper_tool_execute_exit_result
  @test/runtest-test_goal_store
  @test/runtest-test_keeper_goal_phase_projection
  @test/runtest-test_keeper_tool_descriptor_registry_integrity
  @test/runtest-test_schedule_runner
  @test/runtest-test_schedule_store
  @test/runtest-test_schedule_consumer_dispatch
  @test/runtest-test_keeper_registry_hardening
  @test/runtest-test_keeper_reaction_ledger
  @test/runtest-test_exact_lane_run_registry
  @test/runtest-test_ci_run_tests_script
  @test/runtest-test_keeper_unified_verification_surface
  @test/runtest-test_schedule_tool_wiring
  @test/runtest-test_keeper_system_prompt_bytes
  @test/runtest-test_keeper_tool_schema_bytes
  @test/runtest-test_keeper_prompt_metrics
  @test/runtest-test_keeper_surface_presence_prompt
  @test/runtest-test_keeper_board_attention_partition
  @test/runtest-test_keeper_board_attention_candidate
  @test/runtest-test_keeper_board_discoverable_cursor
  @test/runtest-test_keeper_lifecycle_global_gate
  @test/runtest-test_tool_blob_store
  @test/runtest-test_keeper_tool_call_log
  @test/runtest-test_keeper_tool_plan
  @test/runtest-test_keeper_tool_composition_catalog
  @test/runtest-test_keeper_tool_kind
  @test/runtest-test_keeper_tool_plan_executor
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
  @test/runtest-test_keeper_librarian_retry
  @test/runtest-test_keeper_run_tools_hooks
  @test/runtest-test_keeper_connector_attention_batch
  @test/runtest-test_ide_lsp_join_key
  @test/runtest-test_code_address
  @test/runtest-test_keeper_ide_annotate_contract
  @test/runtest-test_dashboard_workspace
  @test/runtest-test_host_fd_pressure_poller
  @test/runtest-test_keeper_turn_driver_failover
  @test/runtest-test_keeper_cycle_failed_runtime_attribution
  @test/runtest-test_keeper_turn_driver_accept
  @test/runtest-test_keeper_vision_tool
  @test/runtest-test_runtime_modality_reroute
  @test/runtest-test_runtime_agent_advanced_outcome
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
  @test/runtest-test_workspace_root_state_parity
  @test/runtest-test_dashboard_keeper_name
  @test/runtest-test_dashboard_briefing
  @test/runtest-test_keeper_model_input_demotion
  @test/runtest-test_tool_type_label
  @test/runtest-test_telemetry_eio_pbt
  @test/runtest-test_process_eio_coverage
  @test/runtest-test_pool
  @test/runtest-test_keeper_secret_redaction
  @test/runtest-test_keeper_sandbox_docker_route
  @test/runtest-test_dashboard_dev_token_host_gate
  @test/runtest-test_dashboard_harness_health
  @test/runtest-test_eval_calibration
  @test/runtest-test_telemetry_unified_keeper_fan_in
  @test/runtest-test_dated_jsonl
  @test/runtest-test_audit_log
  @test/keeper_github_identity/runtest
  # Declared in Dune, compiled every run, never executed before this batch
  # (masc#28925 audit). Each target below was run individually against this
  # worktree and confirmed green before being added here.
  @test/runtest-test_keeper_memory_os_current
  @test/runtest-test_keeper_msg_async_path_traversal
  @test/runtest-test_keeper_msg_async_durable_active_inventory
  @test/runtest-test_keeper_mutex_coverage
  @test/runtest-test_board_karma_ledger
  @test/runtest-test_board_vote_persistence
  @test/runtest-test_log_ring_bounds
  @test/runtest-test_log_seq_restart_continuity
  @test/runtest-test_runtime_log_sink_render
  @test/runtest-test_board_comment_post_write_ahead
  @test/runtest-test_board_sub_board_write_ahead
  @test/runtest-test_keeper_event_queue
  @test/runtest-test_keeper_event_queue_owner_lock
  @test/runtest-test_keeper_event_queue_persist_poison
  @test/runtest-test_keeper_event_queue_state_v2
  @test/runtest-test_keeper_connector_attention_wake
  @test/runtest-test_keeper_scheduled_stimulus_channel
  @test/runtest-test_fusion_delivery_obligation
  @test/runtest-test_fusion_agent_core_error_detail
  @test/runtest-test_fusion_status_tool
  @test/runtest-test_fusion_judge_usage
  @test/runtest-test_fusion_metrics
  @test/runtest-test_fusion_sink_meta
  @test/runtest-test_fusion_run_registry_persist
  @test/fusion_core/runtest-test_fusion
  @test/fusion_core/runtest-test_fusion_harness
  @test/fusion_core/runtest-test_fusion_run_registry
  @test/fusion_core/runtest-test_fusion_config_json
  @test/runtest-test_keeper_thinking_observation
  @test/runtest-test_keeper_external_attention
  @test/runtest-test_keeper_manual_compaction_preemption
  @test/runtest-test_keeper_compaction_unit
  @test/runtest-test_keeper_compaction_persist_gate
  @test/runtest-test_keeper_overflow_recovery
  @test/runtest-test_keeper_post_turn_wirein_order
  @test/runtest-test_keeper_checkpoint_purge
)

board_attention_targets=(
  @test/runtest-test_keeper_board_attention_worker
)

mcp_tool_matrix_targets=(
  @test/runtest-test_mcp_tool_matrix
)

agent_core_targets=(
  @packages/agent_core/test/runtest
  # Recursive alias: runs the ppx_inline_test suites embedded in
  # packages/agent_core/lib{,/base,/protocol,/llm_provider}. These were in no
  # CI manifest, so the exact_output_plan fingerprint pin rotted silently
  # after #27945 (masc#28897).
  @packages/agent_core/lib/runtest
  @test/runtest-test_keeper_hooks_agent_core_introspection
  @test/runtest-test_keeper_execution_join
  @test/runtest-test_hitl_summary_worker
)

operator_targets=(
  @test/runtest-test_tui_operator_projection
  @test/runtest-test_operator_control_snapshot_state
  @test/runtest-test_operator_control_snapshot
  @test/runtest-test_operator_control_snapshot_cache
  @test/runtest-test_model_map_of_keeper_rows
)

sse_targets=(
  @test/runtest-test_tui_context_state
  @test/runtest-test_tui_decode
  @test/runtest-test_tui_frame_presenter
  @test/runtest-test_tui_keeper_chat_projection
  @test/runtest-test_tui_keeper_chat_recovery
  @test/runtest-test_tui_keyboard_input
  @test/runtest-test_tui_message_layout
  @test/runtest-test_tui_metrics_tail
  @test/runtest-test_tui_observation_layout
  @test/runtest-test_tui_http_ast
  @test/runtest-test_tui_render_schedule
  @test/runtest-test_sse_coverage
  @test/runtest-test_ag_ui_coverage
  @test/runtest-test_sse_storm_e2e
)

overall_status=0

(
  export ALCOTEST_QUICK_TESTS=1
  run_group paused-work 600 "${paused_targets[@]}"
) || overall_status=1

run_shell_group host-fd-health-paths test/test_monitor_system_health_paths.sh \
  || overall_status=1

# Runs first among the cheap checks on purpose: it asserts that this script
# still names a failing group, and it costs no build. If it is the thing that
# breaks, the run says so by name instead of exiting 1 in silence — the state
# masc#28502 describes.
run_shell_group focused-failure-reporting \
  test/test_ci_focused_tests_names_failing_group.sh || overall_status=1

run_group board-attention-worker 180 "${board_attention_targets[@]}" || overall_status=1
run_group normal 1200 "${normal_targets[@]}" || overall_status=1

# Own group, not part of [normal_targets]: the matrix's tools/call sweep is an
# Alcotest `Slow case, so it must run without ALCOTEST_QUICK_TESTS, and it
# spawns one runner subprocess (fresh git repo + workspace) per raw schema —
# a several-minute wall-clock profile that would otherwise eat the shared
# normal-group timeout. Wired by masc#28926 after the suite went green
# (36 same-class drift failures repaired in the same change).
run_group mcp-tool-matrix 900 "${mcp_tool_matrix_targets[@]}" || overall_status=1

if [[ "${RUN_AGENT_CORE:-false}" == "true" ]]; then
  run_group agent-core 900 "${agent_core_targets[@]}" || overall_status=1
else
  echo "::notice::focused tests: agent-core skipped by changed-surface scope"
fi

(
  export ALCOTEST_QUICK_TESTS=1
  export MASC_LOCAL_RUNTIMES_JSON='[{"base_url":"http://127.0.0.1:8085","max_concurrency":4}]'
  export MASC_E2E_TESTS=true
  run_group operator-control 600 "${operator_targets[@]}"
) || overall_status=1

(
  export MASC_E2E_TESTS=true
  run_group sse 900 "${sse_targets[@]}"
) || overall_status=1

# One place that states the outcome in full. A reader who opens the step and
# scrolls to the bottom should not have to reconstruct which of seven groups
# set the exit code.
if [ -s "${failed_groups_file}" ]; then
  echo "focused tests: failing groups"
  sed 's/^/  /' "${failed_groups_file}"
  overall_status=1
elif [ "${overall_status}" -ne 0 ]; then
  # The exit code says something failed and no group claimed it. That is a
  # defect in this script, not in the suites, and saying so is better than
  # exiting 1 with nothing to read.
  echo "::error::focused tests: exit ${overall_status} with no group recorded; \
ci-run-focused-tests.sh has a failure path that does not call record_group_failure"
else
  echo "focused tests: all groups passed"
fi

exit "${overall_status}"
