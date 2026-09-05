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
  | VisionDownscale
  | PromptSegmentBytes
  | PromptTemplateRenderOutcome
  | ToolCallParamCompleteness
  | KeeperTurnInstructionHash
  | KeeperToolCallRetryLoop
  | ShellIrEffectTotal
  | RawTraceSinkDegraded
  | RawTraceRetentionDeleted
  | RawTraceRetentionSkipped
  | RawTraceRetentionUnlinkFailed
  | WireCaptureResponseSuppressed
  | WireCaptureWriteFailures
  | WireCaptureRecordSkipped

val to_string : t -> string

type collection =
  | Metric_store
  | External_observable

val collection : t -> collection
(** Typed ownership of a metric's exported value. [External_observable]
    metrics must not also be registered in the mutable metric store. *)

val emit_runtime_selected :
  keeper_name:string -> runtime_id:string -> fallback_reason:string -> unit

val emit_runtime_rotation :
  keeper_name:string -> from_runtime:string -> to_runtime:string -> reason:string -> unit

(** Every constructor of [t], generated from the type declaration by
    [ppx_enumerate].  Membership is compiler-maintained; list order is not a
    public contract. *)
val all : t list
