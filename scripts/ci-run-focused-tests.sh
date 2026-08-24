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
  @test/runtest-test_exec_dispatch_file_redirect
  @test/runtest-test_process_file_redirects
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
  @test/runtest-test_blocker_class_mirror
  @test/runtest-test_board_author_identity_10297
  @test/runtest-test_board_collect_pause_gate
  @test/runtest-test_board_comment_id_is_visible
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
  @test/runtest-test_keeper_tool_execute_typed_input
  @test/runtest-test_tool_schema_agent_core_boundary
  @test/runtest-test_tool_call_quality_benchmark
  @test/runtest-test_filesystem_tool_toml_parity
  @test/runtest-test_task_tool_toml_parity
  @test/runtest-test_operator_surface_toml_parity
  @test/runtest-test_keeper_schema_toml_parity
  @test/runtest-test_keeper_runtime_schemas_toml_parity
  @test/runtest-test_taskboard_tool_toml_parity
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
  @test/runtest-test_telemetry_gate_handler_detection
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
  @test/runtest-test_keeper_tool_progress_identity
  @test/runtest-test_keeper_external_resource_lease
  @test/runtest-test_keeper_wire_capture
  @test/runtest-test_runtime_provider_auth_headers
  @test/runtest-test_keeper_official_client_host
  @test/runtest-test_keeper_tool_approval_gate
  @test/runtest-test_keeper_tool_approval_policy
  @test/runtest-test_keeper_tool_approval_registry
  @test/runtest-test_runtime_codex_app_server
  @test/runtest-test_runtime_antigravity
  @test/runtest-test_runtime_antigravity_home
  @test/runtest-test_runtime_official_client_mcp_http
  @test/runtest-test_official_client_session_store
  @test/runtest-test_runtime_claude_code
  @test/runtest-test_runtime_claude_code_config
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
  @test/runtest-test_broadcast_stores_raw_text
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
  @test/runtest-test_tui_tool_tree
  @test/runtest-test_operator_control_snapshot_state
  @test/runtest-test_operator_control_snapshot
  @test/runtest-test_operator_control_snapshot_cache
  @test/runtest-test_model_map_of_keeper_rows
)

# Suites that test/dune declared and CI never ran. Each one here was built
# and run before being listed, alone and then all together in one dune
# invocation, so wiring them adds coverage without adding a known-red target.
# The list is the alphabetical head of the declared-but-unrun set: it ends at
# test_safe_ops because that is where the sweep stopped, not because the
# suites after it fail. Of the 160 still unwired, the 125 sorting after
# test_safe_ops were measured at 121 passing and 4 failing
# (test_server_mcp_session_persist, test_telemetry_task_transition_10358,
# test_tools_coverage, test_voice_runtime_overlay); the 121 are follow-up
# wiring, not triage. The 35 sorting before it are 17 failing, 5 that are not
# runnable tests (4 e2e stanzas gated on MASC_E2E_TESTS, 1 plain executable),
# test_fusion_wake (case 12 times out in CI, #29064), and the rest unmeasured.
# The ratchet in scripts/audit-ci-test-targets.sh holds the line at 160.
newly_wired_targets=(
  @test/runtest-test_board_explicit_writes
  @test/runtest-test_board_metrics_labels
  @test/runtest-test_board_persistence_schema
  @test/runtest-test_board_rest_routes
  @test/runtest-test_board_sort
  @test/runtest-test_board_sse_canonical_event_type
  @test/runtest-test_board_ttl
  @test/runtest-test_boundary_redaction_runtime_lane
  @test/runtest-test_briefing_compactors
  @test/runtest-test_briefing_gaps
  @test/runtest-test_briefing_json_helpers
  @test/runtest-test_briefing_sections
  @test/runtest-test_broadcast_wakeup_policy
  @test/runtest-test_build_identity
  @test/runtest-test_cache_eio
  @test/runtest-test_cache_eio_coverage
  @test/runtest-test_cache_metrics_wiring
  @test/runtest-test_completion_trust_harness
  @test/runtest-test_dashboard_render_timing_9766
  @test/runtest-test_dashboard_resilience_coverage
  @test/runtest-test_dashboard_runtime_probe_nonblocking
  @test/runtest-test_dashboard_snapshot
  @test/runtest-test_dashboard_tla_specs
  @test/runtest-test_dashboard_tool_host_events
  @test/runtest-test_dated_jsonl_count_cache
  @test/runtest-test_dated_jsonl_mutex_registry_10372
  @test/runtest-test_discord_gateway_client
  @test/runtest-test_discord_presence_bridge
  @test/runtest-test_discord_tls_config_cache
  @test/runtest-test_discord_wss_bridge
  @test/runtest-test_discord_wss_lifecycle
  @test/runtest-test_disk_hygiene_script
  @test/runtest-test_dispatch_observer_validation_failure
  @test/runtest-test_dispatch_outcome_total
  @test/runtest-test_dispatch_telemetry_gap
  @test/runtest-test_distributed_lock_acquire_failed_counter
  @test/runtest-test_distributed_lock_backlog_namespace
  @test/runtest-test_distributed_lock_backoff_jitter_9645
  @test/runtest-test_docker_playground_gc_script
  @test/runtest-test_domain_pool
  @test/runtest-test_dune_local_script
  @test/runtest-test_eio_context_fiber_local
  @test/runtest-test_eio_mutex_concurrency
  @test/runtest-test_eio_resource_scope
  @test/runtest-test_env_config_dashboard_compute_timeouts
  @test/runtest-test_env_config_dashboard_execution_timeouts
  @test/runtest-test_env_config_dashboard_shell_prewarm
  @test/runtest-test_env_config_get_ratio
  @test/runtest-test_env_config_keeper_bootstrap_intervals
  @test/runtest-test_env_config_keeper_poll_intervals
  @test/runtest-test_env_config_nonneg
  @test/runtest-test_env_config_sandbox
  @test/runtest-test_env_config_schedule_runner
  @test/runtest-test_env_config_sidecar_timeouts
  @test/runtest-test_env_config_voice_bridge_timeouts
  @test/runtest-test_env_keeper_scrub
  @test/runtest-test_error_logging_coverage
  @test/runtest-test_eval_feed
  @test/runtest-test_eval_harness
  @test/runtest-test_eval_tool_selector_boundary
  @test/runtest-test_event_kind
  @test/runtest-test_event_priority_monotone_pbt
  @test/runtest-test_exact_output_catalog_precedence
  @test/runtest-test_exec_core
  @test/runtest-test_exec_dispatch
  @test/runtest-test_exec_shell_command_gate
  @test/runtest-test_exec_tap
  @test/runtest-test_executor_pool_eio_mutex
  @test/runtest-test_fact_retention_reachability
  @test/runtest-test_fd_accountant
  @test/runtest-test_feature_flag_registry
  @test/runtest-test_field_resolution
  @test/runtest-test_field_validation
  @test/runtest-test_file_lock_eio
  @test/runtest-test_fs_atomic_orphan_sweep_10130
  @test/runtest-test_fs_compat_append_jsonl_atomicity
  @test/runtest-test_fs_compat_durable_append
  @test/runtest-test_fs_compat_fd_cache
  @test/runtest-test_fs_compat_mkdir_memo
  @test/runtest-test_fs_compat_publication_reconciliation
  @test/runtest-test_gate_hitl_runtime_info
  @test/runtest-test_gate_keeper_backend
  @test/runtest-test_gate_protocol
  @test/runtest-test_gate_surface
  @test/runtest-test_gc_sampler
  @test/runtest-test_git_fetch_retry_script
  @test/runtest-test_git_fetch_timeout_9587
  @test/runtest-test_goal_task_assignment
  @test/runtest-test_goal_tools
  @test/runtest-test_goal_upsert_fsm_bypass_10247
  @test/runtest-test_graphql_api
  @test/runtest-test_graphql_api_coverage
  @test/runtest-test_graphql_endpoint
  @test/runtest-test_grpc_client
  @test/runtest-test_health
  @test/runtest-test_health_status
  @test/runtest-test_heartbeat_integration
  @test/runtest-test_heartbeat_qw
  @test/runtest-test_host_config_resolution
  @test/runtest-test_http_negotiation
  @test/runtest-test_http_pages_asset_read
  @test/runtest-test_http_protocol_detect
  @test/runtest-test_http_server_eio_coverage
  @test/runtest-test_ide_annotations
  @test/runtest-test_ide_canonical_url_join
  @test/runtest-test_ide_diagnostics
  @test/runtest-test_ide_paths
  @test/runtest-test_identity_e2e
  @test/runtest-test_identity_edge_cases
  @test/runtest-test_inference_inflight_observation
  @test/runtest-test_inference_utils
  @test/runtest-test_install_script
  @test/runtest-test_json_field
  @test/runtest-test_json_util
  @test/runtest-test_jsonl_incremental_projection
  @test/runtest-test_k2_pipeline_e2e
  @test/runtest-test_k3_tool_pipeline_e2e
  @test/runtest-test_keeper_agent_run_sandbox_source
  @test/runtest-test_keeper_allowed_paths
  @test/runtest-test_keeper_board_unavailable
  @test/runtest-test_keeper_callback_hardening
  @test/runtest-test_keeper_chat_blocks
  @test/runtest-test_keeper_chat_delivery_identity
  @test/runtest-test_keeper_chat_discord
  @test/runtest-test_keeper_chat_media_store
  @test/runtest-test_keeper_chat_store
  @test/runtest-test_keeper_chat_store_append_result
  @test/runtest-test_keeper_checkpoint_classify
  @test/runtest-test_keeper_classifier_helper
  @test/runtest-test_keeper_compact_recovery_tool_surface
  @test/runtest-test_keeper_compaction_outcome_counters
  @test/runtest-test_keeper_composite_live_turn_surface
  @test/runtest-test_keeper_context_core_dedup
  @test/runtest-test_keeper_context_isolation
  @test/runtest-test_keeper_context_layers
  @test/runtest-test_keeper_context_observation_projection
  @test/runtest-test_keeper_core_error_typed_bridge
  @test/runtest-test_keeper_cwd_response
  @test/runtest-test_keeper_cycle_channel
  @test/runtest-test_keeper_decision_event
  @test/runtest-test_keeper_diagnostic_stale_last_error
  @test/runtest-test_keeper_disk_pressure
  @test/runtest-test_keeper_effective_meta_overlay
  @test/runtest-test_keeper_efficiency_protocol
  @test/runtest-test_keeper_exact_flow_detail
  @test/runtest-test_keeper_execution_receipt_observation_wire
  @test/runtest-test_keeper_failed_selection_disposition
  @test/runtest-test_keeper_fd_pressure_fleet
  @test/runtest-test_keeper_fs
  @test/runtest-test_keeper_fs_edit_containment
  @test/runtest-test_keeper_fs_systhread_cancellation
  @test/runtest-test_keeper_global_shared_refs_atomic
  @test/runtest-test_keeper_hooks_agent_core_log_shape
  @test/runtest-test_keeper_id
  @test/runtest-test_keeper_identity_drift_counter
  @test/runtest-test_keeper_identity_id
  @test/runtest-test_keeper_identity_normalize
  @test/runtest-test_keeper_identity_outcome_label
  @test/runtest-test_keeper_identity_parse
  @test/runtest-test_keeper_invalid_request_auto_recover
  @test/runtest-test_keeper_latched_reason
  @test/runtest-test_keeper_lifecycle_chaos
  @test/runtest-test_keeper_lifecycle_gate
  @test/runtest-test_keeper_lifecycle_registry_dispatch
  @test/runtest-test_keeper_local_profile_docker_playground
  @test/runtest-test_keeper_long_turn_9943
  @test/runtest-test_keeper_memory_write
  @test/runtest-test_keeper_mention_scope
  @test/runtest-test_keeper_meta_current_keyset
  @test/runtest-test_keeper_meta_cwd_resilience
  @test/runtest-test_keeper_misc_mutable_refs
  @test/runtest-test_keeper_noop_backoff
  @test/runtest-test_keeper_path_check_error
  @test/runtest-test_keeper_path_containment_objective
  @test/runtest-test_keeper_path_rejection
  @test/runtest-test_keeper_paused_work_cancellation_transaction
  @test/runtest-test_keeper_paused_work_resume_surface
  @test/runtest-test_keeper_person_note_set_handler
  @test/runtest-test_keeper_person_notes
  @test/runtest-test_keeper_proactive_skip_counter
  @test/runtest-test_keeper_raw_task_signal_wake
  @test/runtest-test_keeper_receipt_authoritative
  @test/runtest-test_keeper_receipt_authoritative_matrix
  @test/runtest-test_keeper_registry_admission_no_suspend
  @test/runtest-test_keeper_registry_provenance
  @test/runtest-test_keeper_replay_checkpoint
  @test/runtest-test_keeper_repo_mapping
  @test/runtest-test_keeper_request_wire_observation
  @test/runtest-test_keeper_response_feedback
  @test/runtest-test_keeper_running_reconcile_attempt
  @test/runtest-test_keeper_runtime_attempt
  @test/runtest-test_keeper_runtime_config_leaf
  @test/runtest-test_keeper_runtime_failure_route
  @test/runtest-test_keeper_runtime_manifest_clock_separation
  @test/runtest-test_keeper_runtime_manifest_completeness
  @test/runtest-test_keeper_runtime_observation_boundaries
  @test/runtest-test_keeper_runtime_trust_snapshot
  @test/runtest-test_keeper_sandbox_containment
  @test/runtest-test_keeper_sandbox_read_runner
  @test/runtest-test_keeper_sandbox_runner
  @test/runtest-test_keeper_secret_projection
  @test/runtest-test_keeper_self_authored_task_exclusion
  @test/runtest-test_keeper_shutdown_reconciliation_settlement
  @test/runtest-test_keeper_state_machine
  @test/runtest-test_keeper_state_machine_mermaid
  @test/runtest-test_keeper_state_machine_pbt
  @test/runtest-test_keeper_state_machine_tla_correspondence
  @test/runtest-test_keeper_stream_media_accum
  @test/runtest-test_keeper_stream_tool_accum
  @test/runtest-test_keeper_structured_output_schema
  @test/runtest-test_keeper_subprocess_registry
  @test/runtest-test_keeper_supervisor
  @test/runtest-test_keeper_supervisor_observability_10125
  @test/runtest-test_keeper_surface_post
  @test/runtest-test_keeper_surface_read
  @test/runtest-test_keeper_surface_status
  @test/runtest-test_keeper_tag_dispatch
  @test/runtest-test_keeper_task_cancellation_wake
  @test/runtest-test_keeper_telemetry_consumer
  @test/runtest-test_keeper_terminal_reason_typed
  @test/runtest-test_keeper_timing
  @test/runtest-test_keeper_toml_loader
  @test/runtest-test_keeper_toml_parser
  @test/runtest-test_keeper_tool_call_sse_io_preview
  @test/runtest-test_keeper_tool_duration_buckets
  @test/runtest-test_keeper_tool_emission_hook
  @test/runtest-test_keeper_tool_execute_descriptor_variant
  @test/runtest-test_keeper_tool_name
  @test/runtest-test_keeper_tool_policy_masc_surface
  @test/runtest-test_keeper_tool_read_window
  @test/runtest-test_keeper_tool_search_files_containment
  @test/runtest-test_keeper_tool_search_files_via_field
  @test/runtest-test_keeper_tool_use_failure_counter
  @test/runtest-test_keeper_transition_audit_types
  @test/runtest-test_keeper_turn_disposition
  @test/runtest-test_keeper_turn_fsm_emit
  @test/runtest-test_keeper_turn_helpers_side_effect_metric
  @test/runtest-test_keeper_turn_terminal_disposition_field
  @test/runtest-test_keeper_typed_labels
  @test/runtest-test_keeper_unified_claim_progress
  @test/runtest-test_keeper_unified_context_overflow
  @test/runtest-test_keeper_unified_turn_event_bus
  @test/runtest-test_keeper_usage_trust_counter
  @test/runtest-test_keeper_visible_path_projection
  @test/runtest-test_keeper_waiting_inventory
  @test/runtest-test_keeper_wire_capture_suppression
  @test/runtest-test_keeper_workspace_ops
  @test/runtest-test_keeper_yield_observability
  @test/runtest-test_legacy_protocol_alias_rejected
  @test/runtest-test_lifecycle
  @test/runtest-test_limit_schema_widen
  @test/runtest-test_llm_metric_bridge
  @test/runtest-test_local_review_script
  @test/runtest-test_local_runtime_pool
  @test/runtest-test_lockfree_atomic
  @test/runtest-test_log_file_sink_self_heal
  @test/runtest-test_log_ring_encoder
  @test/runtest-test_log_severity_outcome_level
  @test/runtest-test_lsp_process_manager
  @test/runtest-test_masc_agent_core_bridge_observation
  @test/runtest-test_masc_error_dashboard_auth_code
  @test/runtest-test_masc_error_is_retryable
  @test/runtest-test_masc_log_utc_filename_10392
  @test/runtest-test_masc_runtime_events
  @test/runtest-test_mcp_auth_gate
  @test/runtest-test_mcp_protocol_coverage
  @test/runtest-test_mcp_server_eio_bind_state
  @test/runtest-test_mcp_server_eio_call_tool
  @test/runtest-test_mcp_server_eio_coverage
  @test/runtest-test_mcp_server_eio_tool_dispatch
  @test/runtest-test_mcp_session_coverage
  @test/runtest-test_mcp_session_id_header
  @test/runtest-test_mcp_telemetry
  @test/runtest-test_mcp_tool_runtime_workspace_path
  @test/runtest-test_mention
  @test/runtest-test_metrics_rotation
  @test/runtest-test_metrics_store_eio
  @test/runtest-test_metrics_store_eio_pbt
  @test/runtest-test_mid_turn_resume
  @test/runtest-test_minted_name_gate
  @test/runtest-test_misc_coverage
  @test/runtest-test_multi_workspace
  @test/runtest-test_nickname_coverage
  @test/runtest-test_normalized_actor
  @test/runtest-test_notify_coverage
  @test/runtest-test_observability_redact_private_material
  @test/runtest-test_operator_control_judgment
  @test/runtest-test_orchestrator_coverage
  @test/runtest-test_orphan_surfacer
  @test/runtest-test_otel_dispatch_hook
  @test/runtest-test_otel_histogram_bucket_labels
  @test/runtest-test_otel_otlp_export_e2e
  @test/runtest-test_otel_runtime_observables
  @test/runtest-test_otel_tick_poison_source
  @test/runtest-test_otel_trace_context
  @test/runtest-test_otel_zero_fill
  @test/runtest-test_parse_outcome
  @test/runtest-test_pbt_context_overflow
  @test/runtest-test_pbt_text_processing
  @test/runtest-test_pbt_validation
  @test/runtest-test_planning_eio
  @test/runtest-test_playground_paths
  @test/runtest-test_pool_metrics
  @test/runtest-test_pr_b_shell_paths_migration
  @test/runtest-test_pr_c_coreutils_migration
  @test/runtest-test_pr_d_agent_runtime_migration
  @test/runtest-test_pr_f_test_mode_migration
  @test/runtest-test_process_eio_detached
  @test/runtest-test_process_timeout_counter
  @test/runtest-test_progress
  @test/runtest-test_progress_coverage
  @test/runtest-test_prompt_registry_dune_fallback
  @test/runtest-test_provider_diag_log_sink
  @test/runtest-test_provider_http_error
  @test/runtest-test_provider_prefix_boundary
  @test/runtest-test_pulse
  @test/runtest-test_rate_limit_coverage
  @test/runtest-test_read_drop_reason
  @test/runtest-test_relation_materializer
  @test/runtest-test_repo_e2e
  @test/runtest-test_repo_git
  @test/runtest-test_repo_store
  @test/runtest-test_repo_sync
  @test/runtest-test_resilience
  @test/runtest-test_resilience_coverage
  @test/runtest-test_response_model_empty_10083
  @test/runtest-test_rfc_0085_pr10_home_assets_purge
  @test/runtest-test_rfc_0085_pr11_deprecation_purge
  @test/runtest-test_rfc_0085_pr12_tool_spec_rename
  @test/runtest-test_rfc_0085_pr13_underscore_rename
  @test/runtest-test_rfc_0085_pr14_dispatch_inline
  @test/runtest-test_rfc_0085_pr17_dead_purge_and_rename
  @test/runtest-test_rfc_0085_pr3_server_runtime_paths
  @test/runtest-test_rfc_0085_pr4_tool_library_proof_store
  @test/runtest-test_rfc_0085_pr6_host_config_from_env
  @test/runtest-test_rfc_0085_pr8_config_dir_resolver_host_config
  @test/runtest-test_rfc_0085_pr9_base_path_opt_purge
  @test/runtest-test_run_eio_coverage
  @test/runtest-test_run_local_script
  @test/runtest-test_runtime_agent_close_cancel_source
  @test/runtest-test_runtime_agent_core_eio_context_classify
  @test/runtest-test_runtime_attempt_fsm
  @test/runtest-test_runtime_defaults_json
  @test/runtest-test_runtime_event_bus
  @test/runtest-test_runtime_lane_preference
  @test/runtest-test_runtime_missing_catalog_report
  @test/runtest-test_runtime_model_temperature_toml
  @test/runtest-test_runtime_params
  @test/runtest-test_runtime_provider_projection_boundary
  @test/runtest-test_safe_ops
)

newly_wired_followup_targets=(
  @test/runtest-test_sandbox_inspect_trim_10488
  @test/runtest-test_schedule_domain
  @test/runtest-test_schedule_service
  @test/runtest-test_server_activity_http
  @test/runtest-test_server_auth_warn_log_bound
  @test/runtest-test_server_base_path_diagnostics
  @test/runtest-test_server_dashboard_http_keeper_api_trace
  @test/runtest-test_server_dashboard_http_keeper_memory_health
  @test/runtest-test_server_dashboard_http_schedule_actions
  @test/runtest-test_server_discord_trigger_policy
  @test/runtest-test_server_hibernation
  @test/runtest-test_server_ide_http
  @test/runtest-test_server_ide_lsp_proxy
  @test/runtest-test_server_request_authority
  @test/runtest-test_server_runtime_bootstrap
  @test/runtest-test_server_slack_gateway_attention
  @test/runtest-test_server_slack_trigger_policy
  @test/runtest-test_server_startup_takeover
  @test/runtest-test_server_state_product
  @test/runtest-test_server_timing
  @test/runtest-test_server_utils_bounded_cache
  @test/runtest-test_session
  @test/runtest-test_session_coverage
  @test/runtest-test_session_lifecycle_event
  @test/runtest-test_set_util
  @test/runtest-test_shutdown_benign_termination
  @test/runtest-test_shutdown_flag
  @test/runtest-test_slack_gateway_state
  @test/runtest-test_slack_rest_client
  @test/runtest-test_sse
  @test/runtest-test_sse_external_sub
  @test/runtest-test_sse_pumps
  @test/runtest-test_sse_qw
  @test/runtest-test_sse_registration_auth
  @test/runtest-test_start_masc_mcp_script
  @test/runtest-test_start_masc_script
  @test/runtest-test_stop_reason_label
  @test/runtest-test_streamable_http_upgrade
  @test/runtest-test_string_util
  @test/runtest-test_subscriptions
  @test/runtest-test_surface_ref
  @test/runtest-test_system_error_class
  @test/runtest-test_system_log_atomicity
  @test/runtest-test_tag_dispatch_typed
  @test/runtest-test_task_status_label_10421
  @test/runtest-test_task_transition_broadcast
  @test/runtest-test_telemetry_eio_coverage
  @test/runtest-test_telemetry_error_occurred_wire_10358
  @test/runtest-test_telemetry_observe
  @test/runtest-test_telemetry_unified
  @test/runtest-test_telemetry_unified_source
  @test/runtest-test_tempo_coverage
  @test/runtest-test_thinking_control_format_unknown_error
  @test/runtest-test_time_codec
  @test/runtest-test_timeout_origin
  @test/runtest-test_tool_agent_coverage
  @test/runtest-test_tool_agent_timeline_build
  @test/runtest-test_tool_agent_timeline_name_match
  @test/runtest-test_tool_args_envelope
  @test/runtest-test_tool_assignment_telemetry
  @test/runtest-test_tool_bridge_externalize
  @test/runtest-test_tool_call_replay_harness
  @test/runtest-test_tool_capability_typed
  @test/runtest-test_tool_control_coverage
  @test/runtest-test_tool_dispatch
  @test/runtest-test_tool_dispatch_emit
  @test/runtest-test_tool_diversity
  @test/runtest-test_tool_error
  @test/runtest-test_tool_help_metadata_rfc_0195
  @test/runtest-test_tool_help_registry_shard_coverage_10101
  @test/runtest-test_tool_hooks
  @test/runtest-test_tool_library_coverage
  @test/runtest-test_tool_local_runtime_probe
  @test/runtest-test_tool_metrics
  @test/runtest-test_tool_metrics_persist
  @test/runtest-test_tool_output_washing_e2e
  @test/runtest-test_tool_plan_coverage
  @test/runtest-test_tool_quality_classify
  @test/runtest-test_tool_registry
  @test/runtest-test_tool_resolution_runtime_projection
  @test/runtest-test_tool_result
  @test/runtest-test_tool_task_args
  @test/runtest-test_tool_token
  @test/runtest-test_tool_unified
  @test/runtest-test_trajectory
  @test/runtest-test_trajectory_atomicity
  @test/runtest-test_transport_bridge_seal
  @test/runtest-test_transport_coverage
  @test/runtest-test_transport_read_model
  @test/runtest-test_turn_id_propagation
  @test/runtest-test_turn_record
  @test/runtest-test_types_coverage
  @test/runtest-test_types_utils_coverage
  @test/runtest-test_validation
  @test/runtest-test_validation_coverage
  @test/runtest-test_verify_handoff_tool
  @test/runtest-test_voice_bridge_error
  @test/runtest-test_voice_config
  @test/runtest-test_web_dashboard_coverage
  @test/runtest-test_with_cleanups_on_release
  @test/runtest-test_with_process_coverage
  @test/runtest-test_work_as_heartbeat
  @test/runtest-test_workspace_base_path_cache
  @test/runtest-test_workspace_bind_fail_closed
  @test/runtest-test_workspace_bootstrap
  @test/runtest-test_workspace_coverage
  @test/runtest-test_workspace_file_confidentiality
  @test/runtest-test_workspace_goal_index
  @test/runtest-test_workspace_handoff_boundary
  @test/runtest-test_workspace_messages_raw
  @test/runtest-test_workspace_routes_keeper
  @test/runtest-test_workspace_state_recovery
  @test/runtest-test_workspace_task_delete
  @test/runtest-test_workspace_task_lifecycle
  @test/runtest-test_workspace_task_verification_phase_e
  @test/runtest-test_workspace_telemetry_drop_non_eio
  @test/runtest-test_workspace_tree_exclusions
  @test/runtest-test_workspace_utils_coverage
  @test/runtest-test_worktree_detection
  @test/runtest-test_yojson_type_error_board
)

sse_targets=(
  @test/runtest-test_tui_board_detail
  @test/runtest-test_tui_board_selection
  @test/runtest-test_tui_context_state
  @test/runtest-test_tui_decode
  @test/runtest-test_tui_frame_presenter
  @test/runtest-test_tui_keeper_chat_history
  @test/runtest-test_tui_keeper_chat_queue
  @test/runtest-test_tui_chat_queue_wiring
  @test/runtest-test_tui_chat_surface_mirror
  @test/runtest-test_tui_keeper_chat_live
  @test/runtest-test_tui_observer
  @test/runtest-test_tui_acting
  @test/runtest-test_tui_command
  @test/runtest-test_tui_keeper_chat_transcript
  @test/runtest-test_tui_keeper_chat_projection
  @test/runtest-test_tui_scroll
  @test/runtest-test_tui_send_disposition
  @test/runtest-test_tui_composer
  @test/runtest-test_tui_markdown
  @test/runtest-test_tui_credential
  @test/runtest-test_tui_editor
  @test/runtest-test_tui_keeper_control
  @test/runtest-test_tui_keeper_selection
  @test/runtest-test_tui_keyboard_input
  @test/runtest-test_tui_keeper_activity
  @test/runtest-test_tui_transport_health
  @test/runtest-test_tui_message_layout
  @test/runtest-test_tui_metrics_tail
  @test/runtest-test_tui_observation_layout
  @test/runtest-test_tui_planning_selection
  @test/runtest-test_tui_task_detail
  @test/runtest-test_tui_http_ast
  @test/runtest-test_tui_render_schedule
  @test/runtest-test_tui_terminal_write_repair
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
# 350 suites ran in 103s on the first CI pass (08:49:02 to 08:50:45, run
# 32628548472); 300s is that measurement with headroom, not a guess.
run_group newly-wired 300 "${newly_wired_targets[@]}" || overall_status=1
run_group newly-wired-followup 300 "${newly_wired_followup_targets[@]}" || overall_status=1

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
