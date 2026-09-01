// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import {
  type AgentTimelineEvent,
  type AgentTimelineResponse,
} from './schemas/agent-timeline'
import {
  type RuntimeDefaultsResponse,
  type RuntimeEntry,
  type ModelRouting,
} from './schemas/runtime-defaults'
import {
  type RuntimeResolvedResponse,
  type RuntimeResolution,
  type MaxContextSource,
  type RuntimeLaneSnapshot,
  type ResolvedAssignmentTarget,
  type RuntimeAssignment,
} from './schemas/runtime-resolved'
export type {
  DashboardGoalsTreeResponse,
  DashboardGoalDetailResponse,
  GoalDetailKeeper,
  GoalKeeperTrustApprovalState,
  GoalKeeperTrustExecutionSummary,
  GoalKeeperTrustLatestEvent,
  GoalKeeperTrustSummary,
  GoalDetailTimelineEvent,
  GoalTaskSummary,
  GoalTreeNode,
  GoalTreeSummary,
  GoalTreeTask,
} from '../types'
export { fetchDashboardGoalsTree, fetchDashboardGoalDetail } from './dashboard-goals'
export { reportToolHostFailure } from './tool-host-failure'
export { fetchDashboardBootstrap, fetchDashboardShell } from './dashboard-hot'
export type {
  FusionRunStatusLabel,
  FusionTopologyLabel,
  FusionRunRecord,
  DashboardFusionRunsResponse,
  FusionConfigView,
  FusionPresetConfigView,
  FusionPanelGroupView,
  FusionJudgeSpecView,
} from './dashboard-fusion'
export {
  parseFusionRunsResponse,
  fetchFusionRuns,
  parseFusionConfigResponse,
  fetchFusionConfig,
  runnableTopologies,
} from './dashboard-fusion'
export type {
  VerificationRunStatusLabel,
  VerificationRunRecord,
  DashboardVerificationRunsResponse,
} from './dashboard-verification-runs'
export {
  parseVerificationRunsResponse,
  fetchVerificationRuns,
} from './dashboard-verification-runs'
export type {
  GoalVerificationReviewKind,
  GoalVerificationRunStatus,
  GoalVerificationRunRecord,
  DashboardGoalVerificationRunsResponse,
} from './dashboard-goal-verification-runs'
export {
  parseGoalVerificationRunsResponse,
  fetchGoalVerificationRuns,
} from './dashboard-goal-verification-runs'
export {
  fetchExactLaneRun,
  fetchExactLaneRuns,
  parseExactLaneRunResponse,
  parseExactLaneRunsResponse,
  type DashboardExactLaneRunsResponse,
  type ExactLane,
  type ExactLaneRunCursor,
  type ExactLaneRunRecord,
  type ExactLaneRunSummary,
  type ExactLaneRunInput,
  type ExactLaneRunStatus,
} from './dashboard-exact-lane-runs'
export {
  fetchStandaloneLanes,
  parseStandaloneLanesSnapshot,
  type StandaloneLaneConfigurationState,
  type StandaloneLaneId,
  type StandaloneLaneSlotCount,
  type StandaloneLaneSnapshotRow,
  type StandaloneLaneStatus,
  type StandaloneLanesSnapshot,
} from './dashboard-standalone-lanes'

// --- Dashboard projections ---

export type { DashboardFeedRetention, DashboardFeedMetadata } from './dashboard-shared'
export { decodeDashboardFeedMetadata } from './dashboard-shared'

export type { RuntimeDefaultsResponse, RuntimeEntry, ModelRouting }
export type {
  RuntimeResolvedResponse,
  RuntimeResolution,
  MaxContextSource,
  RuntimeLaneSnapshot,
  ResolvedAssignmentTarget,
  RuntimeAssignment,
}
export type { AgentTimelineEvent, AgentTimelineResponse }

export { fetchAgentTimeline } from './dashboard-agent'

export type {
  AgentRelation,
  AgentRelationsResponse,
} from './schemas/agent-relations'
export { fetchAgentRelations } from './dashboard-agent'

// Re-export from the hot-path API barrel where the SSOT definition lives
// alongside `fetchDashboardShell` / `fetchDashboardBootstrap` (all three
// share the same hot/bootstrap consumer profile). Until 2026-05-27 the
// implementation was duplicated here verbatim, with `namespace-truth-actions`
// importing the hot variant and `telemetry-unified` / `fleet-telemetry-panel`
// the dashboard.ts variant — same endpoint, same timeout, two definitions
// that could drift independently. SSOT now lives in `./dashboard-hot`.
export { fetchDashboardNamespaceTruth } from './dashboard-hot'

export {
  fetchKeeperProviderInput,
  type ProviderInputMessage,
  type ProviderInputSnapshot,
  type ProviderInputSystemPrompt,
  type ProviderInputToolSchema,
  type ProviderInputWire,
} from './dashboard-provider-input'

export type {
  DashboardExecutionTrustKeeper,
  DashboardExecutionTrustResponse,
  ToolQualityHourlyPoint,
  ToolQualityResponse,
  DashboardPerfRow,
  DashboardPerfComparisonRow,
  DashboardPerfResponse,
} from './dashboard-execution'
export {
  fetchDashboardExecution,
  fetchDashboardExecutionTrust,
  fetchToolQuality,
  fetchDashboardPerf,
  fetchDashboardMemory,
} from './dashboard-execution'

export type {
  SetGateModeResponse,
} from './dashboard-gate'
export {
  fetchDashboardGate,
  resolveGateApproval,
  retryGateAutoJudge,
  deleteGateApprovalRule,
  setGateMode,
} from './dashboard-gate'
export { pruneSchedules } from './dashboard-schedule'
export { fetchDashboardBriefing, fetchDashboardMission } from './dashboard-mission'

export type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeDeclaredBindingSpec,
  DashboardRuntimeDeclaredModelCapabilities,
  DashboardRuntimeDeclaredModelSpec,
  DashboardRuntimeDeclaredProviderSpec,
  DashboardRuntimeDeclaredSpec,
  DashboardRuntimeProviderBehaviorCapabilities,
  DashboardRuntimeParameterPolicy,
  DashboardRuntimeRequestConfig,
  DashboardRuntimeResponseFormat,
  DashboardRuntimeToolChoice,
  DashboardRuntimeEffectiveCapabilities,
  DashboardRuntimeReasoningStreamingFormat,
  DashboardRuntimeAssignment,
  DashboardRuntimeAssignmentStatus,
  DashboardRuntimeStartupDegradation,
  DashboardRuntimeStartupDroppedAssignment,
  DashboardRuntimeStartupDroppedLane,
  DashboardRuntimeStartupDroppedRoute,
  DashboardRuntimeStartupMissingCatalogModel,
  DashboardRuntimeProvidersResponse,
  BucketMetric,
  DashboardRuntimeModelMetric,
  LatencyBucket,
  DashboardRuntimeModelMetricsResponse,
  RuntimeTomlConfig,
  CommittedRuntimeTomlConfig,
  RuntimeConfigCommit,
  RuntimeSkillApplication,
  RuntimeConfigApplication,
  RuntimeConfigApplicationLane,
  RuntimeConfigKeeperOverlayApplication,
  RuntimeConfigPreview,
  RuntimeConfigValidation,
  RuntimeConfigValidationIssue,
  RuntimeKeeperSetting,
  RuntimeTomlEditorProtocol,
  RuntimeRoutingLane,
  DashboardOfficialClientRecoveryFailure,
  DashboardOfficialClientKind,
  DashboardOfficialClientSettlement,
  DashboardOfficialClientSessionPhase,
  DashboardOfficialClientRecoveryResolutionRecord,
  DashboardOfficialClientTransientReleaseRecord,
  DashboardOfficialClientSession,
  DashboardOfficialClientSessionResponse,
  DashboardOfficialClientRecoveryApplication,
  DashboardOfficialClientAuditReceipt,
  DashboardOfficialClientRecoveryResponse,
  DashboardOfficialClientRecoveryDecision,
  DashboardOfficialClientLoginStatus,
  DashboardOfficialClientProbeResponse,
} from './dashboard-runtime'
export {
  fetchRuntimeProviders,
  fetchRuntimeModelMetrics,
  fetchRuntimeTomlConfig,
  fetchRuntimeDefaults,
  fetchRuntimeResolved,
  saveRuntimeTomlConfig,
  previewRuntimeTomlConfig,
  patchRuntimeAssignment,
  patchRuntimeMediaFailover,
  patchRuntimeRouting,
  fetchOfficialClientSession,
  resolveOfficialClientSession,
  probeOfficialClientLogin,
} from './dashboard-runtime'

export type {
  KeeperCostMetric,
  KeeperCostMetricsResponse,
  KeeperDecision,
  KeeperDecisionContext,
  KeeperDecisionsResponse,
  CostPerAgentRow,
  CostMatrix,
  CostLatencyBucket,
  CostLatencyResponse,
} from './dashboard-keeper-cost'
export {
  fetchKeeperCostMetrics,
  fetchKeeperDecisions,
  fetchCostLatency,
} from './dashboard-keeper-cost'

export {
  parseDashboardKeeperWaitingSource,
  normalizeSkillActivationProjection,
} from './dashboard-tools-prompts'

export {
  fetchDashboardScheduledAutomation,
  normalizeScheduledAutomation,
} from './dashboard-scheduled-automation'

export type {
  DashboardScheduledAutomationAvailableData,
  DashboardScheduledAutomationPage,
  DashboardScheduledAutomationProjection,
} from './dashboard-scheduled-automation'

export { fetchDashboardMissionBriefing, fetchDashboardPlanning } from './dashboard-mission'


export type {
  DashboardToolInventoryItem,
  DashboardFullHealthResponse,
  DashboardSurfaceHealth,
  ToolMetricsTopEntry,
  ToolMetricsResponse,
  DashboardScheduledAutomationFsm,
  DashboardScheduledAutomationWakeReceipt,
  DashboardScheduledAutomationDispatchReceipt,
  DashboardScheduledAutomationKeeperReactionEvidence,
  DashboardScheduledAutomationKeeperQueueEvidence,
  DashboardScheduledAutomationActor,
  DashboardScheduledAutomationSignal,
  DashboardScheduledAutomationRequest,
  DashboardScheduledAutomationPayloadSupport,
  DashboardScheduledAutomationLiveSupportedNonTerminalEvidence,
  DashboardScheduledAutomation,
  DashboardKeeperWaitingSource,
  DashboardKeeperWaitingState,
  DashboardKeeperWaitingRow,
  DashboardKeeperWaitingKeeper,
  DashboardKeeperWaitingInventory,
  DashboardKeeperBackgroundLoop,
  DashboardKeeperRecurringTask,
  DashboardKeeperBackgroundKeeper,
  DashboardKeeperBackground,
  DashboardToolsResponse,
  DashboardToolsRequestOptions,
  DashboardSkillReference,
  DashboardEffectiveKeeperSurface,
  DashboardSkillInstructionOrigin,
  DashboardSkillCompositionOrigin,
  DashboardSkillActivationInvocation,
  DashboardSkillActivation,
  DashboardSkillTransitionRejection,
  DashboardSkillActivationSummary,
  DashboardSkillScopedSummary,
  DashboardSkillActivationProjection,
  DashboardScheduleRunnerCounts,
  DashboardScheduleRunnerStatus,
  DashboardKeeperQueueStorageIntegrity,
  DashboardKeeperQueueWorkLiveness,
  DashboardKeeperEventQueueHealth,
} from './dashboard-tools-prompts'

export type {
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeResolution,
  ServerBuildIdentity as DashboardBuildIdentity,
} from '../types'
export type {
  KeeperRuntimeResolved,
  KeeperRuntimeField,
  KeeperRuntimeSource,
} from '../types'

export type {
  DashboardRuntimeProviderProbe,
  DashboardRuntimeProviderProbeSummary,
  DashboardRuntimeProbePayload,
  DashboardRuntimeProbeResponse,
  PromptSource,
  DashboardPromptItem,
  DashboardRuntimePromptAsset,
} from './dashboard-tools-prompts'
export {
  fetchToolMetrics,
  fetchDashboardRuntimeProbe,
  fetchDashboardFullHealth,
  fetchDashboardTools,
  fetchKeeperWaitingInventory,
  fetchDashboardPrompts,
  savePromptOverride,
  clearPromptOverride,
} from './dashboard-tools-prompts'

export type {
  SandboxProfile,
  SandboxNetworkMode,
  KeeperConfigUpdatePayload,
} from './dashboard-keeper-config'
export {
  fetchKeeperConfig,
  patchKeeperConfig,
} from './dashboard-keeper-config'

export type { TrajectoryEntry, TrajectoryResponse } from './dashboard-keeper-trajectory'
export { fetchKeeperTrajectory } from './dashboard-keeper-trajectory'

// ── Keeper tool stats (server-side aggregation) ──────────
export type { TelemetryFreshnessMetadata, DashboardSurfaceEnvelope, TelemetryCoverageGap } from './dashboard-shared'
export { decodeTelemetryFreshnessMetadata } from './dashboard-shared'
export type { ToolStat, HourlyBucket, ToolStatsResponse } from './dashboard-keeper-tool-stats'
export { fetchKeeperToolStats } from './dashboard-keeper-tool-stats'

// ── Keeper tool call log (full I/O) ──────────────────────
export type {
  ToolCallOutputBlob,
  ToolCallEntry,
  ToolCallsResponse,
  ToolCallPathResolution,
  ToolCallRuntimeContract,
  ToolCallActionRadius,
  ToolCallRouteEvidence,
} from './dashboard-keeper-tool-calls'
export { fetchKeeperToolCalls } from './dashboard-keeper-tool-calls'

// ── Keeper turn records (RFC-0233 PR-4) ─────────────────

export type {
  TurnPromptBlockId,
  TurnInputComponentId,
  TurnBlock,
  TurnInputComponent,
  TurnRecordEntry,
  TurnBlockDiff,
  TurnRecordRow,
  MemoryOsFactCategoryTag,
  MemoryOsFactCategory,
  MemoryOsDerivation,
  MemoryOsFactBasis,
  MemoryOsFact,
  MemoryOsUpdateSource,
  MemoryOsSupportInvalidation,
  MemoryOsTurnRecordSnapshot,
  TurnRecordsResponse,
  TurnTranscriptLine,
  TurnTranscript,
} from './dashboard-turn-records'
export {
  fetchKeeperTurnRecords,
  fetchKeeperTurnTranscript,
  parseMemoryOsFactCategory,
  isMemoryOsMemoryId,
} from './dashboard-turn-records'

export type {
  TelemetrySource,
  TelemetryEntry,
  TelemetryResponse,
  DashboardCacheEntryDetail,
  DashboardCacheStatsResponse,
  TelemetrySourceSummary,
  TelemetrySummaryResponse,
} from './dashboard-telemetry'
export {
  fetchTelemetry,
  fetchTelemetrySummary,
  fetchDashboardCacheStats,
} from './dashboard-telemetry'

export type {
  KeeperMemoryHealthAlert,
  KeeperMemoryHealthAlertCode,
  KeeperMemoryHealthAlertSeverity,
  KeeperMemoryHealthAlertTarget,
  KeeperMemoryHealthKeeperEntry,
  KeeperMemoryHealthResponse,
  VerificationRequest,
  VerificationRequestsResponse,
  TlaSpecCategory,
  TlaSpecEntry,
  TlaSpecsResponse,
  TlcResultStatus,
  TlcResultEntry,
  TlcResultsResponse,
  AuditEntry,
  AuditLedgerResponse,
  AuditLedgerParams,
} from './dashboard-misc'
export {
  fetchKeeperMemoryHealth,
  fetchVerificationRequests,
  fetchTlaSpecs,
  fetchTlcResults,
  fetchAuditLedger,
} from './dashboard-misc'
