(** Keeper domain metrics.

    Each keeper metric is owned by this module; Prometheus.ml only provides
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
  | AliveButStuck
  | AliveButStuckSeconds
  | AliveButStuckThresholdSeconds
  | AliveButStuckRecoveryRequests
  | AliveButStuckRecovery
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
  | SemaphoreWaitTimeout
  | TurnSlotBookkeepingFailures
  | SemaphoreWaitSeconds
  | SemaphoreWaitSecondsBucket
  | SlotYieldTotal
  | Compactions
  | CompactionRatioChange
  | CompactionSavedTokens
  | CompactionPairRepairFabrications
  | EmergencyCompactRatioThreshold
  | OperatorCompact
  | OperatorClear
  | CompactionNoop
  | ContinuityNoState
  | ToolPairRepair
  | ToolEmissionRegistrySize
  | ToolEmissionPushes
  | ToolUnderusedAllowedCount
  | ToolUnderusedAllowed
  | PathRejection
  | IdeOrphanWrites
  | PathResolverIdentityMismatch
  | HeartbeatSuccesses
  | HeartbeatFailures
  | CleanupTrackingFailures
  | DispatchEventFailures
  | DirectiveFailures
  | ToolCallDuration
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
  | MetaJsonFailures
  | ToolsOasFailures
  | ToolsOasDeterministicFailures
  | OasHookOutputParseFailures
  | TurnUpUpdateFailures
  | AgentToolDispatchRuntimeFailures
  | CircuitBreakerTrips
  | PromptFailures
  | RunContextFailures
  | WorkspaceInspectFailures
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
  | RequireToolUseViolations
  | ToolCallTotal
  | ProfileConfigConflicts
  | OasTimeoutClassifications
  | NoToolProvider
  | ProactiveOutcome
  | OllamaSaturationSkip
  | TaskLoadFailures
  | ToolSelectionFailures
  | ToolPolicyFailures
  | ReconcileFailures
  | DecisionAuditFlushFailures
  | OasCancel
  | ClaimAutoProvision
  | TomlInvalid
  | PersonaDriftMissing
  | RoomInitFailures
  | PresenceSyncFailures
  | SelfPreservationUniversal
  | StaleStormPaused
  | ProviderTimeoutLoopPaused
  | CycleExceptions
  | SnapshotWriteFailures
  | StateSnapshotSkippedNoState
  | ProgressUpdatedLineFailures
  | SseBroadcastFailures
  | RoomHeartbeatFailures
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
  | CascadeSyncFailures
  | LocalDiscoveryFailures
  | ThinkingPersistFailures
  | CheckpointFailures
  | DecisionAuditRingOverflows
  | ReplySkillRouteStrips
  | ReplySkillRouteLinesRemoved
  | MemoryLlmSummaryOutcomes
  | MemoryLlmSummaryChainExhausted
  | MemoryJsonlOps
  | UserVisibleReplySource
  | ContinuitySummarySource
  | SummarizerStateScrubs
  | SummarizerStateBlocksRemoved
  | OasEnvKeyRejections
  | ContinuityTsRecovered
  | MemoryWriteFailures
  | MemoryConsolidations
  | WriteMetaCycleFailures
  | AlertPersistFailures
  | MetricsSseFailures
  | ChatStoreFailures
  | ObservationQueryFailures
  | OasOnStop
  | OasOnIdleEscalated
  | QuantitativeClaimRejections
  | InvariantViolations
  | FsmEdgeTransitions
  | TurnFsmTransitions
  | TurnPhaseDuration
  | LifecycleTransitions
  | LifecycleCallbackFailures
  | BriefingSessionLastEventSource
  | EventBusDrain
  | SupervisorCleanupFailures
  | SlotForceReleased
  | SpawnSlotDenied
  | RegistryUpdateDropped
  | RegistryOrphanThresholdBreached
  | StaleWatchdogTickFailures
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
  | LivenessRecoveryAttempts
  | LivenessRecoveryOutcomes
  | PassiveLoopDetectedTotal
  | PassiveLoopStreak
  | PassiveLoopStreakExceeded
  | RequiredToolLoopDetectedTotal
  | ZombieLoopDetectedTotal
  | RequiredToolGateSuppressedTotal
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
  | CascadeSaturationSignal
  | ToolUseFailure
  | ToolNotAllowed
  | TurnGateRejectedTerminal
  | ReceiptUnmappedDisposition
  | ExecuteNetworkUpgrade
  | ExecuteLocalExecution
  | DockerRuntimeDiscarded
  | ProactiveSkip
  | StaySilentLoopDetected
  | UsageTrust
  | UsageAnomalyReason
  | ConfigEnvParseFailures
  | PostTurnWireinFailures
  | RecurringFailures
  | TurnCleanupFailures
  | MemoryBankLoadHistorySwallowedExceptions
  | MemoryRecallReadErrors
  | CascadeHttpProbeJsonParseFailures

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
  | AliveButStuck -> "masc_keeper_alive_but_stuck_total"
  | AliveButStuckSeconds -> "masc_keeper_alive_but_stuck_seconds"
  | AliveButStuckThresholdSeconds -> "masc_keeper_alive_but_stuck_threshold_seconds"
  | AliveButStuckRecoveryRequests -> "masc_keeper_alive_but_stuck_recovery_requests_total"
  | AliveButStuckRecovery -> "masc_keeper_alive_but_stuck_recovery_total"
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
  | SemaphoreWaitTimeout -> "masc_keeper_semaphore_wait_timeout_total"
  | TurnSlotBookkeepingFailures -> "masc_keeper_turn_slot_bookkeeping_failures_total"
  | SemaphoreWaitSeconds -> "masc_keeper_semaphore_wait_seconds"
  | SemaphoreWaitSecondsBucket -> "masc_keeper_semaphore_wait_seconds_bucket"
  | SlotYieldTotal -> "masc_keeper_slot_yield_total"
  | Compactions -> "masc_keeper_compactions_total"
  | CompactionRatioChange -> "masc_keeper_compaction_ratio_change"
  | CompactionSavedTokens -> "masc_keeper_compaction_saved_tokens_total"
  | CompactionPairRepairFabrications ->
    "masc_keeper_compaction_pair_repair_fabrications_total"
  | EmergencyCompactRatioThreshold ->
    "masc_keeper_emergency_compact_ratio_threshold"
  | OperatorCompact -> "masc_keeper_operator_compact_total"
  | OperatorClear -> "masc_keeper_operator_clear_total"
  | CompactionNoop -> "masc_keeper_compaction_noop_total"
  | ContinuityNoState -> "masc_keeper_continuity_no_state_total"
  | ToolPairRepair -> "masc_keeper_tool_pair_repair_total"
  | ToolEmissionRegistrySize -> "masc_keeper_tool_emission_registry_size"
  | ToolEmissionPushes -> "masc_keeper_tool_emission_pushes_total"
  | ToolUnderusedAllowedCount -> "masc_keeper_tool_underused_allowed_count"
  | ToolUnderusedAllowed -> "masc_keeper_tool_underused_allowed"
  | PathRejection -> "masc_keeper_path_rejection_total"
  | IdeOrphanWrites -> "masc_ide_orphan_writes_total"
  | PathResolverIdentityMismatch -> "masc_keeper_path_resolver_identity_mismatch_total"
  | HeartbeatSuccesses -> "masc_keeper_heartbeat_successes_total"
  | HeartbeatFailures -> "masc_keeper_heartbeat_failures_total"
  | CleanupTrackingFailures -> "masc_keeper_cleanup_tracking_failures_total"
  | DispatchEventFailures -> "masc_keeper_dispatch_event_failures_total"
  | DirectiveFailures -> "masc_keeper_directive_failures_total"
  | ToolCallDuration -> "masc_keeper_tool_call_duration_seconds"
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
  | MetaJsonFailures -> "masc_keeper_meta_json_failures_total"
  | ToolsOasFailures -> "masc_keeper_tools_oas_failures_total"
  | ToolsOasDeterministicFailures ->
    "masc_keeper_tools_oas_deterministic_failures_total"
  | OasHookOutputParseFailures -> "masc_keeper_oas_hook_output_parse_failures_total"
  | TurnUpUpdateFailures -> "masc_keeper_turn_up_update_failures_total"
  | AgentToolDispatchRuntimeFailures -> "masc_agent_tool_dispatch_runtime_failures_total"
  | CircuitBreakerTrips -> "masc_keeper_circuit_breaker_trips_total"
  | PromptFailures -> "masc_keeper_prompt_failures_total"
  | RunContextFailures -> "masc_keeper_run_context_failures_total"
  | WorkspaceInspectFailures -> "masc_keeper_workspace_inspect_failures_total"
  | TagDispatchFailures -> "masc_keeper_tag_dispatch_failures_total"
  | TraceEmitFailures -> "masc_keeper_trace_emit_failures_total"
  | TransitionAuditFailures -> "masc_keeper_transition_audit_failures_total"
  | ExecutionReceiptFailures -> "masc_keeper_execution_receipt_failures_total"
  | OperatorBroadcastSuppressed -> "masc_keeper_operator_broadcast_suppressed_total"
  | LlmBridgeFailures -> "masc_keeper_llm_bridge_failures_total"
  | SessionCleanupFailures -> "masc_keeper_session_cleanup_failures_total"
  | ToolExecuteFailures -> "masc_agent_tool_execute_runtime_failures_total"
  | RolloverFailures -> "masc_keeper_rollover_failures_total"
  | LifecycleDispatchRejections -> "masc_keeper_lifecycle_dispatch_rejections_total"
  | RecordingErrorDedup -> "masc_keeper_recording_error_dedup_total"
  | PausedStatePersistErrors -> "masc_keeper_paused_state_persist_errors_total"
  | UnexpectedToolPartialTolerance ->
    "masc_keeper_unexpected_tool_partial_tolerance_total"
  | RequireToolUseViolations -> "masc_keeper_require_tool_use_violations_total"
  | ToolCallTotal -> "masc_keeper_tool_call_total"
  | ProfileConfigConflicts -> "masc_keeper_profile_config_conflicts_total"
  | OasTimeoutClassifications -> "masc_keeper_oas_timeout_classifications_total"
  | NoToolProvider -> "masc_keeper_no_tool_provider_total"
  | ProactiveOutcome -> "masc_keeper_proactive_outcome_total"
  | OllamaSaturationSkip -> "masc_keeper_ollama_saturation_skip_total"
  | TaskLoadFailures -> "masc_keeper_task_load_failures_total"
  | ToolSelectionFailures -> "masc_keeper_tool_selection_failures_total"
  | ToolPolicyFailures -> "masc_keeper_tool_policy_failures_total"
  | ReconcileFailures -> "masc_keeper_reconcile_failures_total"
  | DecisionAuditFlushFailures -> "masc_keeper_decision_audit_flush_failures_total"
  | OasCancel -> "masc_keeper_oas_cancel_total"
  | ClaimAutoProvision -> "masc_keeper_claim_auto_provision_total"
  | TomlInvalid -> "masc_keeper_toml_invalid_total"
  | PersonaDriftMissing -> "masc_keeper_persona_drift_missing_total"
  | RoomInitFailures -> "masc_keeper_room_init_failures_total"
  | PresenceSyncFailures -> "masc_keeper_presence_sync_failures_total"
  | SelfPreservationUniversal -> "masc_keeper_self_preservation_universal_total"
  | StaleStormPaused -> "masc_keeper_stale_storm_paused_total"
  | ProviderTimeoutLoopPaused -> "masc_keeper_provider_timeout_loop_paused_total"
  | CycleExceptions -> "masc_keeper_cycle_exceptions_total"
  | SnapshotWriteFailures -> "masc_keeper_snapshot_write_failures_total"
  | StateSnapshotSkippedNoState ->
    "masc_keeper_state_snapshot_skipped_no_state_total"
  | ProgressUpdatedLineFailures -> "masc_keeper_progress_updated_line_failures_total"
  | SseBroadcastFailures -> "masc_keeper_sse_broadcast_failures_total"
  | RoomHeartbeatFailures -> "masc_keeper_room_heartbeat_failures_total"
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
  | CascadeSyncFailures -> "masc_keeper_cascade_sync_failures_total"
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
  | MemoryJsonlOps -> "masc_keeper_memory_jsonl_ops_total"
  | UserVisibleReplySource -> "masc_keeper_user_visible_reply_source_total"
  | ContinuitySummarySource -> "masc_keeper_continuity_summary_source_total"
  | SummarizerStateScrubs -> "masc_keeper_summarizer_state_scrubs_total"
  | SummarizerStateBlocksRemoved ->
    "masc_keeper_summarizer_state_blocks_removed_total"
  | OasEnvKeyRejections -> "masc_keeper_oas_env_key_rejections_total"
  | ContinuityTsRecovered -> "masc_keeper_continuity_ts_recovered_total"
  | MemoryWriteFailures -> "masc_keeper_memory_write_failures_total"
  | MemoryConsolidations -> "masc_keeper_memory_consolidations_total"
  | WriteMetaCycleFailures -> "masc_keeper_write_meta_cycle_failures_total"
  | AlertPersistFailures -> "masc_keeper_alert_persist_failures_total"
  | MetricsSseFailures -> "masc_keeper_metrics_sse_failures_total"
  | ChatStoreFailures -> "masc_keeper_chat_store_failures_total"
  | ObservationQueryFailures -> "masc_keeper_observation_query_failures_total"
  | OasOnStop -> "masc_keeper_oas_on_stop_total"
  | OasOnIdleEscalated -> "masc_keeper_oas_on_idle_escalated_total"
  | QuantitativeClaimRejections -> "masc_keeper_quantitative_claim_rejections_total"
  | InvariantViolations -> "masc_keeper_invariant_violations_total"
  | FsmEdgeTransitions -> "masc_keeper_fsm_edge_transitions_total"
  | TurnFsmTransitions -> "masc_keeper_turn_fsm_transitions_total"
  | TurnPhaseDuration -> "masc_keeper_turn_phase_duration_seconds"
  | LifecycleTransitions -> "masc_keeper_lifecycle_transitions_total"
  | LifecycleCallbackFailures -> "masc_keeper_lifecycle_callback_failures_total"
  | BriefingSessionLastEventSource ->
    "masc_briefing_session_last_event_source_total"
  | EventBusDrain -> "masc_keeper_event_bus_drain_total"
  | SupervisorCleanupFailures -> "masc_keeper_supervisor_cleanup_failures_total"
  | SlotForceReleased -> "masc_keeper_slot_force_released_total"
  | SpawnSlotDenied -> "masc_keeper_spawn_slot_denied_total"
  | RegistryUpdateDropped -> "masc_keeper_registry_update_dropped_total"
  | RegistryOrphanThresholdBreached ->
    "masc_keeper_registry_orphan_threshold_breached_total"
  | StaleWatchdogTickFailures -> "masc_keeper_stale_watchdog_tick_failures_total"
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
  | LivenessRecoveryAttempts -> "masc_keeper_liveness_recovery_attempts_total"
  | LivenessRecoveryOutcomes -> "masc_keeper_liveness_recovery_outcomes_total"
  | PassiveLoopDetectedTotal -> "masc_keeper_passive_loop_detected_total"
  | PassiveLoopStreak -> "masc_keeper_passive_loop_streak"
  | PassiveLoopStreakExceeded -> "masc_keeper_passive_loop_streak_exceeded_total"
  | RequiredToolLoopDetectedTotal -> "masc_keeper_required_tool_loop_detected_total"
  | ZombieLoopDetectedTotal -> "masc_keeper_zombie_loop_detected_total"
  | RequiredToolGateSuppressedTotal -> "masc_keeper_required_tool_gate_suppressed_total"
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
  | CascadeSaturationSignal -> "masc_keeper_cascade_saturation_signal_total"
  | ToolUseFailure -> "masc_keeper_tool_use_failure_total"
  | ToolNotAllowed -> "masc_keeper_tool_not_allowed_total"
  | TurnGateRejectedTerminal -> "masc_keeper_turn_gate_rejected_terminal_total"
  | ReceiptUnmappedDisposition -> "masc_keeper_receipt_unmapped_disposition_total"
  | ExecuteNetworkUpgrade -> "masc_keeper_execute_network_upgrade_total"
  | ExecuteLocalExecution -> "masc_keeper_execute_local_execution_total"
  | DockerRuntimeDiscarded -> "masc_keeper_docker_runtime_discarded_total"
  | ProactiveSkip -> "masc_keeper_proactive_skip_total"
  | StaySilentLoopDetected -> "masc_keeper_stay_silent_loop_detected_total"
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
  | CascadeHttpProbeJsonParseFailures ->
      "masc_cascade_http_probe_json_parse_failures_total"
;;
