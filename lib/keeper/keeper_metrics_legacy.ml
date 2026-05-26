(** Keeper_metrics_legacy — backward-compatible string metric name constants.
    Extracted from [Keeper_metrics] (930 LoC).  These string constants exist
    so existing callers can migrate incrementally to the [t] variant.
    New code should use [Keeper_metrics.t] directly.
    @since Keeper 500-line decomposition *)

include Keeper_metrics_constants
let metric_keeper_domain_pool_fork = "masc_keeper_domain_pool_fork_total"
let metric_keeper_semaphore_wait_timeout = "masc_keeper_semaphore_wait_timeout_total"

let metric_keeper_turn_slot_bookkeeping_failures =
  "masc_keeper_turn_slot_bookkeeping_failures_total"
;;

let metric_keeper_semaphore_wait_seconds = "masc_keeper_semaphore_wait_seconds"

let metric_keeper_semaphore_wait_seconds_bucket =
  "masc_keeper_semaphore_wait_seconds_bucket"
;;

let metric_keeper_slot_yield_total = "masc_keeper_slot_yield_total"
let metric_keeper_compactions = "masc_keeper_compactions_total"
let metric_keeper_compaction_ratio_change = "masc_keeper_compaction_ratio_change"
let metric_keeper_compaction_saved_tokens = "masc_keeper_compaction_saved_tokens_total"

let metric_keeper_compaction_pair_repair_fabrications =
  "masc_keeper_compaction_pair_repair_fabrications_total"
;;

(* Effective emergency compaction ratio threshold (set once at module init
   from [MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD], clamped [0.5,0.99]).
   Gauge so operators can confirm the live value via /metrics without
   restarting under instrumentation. *)
let metric_keeper_emergency_compact_ratio_threshold =
  "masc_keeper_emergency_compact_ratio_threshold"
;;
let metric_keeper_operator_compact = "masc_keeper_operator_compact_total"
let metric_keeper_operator_clear = "masc_keeper_operator_clear_total"
let metric_keeper_compaction_noop = "masc_keeper_compaction_noop_total"
let metric_keeper_continuity_no_state = "masc_keeper_continuity_no_state_total"
let metric_keeper_tool_pair_repair = "masc_keeper_tool_pair_repair_total"
let metric_keeper_tool_emission_registry_size = "masc_keeper_tool_emission_registry_size"
let metric_keeper_tool_emission_pushes = "masc_keeper_tool_emission_pushes_total"

let metric_keeper_tool_underused_allowed_count =
  "masc_keeper_tool_underused_allowed_count"
;;

let metric_keeper_tool_underused_allowed = "masc_keeper_tool_underused_allowed"
let metric_keeper_path_rejection = "masc_keeper_path_rejection_total"

(* RFC-0128 S4.2 — counter for records that could not be assigned to a
   canonical-URL bucket and landed in [.masc-ide/_orphan/]. Labels:
   [kind = "annotation" | "region"], [reason = "unregistered_repo"
   | "blank_url" | "url_unparseable"]. *)
let metric_ide_orphan_writes = "masc_ide_orphan_writes_total"

let metric_keeper_path_resolver_identity_mismatch =
  "masc_keeper_path_resolver_identity_mismatch_total"
;;

let metric_keeper_heartbeat_successes = "masc_keeper_heartbeat_successes_total"
let metric_keeper_heartbeat_failures = "masc_keeper_heartbeat_failures_total"

let metric_keeper_cleanup_tracking_failures =
  "masc_keeper_cleanup_tracking_failures_total"
;;

let metric_keeper_dispatch_event_failures = "masc_keeper_dispatch_event_failures_total"
let metric_keeper_directive_failures = "masc_keeper_directive_failures_total"
let metric_keeper_tool_call_duration = "masc_keeper_tool_call_duration_seconds"
let metric_keeper_write_meta_failures = "masc_keeper_write_meta_failures_total"
let metric_keeper_meta_read_failures = "masc_keeper_meta_read_failures_total"
let metric_keeper_approval_queue_failures = "masc_keeper_approval_queue_failures_total"
let metric_keeper_guards_failures = "masc_keeper_guards_failures_total"
let metric_keeper_profile_load_failures = "masc_keeper_profile_load_failures_total"
let metric_keeper_compact_audit_failures = "masc_keeper_compact_audit_failures_total"

let metric_keeper_compact_audit_retention_parse =
  "masc_keeper_compact_audit_retention_parse_total"
;;

(* V17 burst visibility: per-drain-call counter and bucketed batch-size
   counter for [keeper_compact_audit] subscriber. Labels for bucket are
   closed-vocab {"0"|"1_9"|"10_49"|"50_99"|"100_499"|"500_plus"} to
   avoid cardinality explosion. *)
let metric_keeper_compact_audit_drain_batches =
  "masc_keeper_compact_audit_drain_batches_total"
;;

let metric_keeper_compact_audit_drain_batch_size_bucket =
  "masc_keeper_compact_audit_drain_batch_size_bucket_total"
;;

let metric_keeper_fs_failures = "masc_keeper_fs_failures_total"

let metric_keeper_crash_persistence_failures =
  "masc_keeper_crash_persistence_failures_total"
;;

let metric_keeper_generation_lineage_failures =
  "masc_keeper_generation_lineage_failures_total"
;;

let metric_keeper_keepalive_signal_failures =
  "masc_keeper_keepalive_signal_failures_total"
;;

let metric_keeper_board_signal_wakeup_capped_total =
  "masc_keeper_board_signal_wakeup_capped_total"
;;

let metric_keeper_board_signal_no_wake_total = "masc_keeper_board_signal_no_wake_total"
let metric_keeper_meta_json_failures = "masc_keeper_meta_json_failures_total"
let metric_keeper_tools_oas_failures = "masc_keeper_tools_oas_failures_total"

let metric_keeper_tools_oas_deterministic_failures =
  "masc_keeper_tools_oas_deterministic_failures_total"
;;

let metric_keeper_oas_hook_output_parse_failures =
  "masc_keeper_oas_hook_output_parse_failures_total"
;;

let metric_keeper_turn_up_update_failures = "masc_keeper_turn_up_update_failures_total"
let metric_keeper_exec_tools_failures = "masc_keeper_exec_tools_failures_total"
let metric_keeper_circuit_breaker_trips = "masc_keeper_circuit_breaker_trips_total"
let metric_keeper_prompt_failures = "masc_keeper_prompt_failures_total"
let metric_keeper_run_context_failures = "masc_keeper_run_context_failures_total"
let metric_keeper_shell_ops_failures = "masc_keeper_shell_ops_failures_total"
let metric_keeper_tag_dispatch_failures = "masc_keeper_tag_dispatch_failures_total"
let metric_keeper_trace_emit_failures = "masc_keeper_trace_emit_failures_total"

let metric_keeper_transition_audit_failures =
  "masc_keeper_transition_audit_failures_total"
;;

let metric_keeper_execution_receipt_failures =
  "masc_keeper_execution_receipt_failures_total"
;;

let metric_keeper_operator_broadcast_suppressed =
  "masc_keeper_operator_broadcast_suppressed_total"
;;

let metric_keeper_llm_bridge_failures = "masc_keeper_llm_bridge_failures_total"
let metric_keeper_shell_bash_failures = "masc_keeper_shell_bash_failures_total"
let metric_keeper_rollover_failures = "masc_keeper_rollover_failures_total"

let metric_keeper_lifecycle_dispatch_rejections =
  "masc_keeper_lifecycle_dispatch_rejections_total"
;;

let metric_keeper_recording_error_dedup =
  "masc_keeper_recording_error_dedup_total"
;;

let metric_keeper_paused_state_persist_errors =
  "masc_keeper_paused_state_persist_errors_total"
;;

let metric_keeper_unexpected_tool_partial_tolerance =
  "masc_keeper_unexpected_tool_partial_tolerance_total"
;;

let metric_keeper_require_tool_use_violations =
  "masc_keeper_require_tool_use_violations_total"
;;

let metric_keeper_tool_call_total = "masc_keeper_tool_call_total"
let metric_keeper_profile_config_conflicts = "masc_keeper_profile_config_conflicts_total"

let metric_keeper_oas_timeout_classifications =
  "masc_keeper_oas_timeout_classifications_total"
;;

let metric_keeper_no_tool_provider = "masc_keeper_no_tool_provider_total"
let metric_keeper_proactive_outcome = "masc_keeper_proactive_outcome_total"
let metric_keeper_ollama_saturation_skip = "masc_keeper_ollama_saturation_skip_total"
let metric_keeper_task_load_failures = "masc_keeper_task_load_failures_total"
let metric_keeper_tool_selection_failures = "masc_keeper_tool_selection_failures_total"
let metric_keeper_tool_policy_failures = "masc_keeper_tool_policy_failures_total"
let metric_keeper_reconcile_failures = "masc_keeper_reconcile_failures_total"

let metric_keeper_decision_audit_flush_failures =
  "masc_keeper_decision_audit_flush_failures_total"
;;

let metric_keeper_oas_cancel = "masc_keeper_oas_cancel_total"
let metric_keeper_claim_auto_provision = "masc_keeper_claim_auto_provision_total"
let metric_keeper_toml_invalid = "masc_keeper_toml_invalid_total"
let metric_keeper_persona_drift_missing = "masc_keeper_persona_drift_missing_total"
let metric_keeper_room_init_failures = "masc_keeper_room_init_failures_total"
let metric_keeper_presence_sync_failures = "masc_keeper_presence_sync_failures_total"

let metric_keeper_self_preservation_universal =
  "masc_keeper_self_preservation_universal_total"
;;

let metric_keeper_stale_storm_paused = "masc_keeper_stale_storm_paused_total"

let metric_keeper_provider_timeout_loop_paused =
  "masc_keeper_provider_timeout_loop_paused_total"
;;

let metric_keeper_cycle_exceptions = "masc_keeper_cycle_exceptions_total"
let metric_keeper_snapshot_write_failures = "masc_keeper_snapshot_write_failures_total"

(** Counts post-turn invocations where neither the LLM reply nor the OAS
    checkpoint produced a state snapshot.  Used to detect prompt / cascade
    drift; a keeper that never emits state has no reflection content for
    the compaction cooldown to protect. *)
let metric_keeper_state_snapshot_skipped_no_state =
  "masc_keeper_state_snapshot_skipped_no_state_total"
;;

let metric_keeper_progress_updated_line_failures =
  "masc_keeper_progress_updated_line_failures_total"
;;

let metric_keeper_sse_broadcast_failures = "masc_keeper_sse_broadcast_failures_total"
let metric_keeper_room_heartbeat_failures = "masc_keeper_room_heartbeat_failures_total"

let metric_keeper_turn_metrics_snapshot_failures =
  "masc_keeper_turn_metrics_snapshot_failures_total"
;;

let metric_keeper_oas_execution_errors = "masc_keeper_oas_execution_errors_total"
let metric_keeper_episode_create_failures = "masc_keeper_episode_create_failures_total"

let metric_keeper_memory_activity_emit_failures =
  "masc_keeper_memory_activity_emit_failures_total"
;;

let metric_keeper_supervisor_sweep_failures =
  "masc_keeper_supervisor_sweep_failures_total"
;;

let metric_keeper_toml_reconcile_sweep_failures =
  "masc_keeper_toml_reconcile_sweep_failures_total"
;;

(** Repeated TOML reconcile failures for a keeper (after the first
    [`First] WARN). Labeled by keeper and outcome. Used as a back-off
    observability surface for the [keeper_runtime] periodic beat. *)
let metric_keeper_toml_reconcile_dedup =
  "masc_keeper_toml_reconcile_dedup_total"
;;

(** Keepers whose TOML reconcile reached [default_disable_threshold]
    consecutive failures and have been parked. Labeled by keeper. The
    reconciler resumes when TOML mtime changes. *)
let metric_keeper_reconcile_disabled =
  "masc_keeper_reconcile_disabled_total"
;;

let metric_keeper_tool_usage_flush_failures =
  "masc_keeper_tool_usage_flush_failures_total"
;;

let metric_keeper_turn_timeout_committed = "masc_keeper_turn_timeout_committed_total"
let metric_keeper_turn_error_after_tools = "masc_keeper_turn_error_after_tools_total"
let metric_keeper_cascade_sync_failures = "masc_keeper_cascade_sync_failures_total"
let metric_keeper_local_discovery_failures = "masc_keeper_local_discovery_failures_total"

let metric_keeper_thinking_persist_failures =
  "masc_keeper_thinking_persist_failures_total"
;;

let metric_keeper_checkpoint_failures = "masc_keeper_checkpoint_failures_total"
let metric_keeper_decision_audit_ring_overflows =
  "masc_keeper_decision_audit_ring_overflows_total"
;;

let metric_keeper_reply_skill_route_strips =
  "masc_keeper_reply_skill_route_strips_total"
;;

let metric_keeper_reply_skill_route_lines_removed =
  "masc_keeper_reply_skill_route_lines_removed_total"
;;

let metric_keeper_memory_llm_summary_outcomes =
  "masc_keeper_memory_llm_summary_outcomes_total"
;;

let metric_keeper_memory_llm_summary_chain_exhausted =
  "masc_keeper_memory_llm_summary_chain_exhausted_total"
;;

let metric_keeper_memory_jsonl_ops =
  "masc_keeper_memory_jsonl_ops_total"
;;

let metric_keeper_user_visible_reply_source =
  "masc_keeper_user_visible_reply_source_total"
;;

let metric_keeper_continuity_summary_source =
  "masc_keeper_continuity_summary_source_total"
;;

let metric_keeper_summarizer_state_scrubs =
  "masc_keeper_summarizer_state_scrubs_total"
;;

let metric_keeper_summarizer_state_blocks_removed =
  "masc_keeper_summarizer_state_blocks_removed_total"
;;

let metric_keeper_oas_env_key_rejections =
  "masc_keeper_oas_env_key_rejections_total"
;;

let metric_keeper_continuity_ts_recovered =
  "masc_keeper_continuity_ts_recovered_total"
;;

let metric_keeper_memory_write_failures = "masc_keeper_memory_write_failures_total"
let metric_keeper_memory_consolidations = "masc_keeper_memory_consolidations_total"

let metric_keeper_write_meta_cycle_failures =
  "masc_keeper_write_meta_cycle_failures_total"
;;

let metric_keeper_alert_persist_failures = "masc_keeper_alert_persist_failures_total"
let metric_keeper_metrics_sse_failures = "masc_keeper_metrics_sse_failures_total"
let metric_keeper_chat_store_failures = "masc_keeper_chat_store_failures_total"

let metric_keeper_observation_query_failures =
  "masc_keeper_observation_query_failures_total"
;;

let metric_keeper_oas_on_stop = "masc_keeper_oas_on_stop_total"
let metric_keeper_oas_on_idle_escalated = "masc_keeper_oas_on_idle_escalated_total"

let metric_keeper_quantitative_claim_rejections =
  "masc_keeper_quantitative_claim_rejections_total"
;;

let metric_keeper_invariant_violations = "masc_keeper_invariant_violations_total"
let metric_keeper_fsm_edge_transitions = "masc_keeper_fsm_edge_transitions_total"
let metric_keeper_turn_fsm_transitions = "masc_keeper_turn_fsm_transitions_total"
let metric_keeper_turn_phase_duration = "masc_keeper_turn_phase_duration_seconds"
let metric_keeper_lifecycle_transitions = "masc_keeper_lifecycle_transitions_total"

let metric_keeper_lifecycle_callback_failures =
  "masc_keeper_lifecycle_callback_failures_total"
;;

(* Counter for the [last_event.source] provenance marker emitted by
   [Briefing_compactors.compact_session_json] (PR #15777, V14 follow-up).
   Wrapper-side observer at [dashboard_mission_briefing] keeps the
   [briefing_compactors] leaf sublib Prometheus-free. *)
let metric_briefing_session_last_event_source =
  "masc_briefing_session_last_event_source_total"
;;

let metric_keeper_event_bus_drain = "masc_keeper_event_bus_drain_total"

let metric_keeper_supervisor_cleanup_failures =
  "masc_keeper_supervisor_cleanup_failures_total"
;;

let metric_keeper_slot_force_released = "masc_keeper_slot_force_released_total"
let metric_keeper_spawn_slot_denied = "masc_keeper_spawn_slot_denied_total"
let metric_keeper_registry_update_dropped = "masc_keeper_registry_update_dropped_total"

let metric_keeper_registry_orphan_threshold_breached =
  "masc_keeper_registry_orphan_threshold_breached_total"
;;

let metric_keeper_stale_watchdog_tick_failures =
  "masc_keeper_stale_watchdog_tick_failures_total"
;;

let metric_keeper_dead_total = "masc_keeper_dead_total"
let metric_keeper_auto_resumed_total = "masc_keeper_auto_resumed_total"
let metric_keeper_auto_resume_blocked_total = "masc_keeper_auto_resume_blocked_total"
let metric_keeper_skip_idle_wake_resumed = "masc_keeper_skip_idle_wake_resumed_total"
let metric_keeper_event_queue_override = "masc_keeper_event_queue_override_total"
let metric_keeper_stimulus_consumed = "masc_keeper_stimulus_consumed_total"
let metric_keeper_unsupported_stimulus = "masc_keeper_unsupported_stimulus_total"
let metric_keeper_near_exhaustion_total = "masc_keeper_near_exhaustion_total"
let metric_keeper_restart_attempts = "masc_keeper_restart_attempts_total"
let metric_keeper_restart_outcomes = "masc_keeper_restart_outcomes_total"

let metric_keeper_liveness_recovery_attempts =
  "masc_keeper_liveness_recovery_attempts_total"
;;

let metric_keeper_liveness_recovery_outcomes =
  "masc_keeper_liveness_recovery_outcomes_total"
;;

let metric_keeper_passive_loop_detected_total = "masc_keeper_passive_loop_detected_total"
let metric_keeper_passive_loop_streak = "masc_keeper_passive_loop_streak"

let metric_keeper_passive_loop_streak_exceeded =
  "masc_keeper_passive_loop_streak_exceeded_total"
;;

let metric_keeper_required_tool_loop_detected_total =
  "masc_keeper_required_tool_loop_detected_total"
;;

let metric_keeper_zombie_loop_detected_total = "masc_keeper_zombie_loop_detected_total"

let metric_keeper_required_tool_gate_suppressed_total =
  "masc_keeper_required_tool_gate_suppressed_total"
;;

let metric_keeper_consecutive_idle = "masc_keeper_consecutive_idle"
let metric_keeper_last_productive_ts = "masc_keeper_last_productive_ts"

let metric_keeper_provider_timeout_strike =
  "masc_keeper_provider_timeout_strike_total"
;;

let metric_keeper_stale_termination_total = "masc_keeper_stale_termination_total"

let metric_keeper_stale_termination_by_class =
  "masc_keeper_stale_termination_by_class_total"
;;

let metric_keeper_provider_timeout_watchdog_termination =
  "masc_keeper_provider_timeout_watchdog_termination_total"
;;

let metric_keeper_stale_termination_threshold_breached =
  "masc_keeper_stale_termination_threshold_breached_total"
;;

let metric_keeper_stale_termination_batch = "masc_keeper_stale_termination_batch_total"

let metric_keeper_stale_broadcast_emit_failures =
  "masc_keeper_stale_broadcast_emit_failures"
;;

let metric_keeper_oas_run_timeout = "masc_keeper_oas_run_timeout_total"

(* RFC-0153 Phase A.2: typed Cascade_saturation_signal emission counter.
   Incremented from cascade_attempt_fsm when MASC_CASCADE_SATURATION_SIGNAL_ENABLED
   is set. Labels: [kind] from Cascade_saturation_signal.kind_to_string,
   [cascade] from cascade_name_to_string. Phase A.2 is additive only —
   no behaviour change. Phase B/C are the consumers. *)
let metric_keeper_cascade_saturation_signal =
  "masc_keeper_cascade_saturation_signal_total"
;;

let metric_keeper_tool_use_failure = "masc_keeper_tool_use_failure_total"
let metric_keeper_tool_not_allowed = "masc_keeper_tool_not_allowed_total"

let metric_keeper_turn_gate_rejected_terminal =
  "masc_keeper_turn_gate_rejected_terminal_total"
;;

let metric_keeper_receipt_unmapped_disposition =
  "masc_keeper_receipt_unmapped_disposition_total"
;;

let metric_keeper_bash_network_upgrade = "masc_keeper_bash_network_upgrade_total"
let metric_keeper_bash_local_execution = "masc_keeper_bash_local_execution_total"
let metric_keeper_docker_runtime_discarded = "masc_keeper_docker_runtime_discarded_total"
let metric_keeper_proactive_skip = "masc_keeper_proactive_skip_total"

let metric_keeper_stay_silent_loop_detected =
  "masc_keeper_stay_silent_loop_detected_total"
;;

let metric_keeper_usage_trust = "masc_keeper_usage_trust_total"
let metric_keeper_usage_anomaly_reason = "masc_keeper_usage_anomaly_reason_total"

let metric_keeper_config_env_parse_failures =
  "masc_keeper_config_env_parse_failures_total"
;;

let metric_keeper_post_turn_wirein_failures =
  "masc_keeper_post_turn_wirein_failures_total"
;;

let metric_keeper_recurring_failures = "masc_keeper_recurring_failures_total"
let metric_keeper_turn_cleanup_failures = "masc_keeper_turn_cleanup_failures_total"
let metric_keeper_session_cleanup_failures = "masc_keeper_session_cleanup_failures_total"

let metric_keeper_memory_bank_load_history_swallowed_exceptions =
  "masc_keeper_memory_bank_load_history_swallowed_exceptions_total"
;;

let metric_keeper_memory_recall_read_errors =
  "masc_keeper_memory_recall_read_errors_total"
;;

let metric_cascade_http_probe_json_parse_failures =
  "masc_cascade_http_probe_json_parse_failures_total"
;;
