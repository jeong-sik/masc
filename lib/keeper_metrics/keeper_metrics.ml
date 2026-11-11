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
  | TurnStarts
  | TurnReattempts
  | TurnRegressions
  | TurnLatencyBucket
  | TurnLatencyByModelBucket
  | SupervisorSweepStarts
  | SupervisorLastSweepUnixtime
  | OperatorClear
  | ToolUnderusedAllowedCount
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
  | TagDispatchFailures
  | TraceEmitFailures
  | TransitionAuditFailures
  | ExecutionReceiptFailures
  | SessionCleanupFailures
  | ToolExecuteFailures
  | LifecycleDispatchRejections
  | RecordingErrorDedup
  | PausedStatePersistErrors
  | Agent_coreTimeoutClassifications
  | ProactiveOutcome
  | TaskLoadFailures
  | ToolSelectionFailures
  | ReconcileFailures
  | DecisionAuditFlushFailures
  | WorkspaceInitFailures
  | PresenceSyncFailures
  | CycleExceptions
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
  | MemoryLaneCoalesced
  | MemoryLanePending
  | MemoryLaneInFlight
  | MemoryLaneLatestPending
  | WriteMetaCycleFailures
  | MetricsSseFailures
  | ChatStoreFailures
  | ChatJournalAuditMismatches
  | ChatTransportFailures
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
  | RestartAttempts
  | RestartOutcomes
  | RuntimeSelected
  | ToolUseFailure
  | ReceiptUnmappedDisposition
  | ProactiveSkip
  | UsageTrust
  | UsageAnomalyReason
  | ConfigEnvParseFailures
  | PostTurnWireinFailures
  | TurnCleanupFailures
  | MemoryRecallHistorySwallowedExceptions
  | MemoryRecallReadErrors
  | MemoryOsRecallUnavailable
  | MemoryOsExplicitFactWrite
  | MemorySearch
  | RuntimeRequestWireBytes
  | VisionAnalyze
  | VisionCandidateAttempts
  | VisionIngestEvictions
  | VisionIngestErrors
  | VisionDownscale
  (* Instruction monitoring metrics *)
  | PromptSegmentBytes          (* histogram: bytes per prompt segment *)
  | KeeperTurnInstructionHash   (* gauge: hash of system+user prompt for change detection *)
  | RawTraceSinkDegraded        (* counter: raw-trace sink create failed; turn dispatched untraced *)
  | RawTraceRetentionDeleted   (* counter: unreachable raw-trace files deleted after TurnRecord commit *)
  | RawTraceRetentionSkipped   (* counter: retention skipped because the reachability root was uncertain *)
  | RawTraceRetentionUnlinkFailed (* counter: unreachable raw-trace files that could not be deleted *)
  | WireCaptureResponseSuppressed (* counter: keeper-visible response suppressed before wire capture *)
  | WireCaptureWriteFailures    (* counter: wire-capture write raised an exception *)
  | WireCaptureRecordSkipped    (* counter: wire-capture record dropped — rotation name space exhausted or append guard refused *)
  | TurnBoundaryFailures        (* counter: a turn-boundary line (a turn's end line, or a restart line from a turn or a clear) was not built or not written *)
  | HistoryFragmentFailures     (* counter: a history line (a turn's message or tool observation) was not built or not written *)
  | WorkingStateNotCarried      (* counter: an official client left the Librarian working state out, because carried in front of the range it would have displaced atoms it does not cover *)
  | WorkspaceMemoryBriefingBytes (* gauge: briefing summary bytes observed at the keeper turn boundary *)
  | WorkspaceMemoryLedgerClaims  (* gauge: classified ledger claim count observed at the keeper turn boundary *)
  | MemoryRecallRequests        (* counter: recall judgment requests, by question kind and result *)
  | MemoryRecallInputBytes      (* counter: bytes of the request records the recall judgment saved before sending *)
  | MemoryRecallRequestSeconds  (* histogram: seconds a recall judgment request took, from sending to its result *)
  | MemoryRecallTotal           (* counter: recall judgments, by outcome *)
  | MemoryRecallSelected        (* counter: candidates a recall judgment carried *)
  | MemoryRecallJudgmentSeconds (* histogram: seconds a recall judgment took, from its first request to its saved outcome *)
  | MemoryRecallPreparationFailures (* counter: recall preparation failures, by bounded reason; no judgment is implied *)
  | MemoryChanges               (* counter: memory IDs a store commit added, absorbed, superseded or dropped, by keeper, pass and change *)
  | MemoryFacts                 (* gauge: facts in a keeper's Memory after its last rewriting commit *)
  | MemorySnapshotBytes         (* gauge: rendered fact bytes of a keeper's Memory after its last rewriting commit *)
  | LibrarianAbsorbSources      (* counter: sources of a finished absorb-gate judgment, by keeper, forward outcome and the choice they got *)
  | LibrarianAbsorbCopyChecks   (* counter: reverse copy checks of a finished absorb-gate judgment, by keeper and verdict *)
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
  | TurnStarts -> "masc_keeper_turn_starts_total"
  | TurnReattempts -> "masc_keeper_turn_reattempts_total"
  | TurnRegressions -> "masc_keeper_turn_regressions_total"
  | TurnLatencyBucket -> "masc_keeper_turn_latency_bucket_total"
  | TurnLatencyByModelBucket -> "masc_keeper_turn_latency_by_model_bucket_total"
  | SupervisorSweepStarts -> "masc_keeper_supervisor_sweep_starts_total"
  | SupervisorLastSweepUnixtime -> "masc_keeper_supervisor_last_sweep_unixtime"
  | OperatorClear -> "masc_keeper_operator_clear_total"
  | ToolUnderusedAllowedCount -> "masc_keeper_tool_underused_allowed_count"
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
  | TagDispatchFailures -> "masc_keeper_tag_dispatch_failures_total"
  | TraceEmitFailures -> "masc_keeper_trace_emit_failures_total"
  | TransitionAuditFailures -> "masc_keeper_transition_audit_failures_total"
  | ExecutionReceiptFailures -> "masc_keeper_execution_receipt_failures_total"
  | SessionCleanupFailures -> "masc_keeper_session_cleanup_failures_total"
  | ToolExecuteFailures -> "masc_keeper_tool_execute_runtime_failures_total"
  | LifecycleDispatchRejections -> "masc_keeper_lifecycle_dispatch_rejections_total"
  | RecordingErrorDedup -> "masc_keeper_recording_error_dedup_total"
  | PausedStatePersistErrors -> "masc_keeper_paused_state_persist_errors_total"
  | Agent_coreTimeoutClassifications -> "masc_keeper_agent_core_timeout_classifications_total"
  | ProactiveOutcome -> "masc_keeper_proactive_outcome_total"
  | TaskLoadFailures -> "masc_keeper_task_load_failures_total"
  | ToolSelectionFailures -> "masc_keeper_tool_selection_failures_total"
  | ReconcileFailures -> "masc_keeper_reconcile_failures_total"
  | DecisionAuditFlushFailures -> "masc_keeper_decision_audit_flush_failures_total"
  | WorkspaceInitFailures -> "masc_keeper_workspace_init_failures_total"
  | PresenceSyncFailures -> "masc_keeper_presence_sync_failures_total"
  | CycleExceptions -> "masc_keeper_cycle_exceptions_total"
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
  | MemoryLaneCoalesced -> "masc_keeper_memory_lane_coalesced_total"
  | MemoryLanePending -> "masc_keeper_memory_lane_pending"
  | MemoryLaneInFlight -> "masc_keeper_memory_lane_in_flight"
  | MemoryLaneLatestPending -> "masc_keeper_memory_lane_latest_pending"
  | WriteMetaCycleFailures -> "masc_keeper_write_meta_cycle_failures_total"
  | MetricsSseFailures -> "masc_keeper_metrics_sse_failures_total"
  | ChatStoreFailures -> "masc_keeper_chat_store_failures_total"
  | ChatJournalAuditMismatches ->
    "masc_keeper_chat_journal_audit_mismatches_total"
  | ChatTransportFailures -> "masc_keeper_chat_transport_failures_total"
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
  | RestartAttempts -> "masc_keeper_restart_attempts_total"
  | RestartOutcomes -> "masc_keeper_restart_outcomes_total"
  | RuntimeSelected -> "masc_keeper_runtime_selected_total"
  | ToolUseFailure -> "masc_keeper_tool_use_failure_total"
  | ReceiptUnmappedDisposition -> "masc_keeper_receipt_unmapped_disposition_total"
  | ProactiveSkip -> "masc_keeper_proactive_skip_total"
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
  | MemorySearch -> "masc_keeper_memory_search_total"
  | RuntimeRequestWireBytes -> "masc_keeper_runtime_request_wire_bytes"
  | VisionAnalyze -> "masc_keeper_vision_analyze_total"
  | VisionCandidateAttempts -> "masc_keeper_vision_candidate_attempts_total"
  | VisionIngestEvictions -> "masc_keeper_vision_ingest_evictions_total"
  | VisionIngestErrors -> "masc_keeper_vision_ingest_errors_total"
  | VisionDownscale -> "masc_keeper_vision_downscale_total"
  | PromptSegmentBytes -> "masc_keeper_prompt_segment_bytes"
  | KeeperTurnInstructionHash -> "masc_keeper_turn_instruction_hash"
  | RawTraceSinkDegraded -> "masc_keeper_raw_trace_sink_degraded_total"
  | RawTraceRetentionDeleted -> "masc_keeper_raw_trace_retention_deleted_total"
  | RawTraceRetentionSkipped -> "masc_keeper_raw_trace_retention_skipped_total"
  | RawTraceRetentionUnlinkFailed ->
    "masc_keeper_raw_trace_retention_unlink_failed_total"
  | WireCaptureResponseSuppressed ->
    "masc_keeper_wire_capture_response_suppressed_total"
  | WireCaptureWriteFailures -> "masc_keeper_wire_capture_write_failures_total"
  | WireCaptureRecordSkipped -> "masc_keeper_wire_capture_record_skipped_total"
  | TurnBoundaryFailures -> "masc_keeper_turn_boundary_failures_total"
  | HistoryFragmentFailures -> "masc_keeper_history_fragment_failures_total"
  | WorkingStateNotCarried -> "masc_keeper_librarian_working_state_not_carried_total"
  | WorkspaceMemoryBriefingBytes -> "masc_keeper_workspace_memory_briefing_bytes"
  | WorkspaceMemoryLedgerClaims -> "masc_keeper_workspace_memory_ledger_claims"
  | MemoryRecallRequests -> "masc_keeper_memory_recall_requests_total"
  | MemoryRecallInputBytes -> "masc_keeper_memory_recall_input_bytes_total"
  | MemoryRecallRequestSeconds -> "masc_keeper_memory_recall_request_seconds"
  | MemoryRecallTotal -> "masc_keeper_memory_recall_total"
  | MemoryRecallSelected -> "masc_keeper_memory_recall_selected_total"
  | MemoryRecallJudgmentSeconds -> "masc_keeper_memory_recall_judgment_seconds"
  | MemoryRecallPreparationFailures -> "masc_keeper_memory_recall_preparation_failures_total"
  | MemoryChanges -> "masc_keeper_memory_changes_total"
  | MemoryFacts -> "masc_keeper_memory_facts"
  | MemorySnapshotBytes -> "masc_keeper_memory_snapshot_bytes"
  | LibrarianAbsorbSources -> "masc_keeper_librarian_absorb_sources_total"
  | LibrarianAbsorbCopyChecks -> "masc_keeper_librarian_absorb_copy_checks_total"
;;

type collection =
  | Metric_store
  | External_observable

let collection = function
  | PersistenceLaneWaits | PersistenceLanePending | PersistenceLaneInFlight ->
    External_observable
  | Turns | InputTokens | OutputTokens | CacheCreationTokens | CacheReadTokens | UsageAnomalies
  | TotalCostUsd | TurnScheduled | TurnCompleted | FailureRoute | IdleSeconds
  | InFlightElapsedSeconds | SinceLastProgressSeconds | StreamProjectionEventCutoff
  | MetricEmitDropped | TurnStarts | TurnReattempts | TurnRegressions
  | TurnLatencyBucket | TurnLatencyByModelBucket | SupervisorSweepStarts
  | SupervisorLastSweepUnixtime | OperatorClear | ToolUnderusedAllowedCount | PathRejection
  | PathResolverIdentityMismatch | KeeperMetaOverlayDrift | HeartbeatSuccesses | HeartbeatFailures
  | CleanupTrackingFailures | DispatchEventFailures | DirectiveFailures | ToolCallDuration
  | ToolCallDurationBucket | WriteMetaFailures | MetaReadFailures | ApprovalQueueFailures
  | ApprovalResolutionSignal | ProfileLoadFailures | FsFailures
  | PersistencePreparationStageDuration | PersistencePreparationExamined | PersistenceLaneDuration
  | CrashPersistenceFailures | KeepaliveSignalFailures | BoardSignalRoutedTotal
  | BoardSignalCursorDeferredTotal | BoardSignalDeliveryTotal | BoardSignalNoWakeTotal
  | BoardSignalAttentionCandidateTotal | MetaJsonFailures | ToolsAgent_coreFailures
  | TurnUpUpdateFailures | AgentToolDispatchRuntimeFailures | PromptFailures | TagDispatchFailures
  | TraceEmitFailures | TransitionAuditFailures | ExecutionReceiptFailures | SessionCleanupFailures
  | ToolExecuteFailures | LifecycleDispatchRejections | RecordingErrorDedup
  | PausedStatePersistErrors | Agent_coreTimeoutClassifications | ProactiveOutcome
  | TaskLoadFailures | ToolSelectionFailures | ReconcileFailures | DecisionAuditFlushFailures
  | WorkspaceInitFailures | PresenceSyncFailures | CycleExceptions | SnapshotWriteFailures
  | SseBroadcastFailures | WorkspaceHeartbeatFailures | TurnMetricsSnapshotFailures
  | Agent_coreExecutionErrors | MemoryOsLibrarianFailures | MemoryActivityEmitFailures
  | SupervisorSweepFailures | TomlReconcileSweepFailures | ToolUsageFlushFailures
  | TurnTimeoutCommitted | TurnErrorAfterTools | RuntimeSyncFailures | LocalDiscoveryFailures
  | ThinkingPersistFailures | CheckpointFailures | DecisionAuditRingOverflows | HitlSummaryOutcomes
  | Agent_coreEnvKeyRejections | MemoryLaneUnitFailures | MemoryLaneSubmitted | MemoryLaneRanInline
  | MemoryLaneDropped | MemoryLaneCoalesced | MemoryLanePending | MemoryLaneInFlight
  | MemoryLaneLatestPending | WriteMetaCycleFailures | MetricsSseFailures | ChatStoreFailures
  | ChatJournalAuditMismatches | ChatTransportFailures
  | KeeperMaterializationFailures | ObservationQueryFailures | Agent_coreOnStop
  | InvariantViolations | FsmEdgeTransitions | TurnFsmTransitions | TurnPhaseDuration
  | LifecycleTransitions | LifecycleCallbackFailures | EventBusDrain | SupervisorCleanupFailures
  | RegistryUpdateDropped | RegistryOrphanThresholdBreached | RegistryInvalidEntry
  | StimulusConsumed | RestartAttempts | RestartOutcomes | RuntimeSelected | ToolUseFailure
  | ReceiptUnmappedDisposition | ProactiveSkip | UsageTrust | UsageAnomalyReason
  | ConfigEnvParseFailures | PostTurnWireinFailures | TurnCleanupFailures
  | MemoryRecallHistorySwallowedExceptions | MemoryRecallReadErrors | MemoryOsRecallUnavailable
  | MemoryOsExplicitFactWrite | MemorySearch | RuntimeRequestWireBytes | VisionAnalyze
  | VisionCandidateAttempts | VisionIngestEvictions | VisionIngestErrors | VisionDownscale
  | PromptSegmentBytes | KeeperTurnInstructionHash | RawTraceSinkDegraded | RawTraceRetentionDeleted
  | RawTraceRetentionSkipped | RawTraceRetentionUnlinkFailed | WireCaptureResponseSuppressed
  | WireCaptureWriteFailures | WireCaptureRecordSkipped | TurnBoundaryFailures
  | HistoryFragmentFailures | WorkingStateNotCarried | WorkspaceMemoryBriefingBytes
  | WorkspaceMemoryLedgerClaims | MemoryRecallRequests | MemoryRecallInputBytes
  | MemoryRecallRequestSeconds | MemoryRecallTotal | MemoryRecallSelected
  | MemoryRecallJudgmentSeconds | MemoryRecallPreparationFailures | MemoryChanges | MemoryFacts
  | MemorySnapshotBytes | LibrarianAbsorbSources | LibrarianAbsorbCopyChecks -> Metric_store
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
