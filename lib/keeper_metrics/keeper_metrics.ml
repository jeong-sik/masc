(** Keeper domain metrics.

    Each keeper metric is owned by this module; Otel_metric_store.ml only provides
    the generic registry. *)

(** Variant type

   Compile-time safe metric identifiers.
   Wrong metric name = type error, not runtime string mismatch.
*)

type t =
  | Turns
  | InputTokens
  | OutputTokens
  | CacheCreationTokens
  | CacheReadTokens
  | UsageAnomalies
  | TotalCostUsd
  | TurnScheduled
  | TurnCompleted
  | FailureRoute
  | IdleSeconds
  | InFlightElapsedSeconds
  | SinceLastProgressSeconds
  | StreamProjectionEventCutoff
  | MetricEmitDropped
  | ContextMaxObserved
  | TurnStarts
  | TurnReattempts
  | TurnRegressions
  | TurnLatencyBucket
  | TurnLatencyByModelBucket
  | ProviderCooldownRemainingSec
  | ProviderBlockDurationSec
  | TurnQueueDepth
  | SupervisorSweepStarts
  | SupervisorLastSweepUnixtime
  | TurnHolderBookkeepingFailures
  | OperatorCompact
  | OperatorClear
  | ToolEmissionRegistrySize
  | ToolEmissionPushes
  | ToolUnderusedAllowedCount
  | ToolUnderusedAllowed
  | PathRejection
  | PathResolverIdentityMismatch
  | KeeperMetaOverlayDrift
  | HeartbeatSuccesses
  | HeartbeatFailures
  | CleanupTrackingFailures
  | DispatchEventFailures
  | DirectiveFailures
  | ToolCallDuration
  | ToolCallDurationBucket
  | WriteMetaFailures
  | MetaReadFailures
  | ApprovalQueueFailures
  | ApprovalResolutionSignal
  | ProfileLoadFailures
  | FsFailures
  | PersistencePreparationStageDuration
  | PersistencePreparationExamined
  | PersistenceLaneWaits
  | PersistenceLanePending
  | PersistenceLaneInFlight
  | PersistenceLaneDuration
  | CrashPersistenceFailures
  | KeepaliveSignalFailures
  | BoardSignalRoutedTotal
  | BoardSignalCursorDeferredTotal
  | BoardSignalDeliveryTotal
  | BoardSignalNoWakeTotal
  | BoardSignalAttentionCandidateTotal
  | MetaJsonFailures
  | ToolsAgent_coreFailures
  | TurnUpUpdateFailures
  | AgentToolDispatchRuntimeFailures
  | PromptFailures
  | RunContextFailures
  | SearchFilesFailures
  | TagDispatchFailures
  | TraceEmitFailures
  | TransitionAuditFailures
  | ExecutionReceiptFailures
  | SessionCleanupFailures
  | ToolExecuteFailures
  | RolloverFailures
  | LifecycleDispatchRejections
  | LifecycleTransactions
  | RecordingErrorDedup
  | PausedStatePersistErrors
  | UnexpectedToolPartialTolerance
  | ToolCallTotal
  | ProfileConfigConflicts
  | Agent_coreTimeoutClassifications
  | NoToolProvider
  | ProactiveOutcome
  | TaskLoadFailures
  | ToolSelectionFailures
  | ReconcileFailures
  | DecisionAuditFlushFailures
  | Agent_coreCancel
  | ClaimAutoProvision
  | WorkspaceInitFailures
  | PresenceSyncFailures
  | StaleStormPaused
  | CycleExceptions
  | SnapshotReadFailures
  | SnapshotWriteFailures
  | SseBroadcastFailures
  | WorkspaceHeartbeatFailures
  | TurnMetricsSnapshotFailures
  | Agent_coreExecutionErrors
  | MemoryOsLibrarianFailures
  | MemoryActivityEmitFailures
  | SupervisorSweepFailures
  | TomlReconcileSweepFailures
  | ToolUsageFlushFailures
  | TurnTimeoutCommitted
  | TurnErrorAfterTools
  | RuntimeSyncFailures
  | LocalDiscoveryFailures
  | ThinkingPersistFailures
  | CheckpointFailures
  | DecisionAuditRingOverflows
  | HitlSummaryOutcomes
  | Agent_coreEnvKeyRejections
  | MemoryLaneUnitFailures
  | MemoryLaneSubmitted
  | MemoryLaneRanInline
  | MemoryLaneDropped
  | MemoryLaneRejectedDraining
  | MemoryLaneCoalesced
  | MemoryLanePending
  | MemoryLaneInFlight
  | MemoryLaneLatestPending
  | MemoryLaneExecutionSlotBusy
  | WriteMetaCycleFailures
  | MetricsSseFailures
  | ChatStoreFailures
  | ChatTransportFailures
  | PersonNoteStoreFailures
  | KeeperMaterializationFailures
  | ObservationQueryFailures
  | Agent_coreOnStop
  | InvariantViolations
  | FsmEdgeTransitions
  | TurnFsmTransitions
  | TurnPhaseDuration
  | LifecycleTransitions
  | LifecycleCallbackFailures
  | EventBusDrain
  | SupervisorCleanupFailures
  | RegistryUpdateDropped
  | RegistryOrphanThresholdBreached
  | RegistryInvalidEntry
  | StimulusConsumed
  | UnsupportedStimulus
  | RestartAttempts
  | RestartOutcomes
  | Agent_coreRunTimeout
  | RuntimeSelected
  | RuntimeRotation
  | ToolUseFailure
  | ToolNotAllowed
  | ReceiptUnmappedDisposition
  | ExecuteNetworkUpgrade
  | ExecuteLocalExecution
  | DockerRuntimeDiscarded
  | ProactiveSkip
  | NoProgressStreak
  | UsageTrust
  | UsageAnomalyReason
  | ConfigEnvParseFailures
  | PostTurnWireinFailures
  | TurnCleanupFailures
  | MemoryRecallHistorySwallowedExceptions
  | MemoryRecallReadErrors
  | MemoryOsRecallUnavailable
  | MemoryOsExplicitFactWrite
  | RuntimeRequestWireBytes
  | RuntimeHttpProbeJsonParseFailures
  | VisionAnalyze
  | VisionCandidateAttempts
  | VisionIngestEvictions
  | VisionIngestErrors
  (* Instruction monitoring metrics *)
  | PromptSegmentBytes          (* histogram: bytes per prompt segment *)
  | PromptTemplateRenderOutcome (* counter: template render ok/fallback/empty *)
  | ToolCallParamCompleteness   (* counter: tool calls with all required params vs missing *)
  | KeeperTurnInstructionHash   (* gauge: hash of system+user prompt for change detection *)
  | KeeperToolCallRetryLoop     (* counter: consecutive identical tool calls with errors *)
  | ShellIrEffectTotal          (* counter: fine-grained Shell IR effect decomposition *)
  | RawTraceSinkDegraded        (* counter: raw-trace sink create failed; turn dispatched untraced *)
  | RawTraceRetentionDeleted   (* counter: unreachable raw-trace files deleted after TurnRecord commit *)
  | RawTraceRetentionSkipped   (* counter: retention skipped because the reachability root was uncertain *)
  | RawTraceRetentionUnlinkFailed (* counter: unreachable raw-trace files that could not be deleted *)
  | WireCaptureResponseSuppressed (* counter: keeper-visible response suppressed before wire capture *)
  | WireCaptureWriteFailures    (* counter: wire-capture write raised an exception *)
  | WireCaptureRecordSkipped    (* counter: wire-capture record dropped — rotation name space exhausted or append guard refused *)
[@@deriving enumerate]

(** String conversion

   Compile-time safe metric identifiers.
   Wrong metric name = type error, not runtime string mismatch.
*)

let to_string = function
  | Turns -> "masc_keeper_turns_total"
  | InputTokens -> "masc_keeper_input_tokens_total"
  | OutputTokens -> "masc_keeper_output_tokens_total"
  | CacheCreationTokens -> "masc_keeper_cache_creation_tokens_total"
  | CacheReadTokens -> "masc_keeper_cache_read_tokens_total"
  | UsageAnomalies -> "masc_keeper_usage_anomalies_total"
  | TotalCostUsd -> "masc_keeper_total_cost_usd"
  | TurnScheduled -> "masc_keeper_turn_scheduled_total"
  | TurnCompleted -> "masc_keeper_turn_completed_total"
  | FailureRoute -> "masc_keeper_failure_route_total"
  | IdleSeconds -> "masc_keeper_idle_seconds"
  | InFlightElapsedSeconds -> "masc_keeper_in_flight_elapsed_seconds"
  | SinceLastProgressSeconds -> "masc_keeper_since_last_progress_seconds"
  | StreamProjectionEventCutoff ->
    "masc_keeper_stream_projection_event_cutoff_total"
  | MetricEmitDropped -> "masc_keeper_metric_emit_dropped_total"
  | ContextMaxObserved -> "masc_keeper_context_max_observed_total"
  | TurnStarts -> "masc_keeper_turn_starts_total"
  | TurnReattempts -> "masc_keeper_turn_reattempts_total"
  | TurnRegressions -> "masc_keeper_turn_regressions_total"
  | TurnLatencyBucket -> "masc_keeper_turn_latency_bucket_total"
  | TurnLatencyByModelBucket -> "masc_keeper_turn_latency_by_model_bucket_total"
  | ProviderCooldownRemainingSec -> "masc_keeper_provider_cooldown_remaining_sec"
  | ProviderBlockDurationSec -> "masc_keeper_provider_block_duration_sec"
  | TurnQueueDepth -> "masc_keeper_turn_queue_depth"
  | SupervisorSweepStarts -> "masc_keeper_supervisor_sweep_starts_total"
  | SupervisorLastSweepUnixtime -> "masc_keeper_supervisor_last_sweep_unixtime"
  | TurnHolderBookkeepingFailures -> "masc_keeper_turn_holders_bookkeeping_failures_total"
  | OperatorCompact -> "masc_keeper_operator_compact_total"
  | OperatorClear -> "masc_keeper_operator_clear_total"
  | ToolEmissionRegistrySize -> "masc_keeper_tool_emission_registry_size"
  | ToolEmissionPushes -> "masc_keeper_tool_emission_pushes_total"
  | ToolUnderusedAllowedCount -> "masc_keeper_tool_underused_allowed_count"
  | ToolUnderusedAllowed -> "masc_keeper_tool_underused_allowed"
  | PathRejection -> "masc_keeper_path_rejection_total"
  | PathResolverIdentityMismatch -> "masc_keeper_path_resolver_identity_mismatch_total"
  | KeeperMetaOverlayDrift -> "masc_keeper_meta_overlay_drift_total"
  | HeartbeatSuccesses -> "masc_keeper_heartbeat_successes_total"
  | HeartbeatFailures -> "masc_keeper_heartbeat_failures_total"
  | CleanupTrackingFailures -> "masc_keeper_cleanup_tracking_failures_total"
  | DispatchEventFailures -> "masc_keeper_dispatch_event_failures_total"
  | DirectiveFailures -> "masc_keeper_directive_failures_total"
  | ToolCallDuration -> "masc_keeper_tool_call_duration_seconds"
  | ToolCallDurationBucket -> "masc_keeper_tool_call_duration_seconds_bucket_total"
  | WriteMetaFailures -> "masc_keeper_write_meta_failures_total"
  | MetaReadFailures -> "masc_keeper_meta_read_failures_total"
  | ApprovalQueueFailures -> "masc_keeper_approval_queue_failures_total"
  | ApprovalResolutionSignal -> "masc_keeper_approval_resolution_signal_total"
  | ProfileLoadFailures -> "masc_keeper_profile_load_failures_total"
  | FsFailures -> "masc_keeper_fs_failures_total"
  | PersistencePreparationStageDuration ->
    "masc_keeper_persistence_preparation_stage_duration_seconds"
  | PersistencePreparationExamined ->
    "masc_keeper_persistence_preparation_examined_records"
  | PersistenceLaneWaits -> "masc_keeper_persistence_lane_waits_total"
  | PersistenceLanePending -> "masc_keeper_persistence_lane_pending"
  | PersistenceLaneInFlight -> "masc_keeper_persistence_lane_in_flight"
  | PersistenceLaneDuration -> "masc_keeper_persistence_lane_duration_seconds"
  | CrashPersistenceFailures -> "masc_keeper_crash_persistence_failures_total"
  | KeepaliveSignalFailures -> "masc_keeper_keepalive_signal_failures_total"
  | BoardSignalRoutedTotal -> "masc_keeper_board_signal_routed_total"
  | BoardSignalCursorDeferredTotal ->
    "masc_keeper_board_signal_cursor_deferred_total"
  | BoardSignalDeliveryTotal -> "masc_keeper_board_signal_delivery_total"
  | BoardSignalNoWakeTotal -> "masc_keeper_board_signal_no_wake_total"
  | BoardSignalAttentionCandidateTotal ->
    "masc_keeper_board_signal_attention_candidate_total"
  | MetaJsonFailures -> "masc_keeper_meta_json_failures_total"
  | ToolsAgent_coreFailures -> "masc_keeper_tools_agent_core_failures_total"
  | TurnUpUpdateFailures -> "masc_keeper_turn_up_update_failures_total"
  | AgentToolDispatchRuntimeFailures -> "masc_keeper_tool_dispatch_runtime_failures_total"
  | PromptFailures -> "masc_keeper_prompt_failures_total"
  | RunContextFailures -> "masc_keeper_run_context_failures_total"
  | SearchFilesFailures -> "masc_keeper_search_files_failures_total"
  | TagDispatchFailures -> "masc_keeper_tag_dispatch_failures_total"
  | TraceEmitFailures -> "masc_keeper_trace_emit_failures_total"
  | TransitionAuditFailures -> "masc_keeper_transition_audit_failures_total"
  | ExecutionReceiptFailures -> "masc_keeper_execution_receipt_failures_total"
  | SessionCleanupFailures -> "masc_keeper_session_cleanup_failures_total"
  | ToolExecuteFailures -> "masc_keeper_tool_execute_runtime_failures_total"
  | RolloverFailures -> "masc_keeper_rollover_failures_total"
  | LifecycleDispatchRejections -> "masc_keeper_lifecycle_dispatch_rejections_total"
  | LifecycleTransactions -> "masc_keeper_lifecycle_transactions_total"
  | RecordingErrorDedup -> "masc_keeper_recording_error_dedup_total"
  | PausedStatePersistErrors -> "masc_keeper_paused_state_persist_errors_total"
  | UnexpectedToolPartialTolerance ->
    "masc_keeper_unexpected_tool_partial_tolerance_total"
  | ToolCallTotal -> "masc_keeper_tool_call_total"
  | ProfileConfigConflicts -> "masc_keeper_profile_config_conflicts_total"
  | Agent_coreTimeoutClassifications -> "masc_keeper_agent_core_timeout_classifications_total"
  | NoToolProvider -> "masc_keeper_no_tool_provider_total"
  | ProactiveOutcome -> "masc_keeper_proactive_outcome_total"
  | TaskLoadFailures -> "masc_keeper_task_load_failures_total"
  | ToolSelectionFailures -> "masc_keeper_tool_selection_failures_total"
  | ReconcileFailures -> "masc_keeper_reconcile_failures_total"
  | DecisionAuditFlushFailures -> "masc_keeper_decision_audit_flush_failures_total"
  | Agent_coreCancel -> "masc_keeper_agent_core_cancel_total"
  | ClaimAutoProvision -> "masc_keeper_claim_auto_provision_total"
  | WorkspaceInitFailures -> "masc_keeper_workspace_init_failures_total"
  | PresenceSyncFailures -> "masc_keeper_presence_sync_failures_total"
  | StaleStormPaused -> "masc_keeper_stale_storm_paused_total"
  | CycleExceptions -> "masc_keeper_cycle_exceptions_total"
  | SnapshotReadFailures -> "masc_keeper_snapshot_read_failures_total"
  | SnapshotWriteFailures -> "masc_keeper_snapshot_write_failures_total"
  | SseBroadcastFailures -> "masc_keeper_sse_broadcast_failures_total"
  | WorkspaceHeartbeatFailures -> "masc_keeper_workspace_heartbeat_failures_total"
  | TurnMetricsSnapshotFailures -> "masc_keeper_turn_metrics_snapshot_failures_total"
  | Agent_coreExecutionErrors -> "masc_keeper_agent_core_execution_errors_total"
  | MemoryOsLibrarianFailures -> "masc_keeper_memory_os_librarian_failures_total"
  | MemoryActivityEmitFailures -> "masc_keeper_memory_activity_emit_failures_total"
  | SupervisorSweepFailures -> "masc_keeper_supervisor_sweep_failures_total"
  | TomlReconcileSweepFailures -> "masc_keeper_toml_reconcile_sweep_failures_total"
  | ToolUsageFlushFailures -> "masc_keeper_tool_usage_flush_failures_total"
  | TurnTimeoutCommitted -> "masc_keeper_turn_timeout_committed_total"
  | TurnErrorAfterTools -> "masc_keeper_turn_error_after_tools_total"
  | RuntimeSyncFailures -> "masc_keeper_runtime_sync_failures_total"
  | LocalDiscoveryFailures -> "masc_keeper_local_discovery_failures_total"
  | ThinkingPersistFailures -> "masc_keeper_thinking_persist_failures_total"
  | CheckpointFailures -> "masc_keeper_checkpoint_failures_total"
  | DecisionAuditRingOverflows -> "masc_keeper_decision_audit_ring_overflows_total"
  | HitlSummaryOutcomes -> "masc_keeper_hitl_summary_outcomes_total"
  | Agent_coreEnvKeyRejections -> "masc_keeper_agent_core_env_key_rejections_total"
  | MemoryLaneUnitFailures -> "masc_keeper_memory_lane_unit_failures_total"
  | MemoryLaneSubmitted -> "masc_keeper_memory_lane_submitted_total"
  | MemoryLaneRanInline -> "masc_keeper_memory_lane_ran_inline_total"
  | MemoryLaneDropped -> "masc_keeper_memory_lane_dropped_total"
  | MemoryLaneRejectedDraining ->
    "masc_keeper_memory_lane_rejected_draining_total"
  | MemoryLaneCoalesced -> "masc_keeper_memory_lane_coalesced_total"
  | MemoryLanePending -> "masc_keeper_memory_lane_pending"
  | MemoryLaneInFlight -> "masc_keeper_memory_lane_in_flight"
  | MemoryLaneLatestPending -> "masc_keeper_memory_lane_latest_pending"
  | MemoryLaneExecutionSlotBusy -> "masc_keeper_memory_lane_execution_slot_busy_total"
  | WriteMetaCycleFailures -> "masc_keeper_write_meta_cycle_failures_total"
  | MetricsSseFailures -> "masc_keeper_metrics_sse_failures_total"
  | ChatStoreFailures -> "masc_keeper_chat_store_failures_total"
  | ChatTransportFailures -> "masc_keeper_chat_transport_failures_total"
  | PersonNoteStoreFailures -> "masc_keeper_person_note_store_failures_total"
  | KeeperMaterializationFailures -> "masc_keeper_materialization_failures_total"
  | ObservationQueryFailures -> "masc_keeper_observation_query_failures_total"
  | Agent_coreOnStop -> "masc_keeper_agent_core_on_stop_total"
  | InvariantViolations -> "masc_keeper_invariant_violations_total"
  | FsmEdgeTransitions -> "masc_keeper_fsm_edge_transitions_total"
  | TurnFsmTransitions -> "masc_keeper_turn_fsm_transitions_total"
  | TurnPhaseDuration -> "masc_keeper_turn_phase_duration_seconds"
  | LifecycleTransitions -> "masc_keeper_lifecycle_transitions_total"
  | LifecycleCallbackFailures -> "masc_keeper_lifecycle_callback_failures_total"
  | EventBusDrain -> "masc_keeper_event_bus_drain_total"
  | SupervisorCleanupFailures -> "masc_keeper_supervisor_cleanup_failures_total"
  | RegistryUpdateDropped -> "masc_keeper_registry_update_dropped_total"
  | RegistryOrphanThresholdBreached ->
    "masc_keeper_registry_orphan_threshold_breached_total"
  | RegistryInvalidEntry -> "masc_keeper_registry_invalid_entry_total"
  | StimulusConsumed -> "masc_keeper_stimulus_consumed_total"
  | UnsupportedStimulus -> "masc_keeper_unsupported_stimulus_total"
  | RestartAttempts -> "masc_keeper_restart_attempts_total"
  | RestartOutcomes -> "masc_keeper_restart_outcomes_total"
  | Agent_coreRunTimeout -> "masc_keeper_agent_core_run_timeout_total"
  | RuntimeSelected -> "masc_keeper_runtime_selected_total"
  | RuntimeRotation -> "masc_keeper_runtime_rotation_total"
  | ToolUseFailure -> "masc_keeper_tool_use_failure_total"
  | ToolNotAllowed -> "masc_keeper_tool_not_allowed_total"
  | ReceiptUnmappedDisposition -> "masc_keeper_receipt_unmapped_disposition_total"
  | ExecuteNetworkUpgrade -> "masc_keeper_execute_network_upgrade_total"
  | ExecuteLocalExecution -> "masc_keeper_execute_local_execution_total"
  | DockerRuntimeDiscarded -> "masc_keeper_docker_runtime_discarded_total"
  | ProactiveSkip -> "masc_keeper_proactive_skip_total"
  | NoProgressStreak -> "masc_keeper_no_progress_streak"
  | UsageTrust -> "masc_keeper_usage_trust_total"
  | UsageAnomalyReason -> "masc_keeper_usage_anomaly_reason_total"
  | ConfigEnvParseFailures -> "masc_keeper_config_env_parse_failures_total"
  | PostTurnWireinFailures -> "masc_keeper_post_turn_wirein_failures_total"
  | TurnCleanupFailures -> "masc_keeper_turn_cleanup_failures_total"
  | MemoryRecallHistorySwallowedExceptions ->
      "masc_keeper_memory_recall_history_swallowed_exceptions_total"
  | MemoryRecallReadErrors ->
      "masc_keeper_memory_recall_read_errors_total"
  | MemoryOsRecallUnavailable ->
      "masc_keeper_memory_os_recall_unavailable_total"
  | MemoryOsExplicitFactWrite ->
      "masc_keeper_memory_os_explicit_fact_write_total"
  | RuntimeRequestWireBytes -> "masc_keeper_runtime_request_wire_bytes"
  | RuntimeHttpProbeJsonParseFailures ->
      "masc_runtime_http_probe_json_parse_failures_total"
  | VisionAnalyze -> "masc_keeper_vision_analyze_total"
  | VisionCandidateAttempts -> "masc_keeper_vision_candidate_attempts_total"
  | VisionIngestEvictions -> "masc_keeper_vision_ingest_evictions_total"
  | VisionIngestErrors -> "masc_keeper_vision_ingest_errors_total"
  | PromptSegmentBytes -> "masc_keeper_prompt_segment_bytes"
  | PromptTemplateRenderOutcome -> "masc_keeper_prompt_template_render_outcome_total"
  | ToolCallParamCompleteness -> "masc_keeper_tool_call_param_completeness_total"
  | KeeperTurnInstructionHash -> "masc_keeper_turn_instruction_hash"
  | KeeperToolCallRetryLoop -> "masc_keeper_tool_call_retry_loop_total"
  | ShellIrEffectTotal -> "masc_keeper_shell_ir_effect_total"
  | RawTraceSinkDegraded -> "masc_keeper_raw_trace_sink_degraded_total"
  | RawTraceRetentionDeleted -> "masc_keeper_raw_trace_retention_deleted_total"
  | RawTraceRetentionSkipped -> "masc_keeper_raw_trace_retention_skipped_total"
  | RawTraceRetentionUnlinkFailed ->
    "masc_keeper_raw_trace_retention_unlink_failed_total"
  | WireCaptureResponseSuppressed ->
    "masc_keeper_wire_capture_response_suppressed_total"
  | WireCaptureWriteFailures -> "masc_keeper_wire_capture_write_failures_total"
  | WireCaptureRecordSkipped -> "masc_keeper_wire_capture_record_skipped_total"
;;

type collection =
  | Metric_store
  | External_observable

let collection = function
  | PersistenceLaneWaits | PersistenceLanePending | PersistenceLaneInFlight ->
    External_observable
  | _ -> Metric_store
;;

let emit_runtime_selected ~keeper_name ~runtime_id ~fallback_reason =
  Otel_metric_store_core.inc_counter
    (to_string RuntimeSelected)
    ~labels:
      [ "keeper", keeper_name
      ; "runtime_id", runtime_id
      ; "source", "fallback"
      ; "fallback_reason", fallback_reason
      ]
    ()
;;

let emit_runtime_rotation ~keeper_name ~from_runtime ~to_runtime ~reason =
  Otel_metric_store_core.inc_counter
    (to_string RuntimeRotation)
    ~labels:
      [ "keeper", keeper_name
      ; "from_runtime", from_runtime
      ; "to_runtime", to_runtime
      ; "reason", reason
      ]
    ()
;;

(* Zero-fill: register the unlabeled 0-cell of every counter at module
   init so each declared keeper counter exports 0 from process start.
   Without this a counter that never fired is indistinguishable in
   Grafana from a counter that is not wired.  Counter detection is by
   [_total] suffix -- most gauges/histograms in [t] do not use it and
   stay lazy (a never-set gauge has no honest value).

   #10125: the supervisor last-sweep gauge is an exception.  Dashboards
   alert on its absence after a server restart, so the unlabeled 0-cell
   must be present from process start to prove the metric is wired. *)
let () =
  List.iter
    (fun m ->
      let name = to_string m in
      match collection m with
      | External_observable -> ()
      | Metric_store ->
        if String.ends_with ~suffix:"_total" name
        then Otel_metric_store_core.register_counter ~name ~help:name ())
    all;
  Otel_metric_store_core.register_gauge
    ~name:(to_string SupervisorLastSweepUnixtime)
    ~help:"Unix timestamp of the last keeper supervisor sweep beat"
    ()
;;
