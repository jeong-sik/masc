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
  | TaskWorktreeLazyRepair
  | TomlInvalid
  | PersonaDriftMissing
  | RoomInitFailures
  | PresenceSyncFailures
  | SelfPreservationUniversal
  | StaleStormPaused
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
  | MemoryBankLoadHistorySwallowedExceptions
  | CascadeHttpProbeJsonParseFailures

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

(** Total tool-call pair-repair downgrades observed at the compaction call
    site (post-compact, after [Context_compact_oas.compact] +
    [Agent_sdk.Context_reducer.reduce fold_reducer]) inside
    {!Keeper_compact_policy}. Incremented by
    [pair_repair_stats.downgraded_tool_uses] /
    [.downgraded_tool_results] returned from
    [Keeper_context_core.repair_broken_tool_call_pairs_with_stats].

    Closes the Prometheus-counter half of C1 (CRIT) from
    [oas-internal-audit.html §6]: the JSONL [tool_pair_repair] structured
    log alone gave operators no [/metrics] view, so fabrication-rate
    alerts required JSONL grep. This counter exposes the same numbers via
    the standard Prometheus surface.

    Labels:
    - [keeper]: keeper name.
    - [kind]: closed 2-value vocabulary —
      {ul {- [downgraded_tool_use]: a [tool_use] block whose paired
            [tool_result] was lost during compaction was rewritten to
            plain text instead of fabricating a synthetic result.}
          {- [downgraded_tool_result]: an orphan [tool_result] block was
            rewritten to plain text instead of fabricating its parent
            [tool_use].}}

    Related: {!metric_keeper_tool_pair_repair} covers the keeper-reducer
    site (pre-compact, inside [Keeper_run_tools]) with the same downgrade
    semantics but a different label vocabulary
    ([dangling_tool_use|orphan_tool_result]) tied to that site's
    before/after diff. The [was_fabricated:true] message-record metadata
    half of C1 is RFC-scope (touches message shape across MASC + OAS) and
    deferred. *)
val metric_keeper_compaction_pair_repair_fabrications : string

(** Effective emergency compaction ratio threshold, set once at module
    init in {!Keeper_compact_policy} from the env override
    [MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD] (default 0.8,
    clamped to \[0.5, 0.99\]). Gauge so operators can confirm via
    /metrics what value the running process actually uses without
    restarting under instrumentation. *)
val metric_keeper_emergency_compact_ratio_threshold : string
val metric_keeper_operator_compact : string
val metric_keeper_operator_clear : string
val metric_keeper_compaction_noop : string
val metric_keeper_continuity_no_state : string
val metric_keeper_tool_pair_repair : string
val metric_keeper_tool_emission_registry_size : string
val metric_keeper_tool_emission_pushes : string
val metric_keeper_tool_underused_allowed_count : string
val metric_keeper_tool_underused_allowed : string
val metric_keeper_path_rejection : string
val metric_keeper_path_resolver_identity_mismatch : string

val metric_ide_orphan_writes : string
(** RFC-0128 §4.2 — increments when an IDE annotation/region write
    cannot be assigned to a canonical-URL bucket and lands in
    [.masc-ide/_orphan/]. Counter labels:
    [kind = "annotation" | "region"], [reason]. *)
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

val metric_keeper_compact_audit_retention_parse : string
(** Counter incremented once per subscriber start, labelled [outcome] with
    one of [parsed_ok | unset_default | parse_error | out_of_range]
    (see {!Keeper_compact_audit_retention_outcome}). Surfaces operator
    misconfiguration of [MASC_COMPACTION_AUDIT_RETENTION_DAYS]. *)

val metric_keeper_compact_audit_drain_batches : string
(** V17 burst visibility: incremented once per drain-loop iteration of the
    [keeper_compact_audit] subscriber fiber. Combined with
    {!metric_keeper_compact_audit_drain_batch_size_bucket}, operators can
    compute mean batch size and bucket distribution to detect
    9-keeper compaction storms before JSONL writes fall behind. *)

val metric_keeper_compact_audit_drain_batch_size_bucket : string
(** V17 burst visibility: bucketed counter labelled [bucket] with a
    closed vocabulary of [0 | 1_9 | 10_49 | 50_99 | 100_499 | 500_plus].
    Each drain-loop iteration bumps exactly one bucket label so operators
    can detect lag building via
    [rate(masc_keeper_compact_audit_drain_batch_size_bucket_total{bucket="100_499"}[5m])].
    Closed vocab avoids cardinality explosion. *)

val metric_keeper_fs_failures : string
val metric_keeper_crash_persistence_failures : string
val metric_keeper_generation_lineage_failures : string
val metric_keeper_keepalive_signal_failures : string
val metric_keeper_board_signal_wakeup_capped_total : string
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
val metric_keeper_task_worktree_lazy_repair : string
val metric_keeper_toml_invalid : string
val metric_keeper_persona_drift_missing : string
val metric_keeper_room_init_failures : string
val metric_keeper_presence_sync_failures : string
val metric_keeper_self_preservation_universal : string
val metric_keeper_stale_storm_paused : string
val metric_keeper_oas_timeout_budget_loop_paused : string
val metric_keeper_cycle_exceptions : string
val metric_keeper_snapshot_write_failures : string
val metric_keeper_state_snapshot_skipped_no_state : string
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

val metric_keeper_decision_audit_ring_overflows : string
(** Counter for [Keeper_decision_audit.append] overwriting an
    unflushed record because the ring buffer was at capacity.
    Label [keeper] names the affected keeper.  Each increment is
    one decision_record lost to disk because the flush loop did
    not keep up with the append rate.  Non-zero counts mean the
    flush_batch_size / flush_interval_sec tuning is below the
    decision-emission rate and forensics data is being silently
    dropped. *)

val metric_keeper_reply_skill_route_strips : string
(** Counter for [Keeper_text_processing.strip_internal_reply_markup]
    invocations that found and stripped at least one
    [SKILL:] / [SKILL_REASON:] line from the raw reply.  Each
    increment is one invocation; pair with
    [metric_keeper_reply_skill_route_lines_removed] for the total
    line count.  Rising rate is the resonance-loop input indicator
    for the *skill* marker (sibling of
    [metric_keeper_summarizer_state_scrubs] for the [STATE] marker
    in PR #15676). *)

val metric_keeper_reply_skill_route_lines_removed : string
(** Counter for the total number of SKILL: / SKILL_REASON: lines
    stripped from raw replies.  Divide by
    [_reply_skill_route_strips] for lines-per-invocation. *)

val metric_keeper_memory_llm_summary_outcomes : string
(** Counter for [Keeper_memory_llm_summary.summarize_with_provider]
    attempts, classified by label [outcome] (ok_summary | timed_out |
    http_error | empty_response).  Labels: [outcome], [provider]
    (model_id of the attempt), [cascade] (cascade name driving the
    chain).  Adjacent counter
    [metric_keeper_memory_llm_summary_chain_exhausted] increments
    only when every provider in the cascade returned a non-Ok
    outcome — the operational signal that the consolidation pass
    received no summary at all. *)

val metric_keeper_memory_llm_summary_chain_exhausted : string
(** Counter for [Keeper_memory_llm_summary.summarize_with_providers]
    runs where every provider in the cascade returned a non-Ok
    outcome.  Label [cascade] names the cascade.  A rising rate
    means consolidation is silently skipping the LLM summary step. *)

val metric_keeper_memory_jsonl_ops : string
(** Counter for [Agent_sdk.Memory.long_term_backend] operations
    served by the JSONL backend, classified by label [outcome]
    (one of the labels in {!Memory_oas_bridge_op_outcome}).
    Labels: [outcome], [agent].  Rising failed/miss rates surface
    JSONL-side issues that the dependency-leaf [Memory_jsonl] cannot
    self-report. *)

val metric_keeper_user_visible_reply_source : string
(** Counter for [Keeper_text_processing.user_visible_reply_text]
    return paths.  Label [source] is governed by
    {!Keeper_user_visible_reply_source}.  Rising
    [hardcoded_default] rate is the operational signal that the
    LLM is consistently producing no usable reply and the user is
    being shown the literal ["State updated."]. *)

val metric_keeper_continuity_summary_source : string
(** Counter for [Keeper_world_observation.read_continuity_summary]
    return paths.  Label [source] is governed by
    {!Keeper_continuity_summary_source}; label [keeper] names the
    keeper whose summary was read.  Rising
    [meta_fallback_exception] is the operational signal that the
    catch-all [| _ -> ] is swallowing exceptions that previously
    had no audit trail. *)

val metric_keeper_summarizer_state_scrubs : string
(** Counter for [Keeper_summarizer.keeper_summarizer] invocations,
    classified by label [outcome] (with_scrub | without_scrub).
    Rising [with_scrub] rate is the operational signal that the
    OAS compaction summarizer is regularly receiving [STATE]
    markers in summarisable messages — the resonance-loop input
    that PR #7647 closed at the prompt-injection layer. *)

val metric_keeper_summarizer_state_blocks_removed : string
(** Counter for the total number of [STATE] block start markers
    scrubbed.  Divide by [_summarizer_state_scrubs{outcome=with_scrub}]
    to get blocks-per-scrub; diverging signals turn replay or
    assistant echo of [STATE] across multiple messages. *)

val metric_keeper_oas_env_key_rejections : string
(** Counter for [Keeper_types_profile.extract_oas_env_from_doc]
    entries dropped because the suffix did not match the
    [OAS_(CLAUDE|CODEX|GEMINI)_] / [MASC_KEEPER_OAS_] prefix allowlist, apart
    from a narrow legacy alias for the keeper unified max-token knob.  Each
    rejected key increments by one and produces a warn line so operators can
    spot configuration mistakes or attempted env-injection bypass.  Non-zero
    counts at startup mean the keeper TOML contains [keeper.oas_env.<X>] keys
    that the runtime silently ignored. *)

val metric_keeper_continuity_ts_recovered : string
(** Counter for the synthetic-ts recovery branch in
    [Keeper_meta_json_parse.parse_last_continuity_update_ts]: when
    the persisted [last_continuity_update_ts] is missing/invalid
    ([<= 0.0]) but [continuity_summary] is non-empty, the loader
    substitutes [Time_compat.now ()] so the cooldown gate does not
    interpret the empty timestamp as "never reflected" and bypass
    cooldown for the first run.  Each recovery event increments
    this counter and emits a warn line; non-zero counts mean the
    meta JSON was written without a valid timestamp or the field
    was corrupted on disk. *)

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

val metric_briefing_session_last_event_source : string
(** Counter for the [last_event.source] provenance marker emitted by
    [Briefing_compactors.compact_session_json] (PR #15777, V14).
    Label [source] uses a closed 5-value vocabulary:
    - [recent_event_latest], [fabricated_no_recent_events]
      (SSOT labels from {!Briefing_session_last_event_source.to_label})
    - [missing], [no_last_event], [not_assoc]
      (defensive guards against future regressions in the leaf module)
    Emitted once per session per briefing at the
    [dashboard_mission_briefing] wrapper. Cardinality bound:
    [take 3] sessions per briefing × small briefing rate. *)

val metric_keeper_event_bus_drain : string
val metric_keeper_supervisor_cleanup_failures : string
val metric_keeper_slot_force_released : string
val metric_keeper_spawn_slot_denied : string
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

(** Counter for non-Cancel exceptions silently swallowed by the
    catch-all in [Keeper_memory_recall.load_history_user_messages].
    Labels: [keeper] (when available), [exception_class] — a closed
    4-value vocabulary from [Keeper_memory_recall_exn_class.to_label]:
    {ul
    {- [yojson_parse_error] — [Yojson.Json_error _]}
    {- [io_error] — [Sys_error _] / [Unix.Unix_error _]}
    {- [type_error] — [Failure _] / [Yojson.Safe.Util.Type_error _]}
    {- [other] — terminal bucket for any other exception}}
    Bounded cardinality by construction (constructor-level pattern
    match on the [exn] type, not a substring scan on
    [Printexc.to_string]) so the metric cannot balloon in-process
    memory as malformed lines accumulate. Full [Printexc.to_string]
    detail is retained in the [Log.Keeper.warn] body. Behavior is
    unchanged (the function still returns no row for the failing
    line); the counter exists so JSONL corruption / fs faults stop
    masking as "no history". *)
val metric_keeper_memory_bank_load_history_swallowed_exceptions : string

(** Counter for probe responses dropped by the silent JSON parse catch-all
    in [Cascade_http_probe.try_probe]. Before this counter existed the
    [match Yojson.Safe.from_string body with | exception _ -> None] branch
    returned [None] without log/counter, leaving operators unable to
    distinguish "endpoint down" from "endpoint up but emitting bad JSON".

    Labels:
    {ul
    {- [error_kind] — closed 2-value vocabulary
       \{[yojson_parse_error] | [other]\}. [yojson_parse_error] is
       [Yojson.Json_error _]; [other] is the terminal bucket for any
       other (non-[Eio.Cancel.Cancelled]) exception. Bounded by
       constructor-level pattern match on the [exn] type, not a
       substring scan on [Printexc.to_string].}
    {- [probe_kind] — closed 1-value vocabulary \{[ollama_api_ps]\}.
       Only one probe site exists in [cascade_http_probe.ml]; the label
       is named after the [/api/ps] endpoint it targets.}}

    Cardinality bound: 2 × 1 = 2 label combinations.
    Behavior is unchanged (the probe still returns [None] on parse
    failure); the counter and accompanying [Log.Cascade.warn] exist so
    "endpoint up but JSON is garbage" stops being indistinguishable
    from "endpoint down". *)
val metric_cascade_http_probe_json_parse_failures : string

val metric_keeper_path_resolver_identity_mismatch : string
val metric_keeper_passive_loop_streak : string
val metric_keeper_passive_loop_streak_exceeded : string
