(** Keeper domain metrics

    Variant-based metric names with backward-compatible string constants.
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
  | OperatorCompact
  | OperatorClear
  | CompactionNoop
  | ToolEmissionRegistrySize
  | ToolEmissionPushes
  | ToolUnderusedAllowedCount
  | ToolUnderusedAllowed
  | PathRejection
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
  | FsFailures
  | CrashPersistenceFailures
  | GenerationLineageFailures
  | KeepaliveSignalFailures
  | BoardSignalNoWakeTotal
  | MetaJsonFailures
  | ToolsOasFailures
  | OasHookOutputParseFailures
  | TurnUpUpdateFailures
  | ExecToolsFailures
  | CircuitBreakerTrips
  | PromptFailures
  | RunContextFailures
  | ShellOpsFailures
  | TagDispatchFailures
  | TraceEmitFailures
  | TransitionAuditFailures
  | ExecutionReceiptFailures
  | LlmBridgeFailures
  | SessionCleanupFailures
  | ShellBashFailures
  | RolloverFailures
  | LifecycleDispatchRejections
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
  | StaleFleetBatchPaused
  | OasTimeoutBudgetLoopPaused
  | CycleExceptions
  | SnapshotWriteFailures
  | ProgressUpdatedLineFailures
  | SseBroadcastFailures
  | RoomHeartbeatFailures
  | TurnMetricsSnapshotFailures
  | OasExecutionErrors
  | EpisodeCreateFailures
  | MemoryActivityEmitFailures
  | SupervisorSweepFailures
  | TomlReconcileSweepFailures
  | ToolUsageFlushFailures
  | TurnTimeoutCommitted
  | TurnErrorAfterTools
  | CascadeSyncFailures
  | LocalDiscoveryFailures
  | ThinkingPersistFailures
  | CheckpointFailures
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
  | EventBusDrain
  | SupervisorCleanupFailures
  | SlotForceReleased
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
  | RequiredToolLoopDetectedTotal
  | ZombieLoopDetectedTotal
  | RequiredToolGateSuppressedTotal
  | ConsecutiveIdle
  | LastProductiveTs
  | OasTimeoutBudgetStrike
  | StaleTerminationTotal
  | StaleTerminationByClass
  | OasTimeoutBudgetWatchdogTermination
  | StaleTerminationThresholdBreached
  | StaleTerminationBatch
  | StaleBroadcastEmitFailures
  | OasRunTimeout
  | ToolUseFailure
  | ToolNotAllowed
  | TurnGateRejectedTerminal
  | ReceiptUnmappedDisposition
  | BashNetworkUpgrade
  | BashLocalExecution
  | DockerRuntimeDiscarded
  | ProactiveSkip
  | StaySilentLoopDetected
  | UsageTrust
  | UsageAnomalyReason
  | ConfigEnvParseFailures
  | PostTurnWireinFailures
  | RecurringFailures
  | TurnCleanupFailures

val to_string : t -> string

(** Backward-compatible string constants *)

val metric_keeper_turns : string
val metric_keeper_input_tokens : string
val metric_keeper_output_tokens : string
val metric_keeper_cache_creation_tokens : string
val metric_keeper_cache_read_tokens : string
val metric_keeper_usage_anomalies : string
val metric_keeper_total_cost_usd : string
val metric_keeper_turn_scheduled : string
val metric_keeper_turn_completed : string
val metric_keeper_idle_seconds : string
val metric_keeper_contract_violations : string
val metric_keeper_alive_but_stuck : string
val metric_keeper_alive_but_stuck_seconds : string
val metric_keeper_alive_but_stuck_threshold_seconds : string
val metric_keeper_alive_but_stuck_recovery_requests : string
val metric_keeper_alive_but_stuck_recovery : string
val metric_keeper_metric_emit_dropped : string
val metric_keeper_context_max_observed : string
val metric_keeper_turn_starts : string
val metric_keeper_turn_reattempts : string
val metric_keeper_turn_regressions : string
val metric_keeper_turn_livelock_blocks : string
val metric_keeper_turn_latency_bucket : string
val metric_keeper_turn_latency_by_model_bucket : string
val metric_keeper_provider_cooldown_skip : string
val metric_keeper_provider_cooldown_remaining_sec : string
val metric_keeper_provider_block_duration_sec : string
val metric_keeper_turn_queue_depth : string
val metric_keeper_supervisor_sweep_starts : string
val metric_keeper_supervisor_last_sweep_unixtime : string

(** RFC-0059 PR-7 soak observability counter.

    Labels: [keeper] (keeper name, first), [outcome] in
    {"pool" | "inline_no_pool" | "inline_disabled" | "submit_failed"}.

    [outcome=submit_failed] is emitted in addition to a prior
    [outcome=pool] increment on the same launch when the worker-Domain
    submit raises a non-cancellation exception; the total counter can
    therefore exceed the number of supervised launches.  Aggregations
    that need launch counts should sum over [pool | inline_no_pool |
    inline_disabled] only. *)
val metric_keeper_domain_pool_fork : string

val metric_keeper_semaphore_wait_timeout : string
val metric_keeper_turn_slot_bookkeeping_failures : string
val metric_keeper_semaphore_wait_seconds : string
val metric_keeper_semaphore_wait_seconds_bucket : string
val metric_keeper_slot_yield_total : string
val metric_keeper_compactions : string
val metric_keeper_compaction_ratio_change : string
val metric_keeper_compaction_saved_tokens : string
val metric_keeper_operator_compact : string
val metric_keeper_operator_clear : string
val metric_keeper_compaction_noop : string
val metric_keeper_tool_emission_registry_size : string
val metric_keeper_tool_emission_pushes : string
val metric_keeper_tool_underused_allowed_count : string
val metric_keeper_tool_underused_allowed : string
val metric_keeper_path_rejection : string
val metric_keeper_path_resolver_identity_mismatch : string
val metric_keeper_heartbeat_successes : string
val metric_keeper_heartbeat_failures : string
val metric_keeper_cleanup_tracking_failures : string
val metric_keeper_dispatch_event_failures : string
val metric_keeper_directive_failures : string
val metric_keeper_tool_call_duration : string
val metric_keeper_write_meta_failures : string
val metric_keeper_meta_read_failures : string
val metric_keeper_approval_queue_failures : string
val metric_keeper_guards_failures : string
val metric_keeper_profile_load_failures : string
val metric_keeper_compact_audit_failures : string
val metric_keeper_fs_failures : string
val metric_keeper_crash_persistence_failures : string
val metric_keeper_generation_lineage_failures : string
val metric_keeper_keepalive_signal_failures : string
val metric_keeper_board_signal_no_wake_total : string
val metric_keeper_meta_json_failures : string
val metric_keeper_tools_oas_failures : string
val metric_keeper_oas_hook_output_parse_failures : string
val metric_keeper_turn_up_update_failures : string
val metric_keeper_exec_tools_failures : string
val metric_keeper_circuit_breaker_trips : string
val metric_keeper_prompt_failures : string
val metric_keeper_run_context_failures : string
val metric_keeper_shell_ops_failures : string
val metric_keeper_tag_dispatch_failures : string
val metric_keeper_trace_emit_failures : string
val metric_keeper_transition_audit_failures : string
val metric_keeper_execution_receipt_failures : string
val metric_keeper_llm_bridge_failures : string
val metric_keeper_shell_bash_failures : string
val metric_keeper_rollover_failures : string
val metric_keeper_lifecycle_dispatch_rejections : string
val metric_keeper_paused_state_persist_errors : string
val metric_keeper_unexpected_tool_partial_tolerance : string
val metric_keeper_require_tool_use_violations : string
val metric_keeper_tool_call_total : string
val metric_keeper_profile_config_conflicts : string
val metric_keeper_oas_timeout_classifications : string
val metric_keeper_no_tool_provider : string
val metric_keeper_proactive_outcome : string
val metric_keeper_ollama_saturation_skip : string
val metric_keeper_task_load_failures : string
val metric_keeper_tool_selection_failures : string
val metric_keeper_tool_policy_failures : string
val metric_keeper_reconcile_failures : string
val metric_keeper_decision_audit_flush_failures : string
val metric_keeper_oas_cancel : string
val metric_keeper_claim_auto_provision : string
val metric_keeper_toml_invalid : string
val metric_keeper_persona_drift_missing : string
val metric_keeper_room_init_failures : string
val metric_keeper_presence_sync_failures : string
val metric_keeper_self_preservation_universal : string
val metric_keeper_stale_storm_paused : string
val metric_keeper_stale_fleet_batch_paused : string
val metric_keeper_oas_timeout_budget_loop_paused : string
val metric_keeper_cycle_exceptions : string
val metric_keeper_snapshot_write_failures : string
val metric_keeper_progress_updated_line_failures : string
val metric_keeper_sse_broadcast_failures : string
val metric_keeper_room_heartbeat_failures : string
val metric_keeper_turn_metrics_snapshot_failures : string
val metric_keeper_oas_execution_errors : string
val metric_keeper_episode_create_failures : string
val metric_keeper_memory_activity_emit_failures : string
val metric_keeper_supervisor_sweep_failures : string
val metric_keeper_toml_reconcile_sweep_failures : string
val metric_keeper_tool_usage_flush_failures : string
val metric_keeper_turn_timeout_committed : string
val metric_keeper_turn_error_after_tools : string
val metric_keeper_cascade_sync_failures : string
val metric_keeper_local_discovery_failures : string
val metric_keeper_thinking_persist_failures : string
val metric_keeper_checkpoint_failures : string
val metric_keeper_memory_write_failures : string
val metric_keeper_memory_consolidations : string
val metric_keeper_write_meta_cycle_failures : string
val metric_keeper_alert_persist_failures : string
val metric_keeper_metrics_sse_failures : string
val metric_keeper_chat_store_failures : string
val metric_keeper_observation_query_failures : string
val metric_keeper_oas_on_stop : string
val metric_keeper_oas_on_idle_escalated : string
val metric_keeper_quantitative_claim_rejections : string
val metric_keeper_invariant_violations : string
val metric_keeper_fsm_edge_transitions : string
val metric_keeper_turn_fsm_transitions : string
val metric_keeper_turn_phase_duration : string
val metric_keeper_lifecycle_transitions : string
val metric_keeper_lifecycle_callback_failures : string
val metric_keeper_event_bus_drain : string
val metric_keeper_supervisor_cleanup_failures : string
val metric_keeper_slot_force_released : string
val metric_keeper_registry_update_dropped : string
val metric_keeper_registry_orphan_threshold_breached : string
val metric_keeper_stale_watchdog_tick_failures : string
val metric_keeper_dead_total : string
val metric_keeper_auto_resumed_total : string
val metric_keeper_auto_resume_blocked_total : string
val metric_keeper_skip_idle_wake_resumed : string
val metric_keeper_event_queue_override : string
val metric_keeper_stimulus_consumed : string
val metric_keeper_unsupported_stimulus : string
val metric_keeper_near_exhaustion_total : string
val metric_keeper_restart_attempts : string
val metric_keeper_restart_outcomes : string
val metric_keeper_liveness_recovery_attempts : string
val metric_keeper_liveness_recovery_outcomes : string
val metric_keeper_passive_loop_detected_total : string
val metric_keeper_required_tool_loop_detected_total : string
val metric_keeper_zombie_loop_detected_total : string
val metric_keeper_required_tool_gate_suppressed_total : string
val metric_keeper_consecutive_idle : string
val metric_keeper_last_productive_ts : string
val metric_keeper_oas_timeout_budget_strike : string
val metric_keeper_stale_termination_total : string
val metric_keeper_stale_termination_by_class : string
val metric_keeper_oas_timeout_budget_watchdog_termination : string
val metric_keeper_stale_termination_threshold_breached : string
val metric_keeper_stale_termination_batch : string
val metric_keeper_stale_broadcast_emit_failures : string
val metric_keeper_oas_run_timeout : string
val metric_keeper_tool_use_failure : string
val metric_keeper_tool_not_allowed : string
val metric_keeper_turn_gate_rejected_terminal : string
val metric_keeper_receipt_unmapped_disposition : string
val metric_keeper_bash_network_upgrade : string
val metric_keeper_bash_local_execution : string
val metric_keeper_docker_runtime_discarded : string
val metric_keeper_proactive_skip : string
val metric_keeper_stay_silent_loop_detected : string
val metric_keeper_usage_trust : string
val metric_keeper_usage_anomaly_reason : string
val metric_keeper_config_env_parse_failures : string
val metric_keeper_post_turn_wirein_failures : string
val metric_keeper_recurring_failures : string
val metric_keeper_turn_cleanup_failures : string
val metric_keeper_session_cleanup_failures : string
val metric_keeper_path_resolver_identity_mismatch : string
val metric_keeper_passive_loop_streak : string
val metric_keeper_passive_loop_streak_exceeded : string
