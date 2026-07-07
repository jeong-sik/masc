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
  | IdleSeconds
  | ContractViolations
  | MetricEmitDropped
  | ContextMaxObserved
  | TurnStarts
  | TurnReattempts
  | TurnRegressions
  | TurnLivelockBlocks
  | TurnLivelockBlocksRepeated
  | TurnLivelockBlocksThresholdPark
  | TurnLatencyBucket
  | TurnLatencyByModelBucket
  | ProviderCooldownSkip
  | ProviderCooldownRemainingSec
  | ProviderBlockDurationSec
  | TurnQueueDepth
  | SupervisorSweepStarts
  | SupervisorLastSweepUnixtime
  | DomainPoolFork
  | TurnHolderBookkeepingFailures
  | Compactions
  | CompactionRatioChange
  | CompactionSavedTokens
  | CompactionPairRepairDrops
  | EmergencyCompactRatioThreshold
  | OperatorCompact
  | OperatorClear
  | CompactionNoop
  | ToolPairRepair
  | ToolEmissionRegistrySize
  | ToolEmissionPushes
  | ToolUnderusedAllowedCount
  | ToolUnderusedAllowed
  | PathRejection
  | IdeOrphanWrites
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
  | GuardsFailures
  | ProfileLoadFailures
  | CompactAuditFailures
  | CompactAuditRetentionParse
  | CompactAuditDrainBatches
  | CompactAuditDrainBatchSizeBucket
  | FsFailures
  | CrashPersistenceFailures
  | GenerationLineageFailures
  | KeepaliveSignalFailures
  | BoardSignalWakeupCappedTotal
  | BoardSignalNoWakeTotal
  | BoardSignalAttentionCandidateTotal
  | MetaJsonFailures
  | ToolsOasFailures
  | ToolsOasDeterministicFailures
  | TurnUpUpdateFailures
  | AgentToolDispatchRuntimeFailures
  | CircuitBreakerTrips
  | PromptFailures
  | RunContextFailures
  | SearchFilesFailures
  | TagDispatchFailures
  | TraceEmitFailures
  | TransitionAuditFailures
  | ExecutionReceiptFailures
  | OperatorBroadcastSuppressed
  | LlmBridgeFailures
  | SessionCleanupFailures
  | ToolExecuteFailures
  | RolloverFailures
  | LifecycleDispatchRejections
  | RecordingErrorDedup
  | PausedStatePersistErrors
  | UnexpectedToolPartialTolerance
  | ToolCallTotal
  | ProfileConfigConflicts
  | OasTimeoutClassifications
  | NoToolProvider
  | ProactiveOutcome
  | OllamaSaturationSkip
  | TaskLoadFailures
  | ToolSelectionFailures
  | ReconcileFailures
  | DecisionAuditFlushFailures
  | OasCancel
  | ClaimAutoProvision
  | TomlInvalid
  | PersonaDriftMissing
  | WorkspaceInitFailures
  | PresenceSyncFailures
  | SelfPreservationUniversal
  | StaleStormPaused
  | ProviderTimeoutLoopPaused
  | CycleExceptions
  | SnapshotWriteFailures
  | StateSnapshotSkippedNoState
  | StateSnapshotInvalidGoal
  | PromptUnknownToolTokens
  | PromptTokenStripped
  | ProgressUpdatedLineFailures
  | SseBroadcastFailures
  | WorkspaceHeartbeatFailures
  | TurnMetricsSnapshotFailures
  | OasExecutionErrors
  | EpisodeCreateFailures
  | MemoryActivityEmitFailures
  | SupervisorSweepFailures
  | TomlReconcileSweepFailures
  | TomlReconcileDedup
  | ReconcileDisabled
  | ToolUsageFlushFailures
  | TurnTimeoutCommitted
  | TurnErrorAfterTools
  | RuntimeSyncFailures
  | LocalDiscoveryFailures
  | ThinkingPersistFailures
  | CheckpointFailures
  | DecisionAuditRingOverflows
  | ReplySkillRouteStrips
  | ReplySkillRouteLinesRemoved
  | MemoryLlmSummaryOutcomes
  | MemoryLlmSummaryChainExhausted
  | HitlSummaryOutcomes
  | UserVisibleReplySource
  | ContinuitySummarySource
  | SummarizerStateScrubs
  | SummarizerStateBlocksRemoved
  | OasEnvKeyRejections
  | ContinuityTsRecovered
  | MemoryWriteFailures
  | MemoryLaneUnitFailures
  | MemoryConsolidations
  | MemoryLaneSubmitted
  | MemoryLaneRanInline
  | MemoryLaneDropped
  | MemoryLanePending
  | MemoryLaneInFlight
  | MemoryLaneProviderSlotBusy
  | MemoryBankCompactionFailures
  | MemoryOsMaintenanceKeeperTimeout
  | WriteMetaCycleFailures
  | AlertPersistFailures
  | MetricsSseFailures
  | ChatStoreFailures
  | ChatTransportFailures
  | PersonNoteStoreFailures
  | KeeperMaterializationFailures
  | ObservationQueryFailures
  | OasOnStop
  | OasOnIdleEscalated
  | InvariantViolations
  | FsmEdgeTransitions
  | TurnFsmTransitions
  | TurnPhaseDuration
  | LifecycleTransitions
  | LifecycleCallbackFailures
  | CompactionCallbackRecoveries
  | EventBusDrain
  | SupervisorCleanupFailures
  | SpawnSlotDenied
  | RegistryUpdateDropped
  | RegistryOrphanThresholdBreached
  | RegistryInvalidEntry
  | DeadTotal
  | AutoResumedTotal
  | AutoResumeBlockedTotal
  | SkipIdleWakeResumed
  | EventQueueOverride
  | StimulusConsumed
  | UnsupportedStimulus
  | NearExhaustionTotal
  | RestartAttempts
  | RestartOutcomes
  | ConsecutiveIdle
  | LastProductiveTs
  | ProviderTimeoutStrike
  | StaleTerminationTotal
  | StaleTerminationByClass
  | ProviderTimeoutWatchdogTermination
  | StaleTerminationThresholdBreached
  | StaleTerminationBatch
  | StaleBroadcastEmitFailures
  | OasRunTimeout
  | RuntimeSaturationSignal
  | RuntimeSelected
  | RuntimeRotation
  | ToolUseFailure
  | ToolNotAllowed
  | TurnGateRejectedTerminal
  | ReceiptUnmappedDisposition
  | ExecuteNetworkUpgrade
  | ExecuteLocalExecution
  | DockerRuntimeDiscarded
  | ProactiveSkip
  | NoProgressLoopDetected
  | NoProgressStreak
  | UsageTrust
  | UsageAnomalyReason
  | ConfigEnvParseFailures
  | PostTurnWireinFailures
  | RecurringFailures
  | TurnCleanupFailures
  | MemoryBankLoadHistorySwallowedExceptions
  | MemoryRecallReadErrors
  | MemoryOsRecallUnavailable
  | RuntimeHttpProbeJsonParseFailures
  | VisionAnalyze
  | VisionCandidateAttempts
  | VisionIngestEvictions
  (* Instruction monitoring metrics *)
  | PromptSegmentBytes          (* histogram: bytes per prompt segment *)
  | PromptTemplateRenderOutcome (* counter: template render ok/fallback/empty *)
  | ToolCallParamCompleteness   (* counter: tool calls with all required params vs missing *)
  | KeeperTurnInstructionHash   (* gauge: hash of system+user prompt for change detection *)
  | KeeperToolCallRetryLoop     (* counter: consecutive identical tool calls with errors *)
  | AttemptWatchdogFired        (* counter: 1800s safety-cap watchdog killed a stuck attempt *)
  | ShellIrEffectTotal          (* counter: fine-grained Shell IR effect decomposition *)
  | ToolExecutePrActionTotal    (* counter: raw tool_execute gh PR actions *)
  | GhClassificationTotal       (* counter: gh verb/risk/typed-hit classification coverage *)
  | GatedGhLifecycleTotal       (* counter: non-blocking gated gh approval lifecycle events *)
  | GatedGhBlockTimeSeconds     (* histogram: gated gh approval path turn-block time *)
  | KeeperRepoMappingDefaultScopeAllowed (* counter: missing mapping default-scope access allowed *)
  | KeeperRepoMappingDeniedUnregistered (* counter: repository policy denied an unregistered repo id *)
  | KeeperRepoMappingLoadError          (* counter: keeper repo mapping load/parse failure *)
  | KeeperRepoMappingRepositoryIdentityMismatch (* counter: repo identity mismatch in policy projection *)
  | KeeperRepoMappingRepositoryStoreError       (* counter: repo catalog load failure in policy projection *)
  | RawTraceSinkDegraded        (* counter: raw-trace sink create failed; turn dispatched untraced *)
  | WireCaptureResponseSuppressed (* counter: keeper-visible response suppressed before wire capture *)
  | WireCaptureWriteFailures    (* counter: wire-capture write raised an exception *)
  | WireCaptureRecordSkipped    (* counter: wire-capture record dropped by current-file byte cap *)

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
  | IdleSeconds -> "masc_keeper_idle_seconds"
  | ContractViolations -> "masc_keeper_contract_violations_total"
  | MetricEmitDropped -> "masc_keeper_metric_emit_dropped_total"
  | ContextMaxObserved -> "masc_keeper_context_max_observed_total"
  | TurnStarts -> "masc_keeper_turn_starts_total"
  | TurnReattempts -> "masc_keeper_turn_reattempts_total"
  | TurnRegressions -> "masc_keeper_turn_regressions_total"
  | TurnLivelockBlocks -> "masc_keeper_turn_livelock_blocks_total"
  | TurnLivelockBlocksRepeated -> "masc_keeper_turn_livelock_blocks_repeated_total"
  | TurnLivelockBlocksThresholdPark ->
    "masc_keeper_turn_livelock_blocks_threshold_park_total"
  | TurnLatencyBucket -> "masc_keeper_turn_latency_bucket_total"
  | TurnLatencyByModelBucket -> "masc_keeper_turn_latency_by_model_bucket_total"
  | ProviderCooldownSkip -> "masc_keeper_provider_cooldown_skip_total"
  | ProviderCooldownRemainingSec -> "masc_keeper_provider_cooldown_remaining_sec"
  | ProviderBlockDurationSec -> "masc_keeper_provider_block_duration_sec"
  | TurnQueueDepth -> "masc_keeper_turn_queue_depth"
  | SupervisorSweepStarts -> "masc_keeper_supervisor_sweep_starts_total"
  | SupervisorLastSweepUnixtime -> "masc_keeper_supervisor_last_sweep_unixtime"
  | DomainPoolFork -> "masc_keeper_domain_pool_fork_total"
  | TurnHolderBookkeepingFailures -> "masc_keeper_turn_holders_bookkeeping_failures_total"
  | Compactions -> "masc_keeper_compactions_total"
  | CompactionRatioChange -> "masc_keeper_compaction_ratio_change"
  | CompactionSavedTokens -> "masc_keeper_compaction_saved_tokens_total"
  | CompactionPairRepairDrops ->
    "masc_keeper_compaction_pair_repair_drops_total"
  | EmergencyCompactRatioThreshold ->
    "masc_keeper_emergency_compact_ratio_threshold"
  | OperatorCompact -> "masc_keeper_operator_compact_total"
  | OperatorClear -> "masc_keeper_operator_clear_total"
  | CompactionNoop -> "masc_keeper_compaction_noop_total"
  | ToolPairRepair -> "masc_keeper_tool_pair_repair_total"
  | ToolEmissionRegistrySize -> "masc_keeper_tool_emission_registry_size"
  | ToolEmissionPushes -> "masc_keeper_tool_emission_pushes_total"
  | ToolUnderusedAllowedCount -> "masc_keeper_tool_underused_allowed_count"
  | ToolUnderusedAllowed -> "masc_keeper_tool_underused_allowed"
  | PathRejection -> "masc_keeper_path_rejection_total"
  | IdeOrphanWrites -> "masc_ide_orphan_writes_total"
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
  | GuardsFailures -> "masc_keeper_guards_failures_total"
  | ProfileLoadFailures -> "masc_keeper_profile_load_failures_total"
  | CompactAuditFailures -> "masc_keeper_compact_audit_failures_total"
  | CompactAuditRetentionParse -> "masc_keeper_compact_audit_retention_parse_total"
  | CompactAuditDrainBatches -> "masc_keeper_compact_audit_drain_batches_total"
  | CompactAuditDrainBatchSizeBucket ->
    "masc_keeper_compact_audit_drain_batch_size_bucket_total"
  | FsFailures -> "masc_keeper_fs_failures_total"
  | CrashPersistenceFailures -> "masc_keeper_crash_persistence_failures_total"
  | GenerationLineageFailures -> "masc_keeper_generation_lineage_failures_total"
  | KeepaliveSignalFailures -> "masc_keeper_keepalive_signal_failures_total"
  | BoardSignalWakeupCappedTotal -> "masc_keeper_board_signal_wakeup_capped_total"
  | BoardSignalNoWakeTotal -> "masc_keeper_board_signal_no_wake_total"
  | BoardSignalAttentionCandidateTotal ->
    "masc_keeper_board_signal_attention_candidate_total"
  | MetaJsonFailures -> "masc_keeper_meta_json_failures_total"
  | ToolsOasFailures -> "masc_keeper_tools_oas_failures_total"
  | ToolsOasDeterministicFailures ->
    "masc_keeper_tools_oas_deterministic_failures_total"
  | TurnUpUpdateFailures -> "masc_keeper_turn_up_update_failures_total"
  | AgentToolDispatchRuntimeFailures -> "masc_keeper_tool_dispatch_runtime_failures_total"
  | CircuitBreakerTrips -> "masc_keeper_circuit_breaker_trips_total"
  | PromptFailures -> "masc_keeper_prompt_failures_total"
  | RunContextFailures -> "masc_keeper_run_context_failures_total"
  | SearchFilesFailures -> "masc_keeper_search_files_failures_total"
  | TagDispatchFailures -> "masc_keeper_tag_dispatch_failures_total"
  | TraceEmitFailures -> "masc_keeper_trace_emit_failures_total"
  | TransitionAuditFailures -> "masc_keeper_transition_audit_failures_total"
  | ExecutionReceiptFailures -> "masc_keeper_execution_receipt_failures_total"
  | OperatorBroadcastSuppressed -> "masc_keeper_operator_broadcast_suppressed_total"
  | LlmBridgeFailures -> "masc_keeper_llm_bridge_failures_total"
  | SessionCleanupFailures -> "masc_keeper_session_cleanup_failures_total"
  | ToolExecuteFailures -> "masc_keeper_tool_execute_runtime_failures_total"
  | RolloverFailures -> "masc_keeper_rollover_failures_total"
  | LifecycleDispatchRejections -> "masc_keeper_lifecycle_dispatch_rejections_total"
  | RecordingErrorDedup -> "masc_keeper_recording_error_dedup_total"
  | PausedStatePersistErrors -> "masc_keeper_paused_state_persist_errors_total"
  | UnexpectedToolPartialTolerance ->
    "masc_keeper_unexpected_tool_partial_tolerance_total"
  | ToolCallTotal -> "masc_keeper_tool_call_total"
  | ProfileConfigConflicts -> "masc_keeper_profile_config_conflicts_total"
  | OasTimeoutClassifications -> "masc_keeper_oas_timeout_classifications_total"
  | NoToolProvider -> "masc_keeper_no_tool_provider_total"
  | ProactiveOutcome -> "masc_keeper_proactive_outcome_total"
  | OllamaSaturationSkip -> "masc_keeper_ollama_saturation_skip_total"
  | TaskLoadFailures -> "masc_keeper_task_load_failures_total"
  | ToolSelectionFailures -> "masc_keeper_tool_selection_failures_total"
  | ReconcileFailures -> "masc_keeper_reconcile_failures_total"
  | DecisionAuditFlushFailures -> "masc_keeper_decision_audit_flush_failures_total"
  | OasCancel -> "masc_keeper_oas_cancel_total"
  | ClaimAutoProvision -> "masc_keeper_claim_auto_provision_total"
  | TomlInvalid -> "masc_keeper_toml_invalid_total"
  | PersonaDriftMissing -> "masc_keeper_persona_drift_missing_total"
  | WorkspaceInitFailures -> "masc_keeper_workspace_init_failures_total"
  | PresenceSyncFailures -> "masc_keeper_presence_sync_failures_total"
  | SelfPreservationUniversal -> "masc_keeper_self_preservation_universal_total"
  | StaleStormPaused -> "masc_keeper_stale_storm_paused_total"
  | ProviderTimeoutLoopPaused -> "masc_keeper_provider_timeout_loop_paused_total"
  | CycleExceptions -> "masc_keeper_cycle_exceptions_total"
  | SnapshotWriteFailures -> "masc_keeper_snapshot_write_failures_total"
  | StateSnapshotSkippedNoState ->
    "masc_keeper_state_snapshot_skipped_no_state_total"
  | StateSnapshotInvalidGoal ->
    "masc_keeper_state_snapshot_invalid_goal_total"
  | PromptUnknownToolTokens ->
    "masc_keeper_prompt_unknown_tool_tokens_total"
  | PromptTokenStripped ->
    "masc_keeper_prompt_token_stripped_total"
  | ProgressUpdatedLineFailures -> "masc_keeper_progress_updated_line_failures_total"
  | SseBroadcastFailures -> "masc_keeper_sse_broadcast_failures_total"
  | WorkspaceHeartbeatFailures -> "masc_keeper_workspace_heartbeat_failures_total"
  | TurnMetricsSnapshotFailures -> "masc_keeper_turn_metrics_snapshot_failures_total"
  | OasExecutionErrors -> "masc_keeper_oas_execution_errors_total"
  | EpisodeCreateFailures -> "masc_keeper_episode_create_failures_total"
  | MemoryActivityEmitFailures -> "masc_keeper_memory_activity_emit_failures_total"
  | SupervisorSweepFailures -> "masc_keeper_supervisor_sweep_failures_total"
  | TomlReconcileSweepFailures -> "masc_keeper_toml_reconcile_sweep_failures_total"
  | TomlReconcileDedup -> "masc_keeper_toml_reconcile_dedup_total"
  | ReconcileDisabled -> "masc_keeper_reconcile_disabled_total"
  | ToolUsageFlushFailures -> "masc_keeper_tool_usage_flush_failures_total"
  | TurnTimeoutCommitted -> "masc_keeper_turn_timeout_committed_total"
  | TurnErrorAfterTools -> "masc_keeper_turn_error_after_tools_total"
  | RuntimeSyncFailures -> "masc_keeper_runtime_sync_failures_total"
  | LocalDiscoveryFailures -> "masc_keeper_local_discovery_failures_total"
  | ThinkingPersistFailures -> "masc_keeper_thinking_persist_failures_total"
  | CheckpointFailures -> "masc_keeper_checkpoint_failures_total"
  | DecisionAuditRingOverflows -> "masc_keeper_decision_audit_ring_overflows_total"
  | ReplySkillRouteStrips -> "masc_keeper_reply_skill_route_strips_total"
  | ReplySkillRouteLinesRemoved ->
    "masc_keeper_reply_skill_route_lines_removed_total"
  | MemoryLlmSummaryOutcomes -> "masc_keeper_memory_llm_summary_outcomes_total"
  | MemoryLlmSummaryChainExhausted ->
    "masc_keeper_memory_llm_summary_chain_exhausted_total"
  | HitlSummaryOutcomes -> "masc_keeper_hitl_summary_outcomes_total"
  | UserVisibleReplySource -> "masc_keeper_user_visible_reply_source_total"
  | ContinuitySummarySource -> "masc_keeper_continuity_summary_source_total"
  | SummarizerStateScrubs -> "masc_keeper_summarizer_state_scrubs_total"
  | SummarizerStateBlocksRemoved ->
    "masc_keeper_summarizer_state_blocks_removed_total"
  | OasEnvKeyRejections -> "masc_keeper_oas_env_key_rejections_total"
  | ContinuityTsRecovered -> "masc_keeper_continuity_ts_recovered_total"
  | MemoryWriteFailures -> "masc_keeper_memory_write_failures_total"
  | MemoryLaneUnitFailures -> "masc_keeper_memory_lane_unit_failures_total"
  | MemoryConsolidations -> "masc_keeper_memory_consolidations_total"
  | MemoryLaneSubmitted -> "masc_keeper_memory_lane_submitted_total"
  | MemoryLaneRanInline -> "masc_keeper_memory_lane_ran_inline_total"
  | MemoryLaneDropped -> "masc_keeper_memory_lane_dropped_total"
  | MemoryLanePending -> "masc_keeper_memory_lane_pending"
  | MemoryLaneInFlight -> "masc_keeper_memory_lane_in_flight"
  | MemoryLaneProviderSlotBusy -> "masc_keeper_memory_lane_provider_slot_busy_total"
  | MemoryBankCompactionFailures -> "masc_keeper_memory_bank_compaction_failures_total"
  | MemoryOsMaintenanceKeeperTimeout -> "masc_keeper_memory_os_maintenance_keeper_timeout_total"
  | WriteMetaCycleFailures -> "masc_keeper_write_meta_cycle_failures_total"
  | AlertPersistFailures -> "masc_keeper_alert_persist_failures_total"
  | MetricsSseFailures -> "masc_keeper_metrics_sse_failures_total"
  | ChatStoreFailures -> "masc_keeper_chat_store_failures_total"
  | ChatTransportFailures -> "masc_keeper_chat_transport_failures_total"
  | PersonNoteStoreFailures -> "masc_keeper_person_note_store_failures_total"
  | KeeperMaterializationFailures -> "masc_keeper_materialization_failures_total"
  | ObservationQueryFailures -> "masc_keeper_observation_query_failures_total"
  | OasOnStop -> "masc_keeper_oas_on_stop_total"
  | OasOnIdleEscalated -> "masc_keeper_oas_on_idle_escalated_total"
  | InvariantViolations -> "masc_keeper_invariant_violations_total"
  | FsmEdgeTransitions -> "masc_keeper_fsm_edge_transitions_total"
  | TurnFsmTransitions -> "masc_keeper_turn_fsm_transitions_total"
  | TurnPhaseDuration -> "masc_keeper_turn_phase_duration_seconds"
  | LifecycleTransitions -> "masc_keeper_lifecycle_transitions_total"
  | LifecycleCallbackFailures -> "masc_keeper_lifecycle_callback_failures_total"
  | CompactionCallbackRecoveries ->
    "masc_keeper_compaction_callback_recoveries_total"
  | EventBusDrain -> "masc_keeper_event_bus_drain_total"
  | SupervisorCleanupFailures -> "masc_keeper_supervisor_cleanup_failures_total"
  | SpawnSlotDenied -> "masc_keeper_spawn_slot_denied_total"
  | RegistryUpdateDropped -> "masc_keeper_registry_update_dropped_total"
  | RegistryOrphanThresholdBreached ->
    "masc_keeper_registry_orphan_threshold_breached_total"
  | RegistryInvalidEntry -> "masc_keeper_registry_invalid_entry_total"
  | DeadTotal -> "masc_keeper_dead_total"
  | AutoResumedTotal -> "masc_keeper_auto_resumed_total"
  | AutoResumeBlockedTotal -> "masc_keeper_auto_resume_blocked_total"
  | SkipIdleWakeResumed -> "masc_keeper_skip_idle_wake_resumed_total"
  | EventQueueOverride -> "masc_keeper_event_queue_override_total"
  | StimulusConsumed -> "masc_keeper_stimulus_consumed_total"
  | UnsupportedStimulus -> "masc_keeper_unsupported_stimulus_total"
  | NearExhaustionTotal -> "masc_keeper_near_exhaustion_total"
  | RestartAttempts -> "masc_keeper_restart_attempts_total"
  | RestartOutcomes -> "masc_keeper_restart_outcomes_total"
  | ConsecutiveIdle -> "masc_keeper_consecutive_idle"
  | LastProductiveTs -> "masc_keeper_last_productive_ts"
  | ProviderTimeoutStrike -> "masc_keeper_provider_timeout_strike_total"
  | StaleTerminationTotal -> "masc_keeper_stale_termination_total"
  | StaleTerminationByClass -> "masc_keeper_stale_termination_by_class_total"
  | ProviderTimeoutWatchdogTermination ->
    "masc_keeper_provider_timeout_watchdog_termination_total"
  | StaleTerminationThresholdBreached ->
    "masc_keeper_stale_termination_threshold_breached_total"
  | StaleTerminationBatch -> "masc_keeper_stale_termination_batch_total"
  | StaleBroadcastEmitFailures -> "masc_keeper_stale_broadcast_emit_failures"
  | OasRunTimeout -> "masc_keeper_oas_run_timeout_total"
  | RuntimeSaturationSignal -> "masc_keeper_runtime_saturation_signal_total"
  | RuntimeSelected -> "masc_keeper_runtime_selected_total"
  | RuntimeRotation -> "masc_keeper_runtime_rotation_total"
  | ToolUseFailure -> "masc_keeper_tool_use_failure_total"
  | ToolNotAllowed -> "masc_keeper_tool_not_allowed_total"
  | TurnGateRejectedTerminal -> "masc_keeper_turn_gate_rejected_terminal_total"
  | ReceiptUnmappedDisposition -> "masc_keeper_receipt_unmapped_disposition_total"
  | ExecuteNetworkUpgrade -> "masc_keeper_execute_network_upgrade_total"
  | ExecuteLocalExecution -> "masc_keeper_execute_local_execution_total"
  | DockerRuntimeDiscarded -> "masc_keeper_docker_runtime_discarded_total"
  | ProactiveSkip -> "masc_keeper_proactive_skip_total"
  | NoProgressLoopDetected -> "masc_keeper_no_progress_loop_detected_total"
  | NoProgressStreak -> "masc_keeper_no_progress_streak"
  | UsageTrust -> "masc_keeper_usage_trust_total"
  | UsageAnomalyReason -> "masc_keeper_usage_anomaly_reason_total"
  | ConfigEnvParseFailures -> "masc_keeper_config_env_parse_failures_total"
  | PostTurnWireinFailures -> "masc_keeper_post_turn_wirein_failures_total"
  | RecurringFailures -> "masc_keeper_recurring_failures_total"
  | TurnCleanupFailures -> "masc_keeper_turn_cleanup_failures_total"
  | MemoryBankLoadHistorySwallowedExceptions ->
      "masc_keeper_memory_bank_load_history_swallowed_exceptions_total"
  | MemoryRecallReadErrors ->
      "masc_keeper_memory_recall_read_errors_total"
  | MemoryOsRecallUnavailable ->
      "masc_keeper_memory_os_recall_unavailable_total"
  | RuntimeHttpProbeJsonParseFailures ->
      "masc_runtime_http_probe_json_parse_failures_total"
  | VisionAnalyze -> "masc_keeper_vision_analyze_total"
  | VisionCandidateAttempts -> "masc_keeper_vision_candidate_attempts_total"
  | VisionIngestEvictions -> "masc_keeper_vision_ingest_evictions_total"
  | PromptSegmentBytes -> "masc_keeper_prompt_segment_bytes"
  | PromptTemplateRenderOutcome -> "masc_keeper_prompt_template_render_outcome_total"
  | ToolCallParamCompleteness -> "masc_keeper_tool_call_param_completeness_total"
  | KeeperTurnInstructionHash -> "masc_keeper_turn_instruction_hash"
  | KeeperToolCallRetryLoop -> "masc_keeper_tool_call_retry_loop_total"
  | AttemptWatchdogFired -> "masc_keeper_attempt_watchdog_fired_total"
  | ShellIrEffectTotal -> "masc_keeper_shell_ir_effect_total"
  | ToolExecutePrActionTotal -> "masc_keeper_tool_execute_pr_action_total"
  | GhClassificationTotal -> "masc_keeper_gh_classification_total"
  | GatedGhLifecycleTotal -> "masc_keeper_gated_gh_lifecycle_total"
  | GatedGhBlockTimeSeconds -> "masc_keeper_gated_gh_block_time_seconds"
  | KeeperRepoMappingDefaultScopeAllowed ->
    "masc_keeper_repo_mapping_default_scope_allowed_total"
  | KeeperRepoMappingDeniedUnregistered ->
    "masc_keeper_repo_mapping_denied_unregistered_total"
  | KeeperRepoMappingLoadError -> "masc_keeper_repo_mapping_load_error_total"
  | KeeperRepoMappingRepositoryIdentityMismatch ->
    "masc_keeper_repo_mapping_repository_identity_mismatch_total"
  | KeeperRepoMappingRepositoryStoreError ->
    "masc_keeper_repo_mapping_repository_store_error_total"
  | RawTraceSinkDegraded -> "masc_keeper_raw_trace_sink_degraded_total"
  | WireCaptureResponseSuppressed ->
    "masc_keeper_wire_capture_response_suppressed_total"
  | WireCaptureWriteFailures -> "masc_keeper_wire_capture_write_failures_total"
  | WireCaptureRecordSkipped -> "masc_keeper_wire_capture_record_skipped_total"
;;

(* Every constructor of [t], in declaration order.  Consumed by
   [register_zero_fill] below.  The compiler cannot enforce membership
   here (no enumerate ppx in this repo): when you add a constructor,
   exhaustiveness already forces you to edit [to_string] in this file --
   add the constructor to [all] in the same edit. *)
let all : t list =
  [ Turns; InputTokens; OutputTokens; CacheCreationTokens;
    CacheReadTokens; UsageAnomalies; TotalCostUsd; TurnScheduled;
    TurnCompleted; IdleSeconds; ContractViolations; MetricEmitDropped;
    ContextMaxObserved; TurnStarts; TurnReattempts; TurnRegressions;
    TurnLivelockBlocks; TurnLivelockBlocksRepeated; TurnLivelockBlocksThresholdPark; TurnLatencyBucket;
    TurnLatencyByModelBucket; ProviderCooldownSkip; ProviderCooldownRemainingSec; ProviderBlockDurationSec;
    TurnQueueDepth; SupervisorSweepStarts; SupervisorLastSweepUnixtime; DomainPoolFork;
    TurnHolderBookkeepingFailures; Compactions; CompactionRatioChange; CompactionSavedTokens;
    CompactionPairRepairDrops; EmergencyCompactRatioThreshold; OperatorCompact; OperatorClear;
    CompactionNoop; ToolPairRepair; ToolEmissionRegistrySize; ToolEmissionPushes;
    ToolUnderusedAllowedCount; ToolUnderusedAllowed; PathRejection; IdeOrphanWrites;
    PathResolverIdentityMismatch; KeeperMetaOverlayDrift; HeartbeatSuccesses; HeartbeatFailures; CleanupTrackingFailures;
    DispatchEventFailures; DirectiveFailures; ToolCallDuration; ToolCallDurationBucket; WriteMetaFailures;
    MetaReadFailures; ApprovalQueueFailures; GuardsFailures; ProfileLoadFailures;
    CompactAuditFailures; CompactAuditRetentionParse; CompactAuditDrainBatches; CompactAuditDrainBatchSizeBucket;
    FsFailures; CrashPersistenceFailures; GenerationLineageFailures; KeepaliveSignalFailures;
    BoardSignalWakeupCappedTotal; BoardSignalNoWakeTotal; MetaJsonFailures; ToolsOasFailures;
    ToolsOasDeterministicFailures; TurnUpUpdateFailures; AgentToolDispatchRuntimeFailures; CircuitBreakerTrips;
    PromptFailures; RunContextFailures; SearchFilesFailures; TagDispatchFailures;
    TraceEmitFailures; TransitionAuditFailures; ExecutionReceiptFailures; OperatorBroadcastSuppressed;
    LlmBridgeFailures; SessionCleanupFailures; ToolExecuteFailures; RolloverFailures;
    LifecycleDispatchRejections; RecordingErrorDedup; PausedStatePersistErrors; UnexpectedToolPartialTolerance;
    ToolCallTotal; ProfileConfigConflicts; OasTimeoutClassifications; NoToolProvider;
    ProactiveOutcome; OllamaSaturationSkip; TaskLoadFailures; ToolSelectionFailures;
    ReconcileFailures; DecisionAuditFlushFailures; OasCancel;
    ClaimAutoProvision; TomlInvalid; PersonaDriftMissing; WorkspaceInitFailures;
    PresenceSyncFailures; SelfPreservationUniversal; StaleStormPaused; ProviderTimeoutLoopPaused;
    CycleExceptions; SnapshotWriteFailures; StateSnapshotSkippedNoState; StateSnapshotInvalidGoal; PromptUnknownToolTokens;
    PromptTokenStripped;
    ProgressUpdatedLineFailures;
    SseBroadcastFailures; WorkspaceHeartbeatFailures; TurnMetricsSnapshotFailures; OasExecutionErrors;
    EpisodeCreateFailures; MemoryActivityEmitFailures; SupervisorSweepFailures; TomlReconcileSweepFailures;
    TomlReconcileDedup; ReconcileDisabled; ToolUsageFlushFailures; TurnTimeoutCommitted;
    TurnErrorAfterTools; RuntimeSyncFailures; LocalDiscoveryFailures; ThinkingPersistFailures;
    CheckpointFailures; DecisionAuditRingOverflows; ReplySkillRouteStrips; ReplySkillRouteLinesRemoved;
    MemoryLlmSummaryOutcomes; MemoryLlmSummaryChainExhausted; HitlSummaryOutcomes; UserVisibleReplySource; ContinuitySummarySource;
    SummarizerStateScrubs; SummarizerStateBlocksRemoved; OasEnvKeyRejections; ContinuityTsRecovered;
    MemoryWriteFailures; MemoryLaneUnitFailures; MemoryConsolidations; MemoryLaneSubmitted; MemoryLaneRanInline; MemoryLaneDropped;
    MemoryLanePending; MemoryLaneInFlight; MemoryLaneProviderSlotBusy; MemoryBankCompactionFailures; MemoryOsMaintenanceKeeperTimeout; WriteMetaCycleFailures; AlertPersistFailures;
    MetricsSseFailures; ChatStoreFailures; ChatTransportFailures; PersonNoteStoreFailures; KeeperMaterializationFailures; ObservationQueryFailures; OasOnStop;
    OasOnIdleEscalated; InvariantViolations; FsmEdgeTransitions; TurnFsmTransitions;
    TurnPhaseDuration; LifecycleTransitions; LifecycleCallbackFailures; CompactionCallbackRecoveries;
    EventBusDrain; SupervisorCleanupFailures; SpawnSlotDenied; RegistryUpdateDropped;
    RegistryOrphanThresholdBreached; RegistryInvalidEntry; DeadTotal; AutoResumedTotal; AutoResumeBlockedTotal;
    SkipIdleWakeResumed; EventQueueOverride; StimulusConsumed; UnsupportedStimulus;
    NearExhaustionTotal; RestartAttempts; RestartOutcomes; ConsecutiveIdle;
    LastProductiveTs; ProviderTimeoutStrike; StaleTerminationTotal; StaleTerminationByClass;
    ProviderTimeoutWatchdogTermination; StaleTerminationThresholdBreached; StaleTerminationBatch; StaleBroadcastEmitFailures;
    OasRunTimeout; RuntimeSaturationSignal; RuntimeSelected; RuntimeRotation; ToolUseFailure; ToolNotAllowed;
    TurnGateRejectedTerminal; ReceiptUnmappedDisposition; ExecuteNetworkUpgrade; ExecuteLocalExecution;
    DockerRuntimeDiscarded; ProactiveSkip; NoProgressLoopDetected; NoProgressStreak; UsageTrust;
    UsageAnomalyReason; ConfigEnvParseFailures; PostTurnWireinFailures; RecurringFailures;
    TurnCleanupFailures; MemoryBankLoadHistorySwallowedExceptions; MemoryRecallReadErrors; MemoryOsRecallUnavailable; RuntimeHttpProbeJsonParseFailures;
    VisionAnalyze; VisionCandidateAttempts; VisionIngestEvictions; PromptSegmentBytes; PromptTemplateRenderOutcome; ToolCallParamCompleteness; KeeperTurnInstructionHash;
    KeeperToolCallRetryLoop; AttemptWatchdogFired; ShellIrEffectTotal; ToolExecutePrActionTotal;
    GhClassificationTotal; GatedGhLifecycleTotal; GatedGhBlockTimeSeconds;
  KeeperRepoMappingDefaultScopeAllowed; KeeperRepoMappingDeniedUnregistered;
  KeeperRepoMappingLoadError;
  KeeperRepoMappingRepositoryIdentityMismatch; KeeperRepoMappingRepositoryStoreError;
  RawTraceSinkDegraded; WireCaptureResponseSuppressed; WireCaptureWriteFailures;
  WireCaptureRecordSkipped
  ]
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
      if String.ends_with ~suffix:"_total" name then
        Otel_metric_store_core.register_counter ~name ~help:name ())
    all;
  Otel_metric_store_core.register_gauge
    ~name:(to_string SupervisorLastSweepUnixtime)
    ~help:"Unix timestamp of the last keeper supervisor sweep beat"
    ()
;;
