(** Keeper domain metrics. *)

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
  | TurnStarts (* counter: turn starts, by keeper *)
  | TurnReattempts (* counter: turn starts that reuse the previous start's turn id, by keeper *)
  | TurnRegressions (* counter: turn starts whose turn id is below the previous start's, by keeper *)
  | TurnLatencyBucket (* counter: turns by keeper and latency bucket *)
  | TurnLatencyByModelBucket
    (* counter: TurnLatencyBucket with channel, provider_kind, model_used, resolved_model_id and
       runtime_profile labels added *)
  | SupervisorSweepStarts (* counter: supervisor sweep loops started, by base_path *)
  | SupervisorLastSweepUnixtime (* gauge: unix time of the last supervisor sweep beat, by base_path *)
  | OperatorClear
  | ToolUnderusedAllowedCount (* gauge: allowed tools never called or called in under 1% of calls, by keeper *)
  | PathRejection (* counter: keeper path rejections, by kind (one value per keeper_path_rejection constructor) *)
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
  | ProactiveOutcome (* counter: scheduled autonomous cycles, by keeper and outcome (tool_called, noop, error) *)
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
  | TurnMetricsSnapshotFailures (* counter: post-cycle metrics snapshot write failures, by keeper and site *)
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
  | PromptSegmentBytes
  | KeeperTurnInstructionHash
  | RawTraceSinkDegraded
  | RawTraceRetentionDeleted
  | RawTraceRetentionSkipped
  | RawTraceRetentionUnlinkFailed
  | WireCaptureResponseSuppressed
  | WireCaptureWriteFailures
  | WireCaptureRecordSkipped
  | TurnBoundaryFailures
  | HistoryFragmentFailures
  | WorkingStateNotCarried
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

val to_string : t -> string

type collection =
  | Metric_store
  | External_observable

val collection : t -> collection
(** Typed ownership of a metric's exported value. [External_observable]
    metrics must not also be registered in the mutable metric store. *)

(** Every constructor of [t], generated from the type declaration by
    [ppx_enumerate].  Membership is compiler-maintained; list order is not a
    public contract. *)
val all : t list
