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
  | ContextMaxObserved
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
