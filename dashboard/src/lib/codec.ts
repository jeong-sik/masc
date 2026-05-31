// Dashboard Wire→Typed Codec Layer
//
// Unified entry point for all wire-format-to-typed-normalization functions.
// Previously scattered across keeper-store-normalize.ts, store-normalizers.ts,
// and mission-normalizers.ts.
//
// TODO: Gradually inline functions from the legacy files into this module
// and delete the legacy re-exports once all call sites migrate.

// --- Keeper normalizers (from keeper-store-normalize.ts) ---
export {
  toKeeperPhase,
  toPipelineStage,
  toKeeperLifecycleState,
  deriveLifecycleState,
  keeperFreshnessTs,
  normalizeKeeperTrustTerminalReason,
  normalizeKeeperTrust,
  normalizeKeepers,
} from '../keeper-store-normalize'

// --- Store normalizers (from store-normalizers.ts) ---
export {
  normalizeAgentStatus,
  normalizeTaskStatus,
  normalizeAgent,
  normalizeTask,
  normalizeMessage,
  normalizeExecutionTone,
  normalizeExecutionSummary,
  normalizeExecutionHandoff,
  normalizeExecutionQueueItem,
  normalizeExecutionSessionBrief,
  normalizeExecutionWorkerSupportBrief,
  normalizeExecutionContinuityBrief,
  normalizeShellMetaCognitionBelief,
  normalizeShellMetaCognitionTension,
  normalizeShellMetaCognitionDesire,
  normalizeShellMetaCognitionSummary,
  normalizeDashboardConfigResolutionItem,
  normalizeDashboardConfigResolution,
  normalizeDashboardRuntimeDiagnostic,
  normalizeDashboardRuntimeResolution,
  normalizeAttentionItem,
  normalizeRecommendedAction,
  messageSortKey,
  mergeMessages,
  normalizeBuildIdentity,
  normalizeServerStatus,
  mergeServerStatus,
} from '../store-normalizers'

// --- Mission normalizers (from mission-normalizers.ts) ---
export {
  normalizeMission,
  normalizeMissionSessionDetail,
  normalizeMissionBriefing,
} from '../mission-normalizers'
