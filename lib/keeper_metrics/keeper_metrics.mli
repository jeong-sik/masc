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
  | FailureJudgmentOutcome
  | IdleSeconds
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
  | DomainPoolFork
  | TurnHolderBookkeepingFailures
  | Compactions
  | CompactionRatioChange
  | CompactionSavedTokens
  | CompactionPairRepairDrops
  | EmergencyCompactRatioThreshold
  | OperatorCompact
  | OperatorClear
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
  | ApprovalResolutionSignal
  | ProfileLoadFailures
  | CompactAuditFailures
  | FsFailures
  | PersistencePreparationStageDuration
  | PersistencePreparationExamined
  | PersistenceLaneWaits
  | PersistenceLanePending
  | PersistenceLaneInFlight
  | PersistenceLaneDuration
  | CrashPersistenceFailures
  | GenerationLineageFailures
  | KeepaliveSignalFailures
  | BoardSignalNoWakeTotal
  | BoardSignalAttentionCandidateTotal
  | MetaJsonFailures
  | ToolsOasFailures
  | TurnUpUpdateFailures
  | AgentToolDispatchRuntimeFailures
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
  | LifecycleTransactions
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
  | PersonaDriftMissing
  | WorkspaceInitFailures
  | PresenceSyncFailures
  | StaleStormPaused
  | TurnFailureStreakPaused
  | CycleExceptions
  | SnapshotReadFailures
  | SnapshotWriteFailures
  | PromptUnknownToolTokens
  | PromptTokenStripped
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
  | MemoryLlmSummaryOutcomes
  | MemoryLlmSummaryChainExhausted
  | HitlSummaryOutcomes
  | OasEnvKeyRejections
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
  | InvariantViolations
  | FsmEdgeTransitions
  | TurnFsmTransitions
  | TurnPhaseDuration
  | LifecycleTransitions
  | LifecycleCallbackFailures
  | CompactionCallbackRecoveries
  | EventBusDrain
  | SupervisorCleanupFailures
  | RegistryUpdateDropped
  | RegistryOrphanThresholdBreached
  | RegistryInvalidEntry
  | StimulusConsumed
  | UnsupportedStimulus
  | RestartAttempts
  | RestartOutcomes
  | OasRunTimeout
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
  | MemoryBankLoadHistorySwallowedExceptions
  | MemoryRecallReadErrors
  | MemoryOsRecallUnavailable
  | MemoryOsReobserveEchoSuppressed
  | RuntimeHttpProbeJsonParseFailures
  | VisionAnalyze
  | VisionCandidateAttempts
  | VisionIngestEvictions
  | PromptSegmentBytes
  | PromptTemplateRenderOutcome
  | ToolCallParamCompleteness
  | KeeperTurnInstructionHash
  | KeeperToolCallRetryLoop
  | ShellIrEffectTotal
  | RawTraceSinkDegraded
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
