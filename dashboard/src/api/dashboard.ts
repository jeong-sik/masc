// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import {
  type AgentTimelineEvent,
  type AgentTimelineResponse,
} from './schemas/agent-timeline'
import { type LogEntry, type LogsResponse } from './schemas/logs'
import {
  type RuntimeDefaultsResponse,
  type RuntimeEntry,
  type KeeperAssignment,
  type ModelRouting,
} from './schemas/runtime-defaults'
import {
  type ProviderLogCatalogEntry,
  type ProviderLogsCatalogResponse,
  type ProviderLogTailLine,
  type ProviderLogTailResponse,
} from './schemas/provider-logs'
export type {
  DashboardGoalsTreeResponse,
  DashboardGoalDetailResponse,
  GoalDetailKeeper,
  GoalKeeperTrustApprovalState,
  GoalKeeperTrustExecutionSummary,
  GoalKeeperTrustLatestEvent,
  GoalKeeperTrustSummary,
  GoalDetailTimelineEvent,
  GoalAttainmentProjection,
  GoalCompletionSummary,
  GoalTaskSummary,
  GoalTreeNode,
  GoalTreeSummary,
  GoalTreeTask,
  GoalVerificationRequest,
  GoalVerificationSummary,
  GoalVerificationVote,
} from '../types'
export { fetchDashboardGoalsTree, fetchDashboardGoalDetail } from './dashboard-goals'
export type {
  ConfigEntry,
  ConfigEntryProvenance,
  ConfigEntrySource,
  DashboardConfigResponse,
} from './schemas/dashboard-config'
export { reportToolHostFailure } from './tool-host-failure'
export { fetchDashboardBootstrap, fetchDashboardShell } from './dashboard-hot'
export type { FusionRunStatusLabel, FusionRunRecord, DashboardFusionRunsResponse } from './dashboard-fusion'
export { parseFusionRunsResponse, fetchFusionRuns } from './dashboard-fusion'

// --- Dashboard projections ---

export type { DashboardFeedRetention, DashboardFeedMetadata } from './dashboard-shared'
export { decodeDashboardFeedMetadata } from './dashboard-shared'

// --- System logs ---

export type { LogEntry, LogsResponse }
export type { RuntimeDefaultsResponse, RuntimeEntry, KeeperAssignment, ModelRouting }
export type {
  ProviderLogCatalogEntry,
  ProviderLogsCatalogResponse,
  ProviderLogTailLine,
  ProviderLogTailResponse,
}

export {
  fetchLogs,
  fetchProviderLogsCatalog,
  fetchProviderLogTail,
  fetchDashboardConfig,
  parseContextThresholds,
} from './dashboard-logs'

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

export type { DashboardScheduleDecision, DashboardScheduleResolveResponse } from './dashboard-governance'
export {
  fetchDashboardGovernance,
  resolveGovernanceApproval,
  deleteGovernanceApprovalRule,
  resolveScheduleApproval,
  fetchGovernanceCaseStatus,
  submitGovernancePetition,
  submitGovernanceCaseBrief,
  decideGovernanceExecutionOrder,
} from './dashboard-governance'
export { fetchDashboardBriefing, fetchDashboardMission, fetchDashboardMissionSession } from './dashboard-mission'

export type {
  DashboardRuntimeProviderSnapshot,
  DashboardRuntimeParameterPolicy,
  DashboardRuntimeEffectiveCapabilities,
  DashboardRuntimeReasoningStreamingFormat,
  DashboardRuntimeAssignment,
  DashboardRuntimeAssignmentGovernance,
  DashboardRuntimeProvidersResponse,
  BucketMetric,
  DashboardRuntimeModelMetric,
  LatencyBucket,
  DashboardRuntimeModelMetricsResponse,
  RuntimeTomlConfig,
  RuntimeRoutingLane,
} from './dashboard-runtime'
export {
  fetchRuntimeProviders,
  fetchRuntimeModelMetrics,
  fetchRuntimeTomlConfig,
  fetchRuntimeDefaults,
  saveRuntimeTomlConfig,
  patchRuntimeAssignment,
  patchRuntimeMediaFailover,
  patchRuntimeRouting,
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

export { fetchDashboardMissionBriefing, fetchDashboardPlanning } from './dashboard-mission'


export type {
  DashboardToolInventoryItem,
  ToolMetricsTopEntry,
  ToolMetricsResponse,
  DashboardScheduledAutomationFsm,
  DashboardScheduledAutomationExecution,
  DashboardScheduledAutomationKeeperToolStatus,
  DashboardScheduledAutomationActor,
  DashboardScheduledAutomationSignal,
  DashboardScheduledAutomationRequest,
  DashboardScheduledAutomationPayloadSupport,
  DashboardScheduledAutomation,
  DashboardToolsResponse,
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
} from './dashboard-tools-prompts'
export {
  fetchToolMetrics,
  fetchDashboardRuntimeProbe,
  fetchDashboardTools,
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
  setKeeperToolPolicy,
} from './dashboard-keeper-config'

export type { TrajectoryEntry, TrajectoryResponse } from './dashboard-keeper-trajectory'
export { fetchKeeperTrajectory } from './dashboard-keeper-trajectory'

// ── Keeper tool stats (server-side aggregation) ──────────
export type { TelemetryFreshnessMetadata, DashboardSurfaceEnvelope, TelemetryCoverageGap } from './dashboard-shared'
export { decodeTelemetryFreshnessMetadata } from './dashboard-shared'
export type { ToolStat, HourlyBucket, ToolStatsResponse } from './dashboard-keeper-tool-stats'
export { fetchKeeperToolStats } from './dashboard-keeper-tool-stats'

// ── Keeper tool call log (full I/O) ──────────────────────
export type { ToolCallOutputBlob, ToolCallEntry, ToolCallsResponse } from './dashboard-keeper-tool-calls'
export { fetchKeeperToolCalls } from './dashboard-keeper-tool-calls'

// ── Keeper turn records (RFC-0233 PR-4) ─────────────────

export type {
  TurnBlock,
  TurnRecordEntry,
  TurnBlockDiff,
  TurnRecordRow,
  MemoryOsEpisodeSummary,
  MemoryOsFactCategoryTag,
  MemoryOsFactCategory,
  MemoryOsClaimKind,
  MemoryOsFactProvenance,
  MemoryOsFact,
  MemoryOsSelectionPolicy,
  MemoryOsTurnRecordSnapshot,
  KeeperUserModelItem,
  KeeperUserModelSnapshot,
  TurnRecordsResponse,
  KeeperCompactionSnapshotLinks,
  KeeperCompactionSnapshot,
  KeeperCompactionSnapshotsResponse,
  TurnTranscriptLine,
  TurnTranscript,
} from './dashboard-turn-records'
export {
  MEMORY_OS_LIBRARIAN_UNSTRUCTURED_FALLBACK_MARKER,
  fetchKeeperTurnRecords,
  fetchKeeperCompactionSnapshots,
  fetchKeeperTurnTranscript,
  parseMemoryOsFactCategory,
  parseMemoryOsClaimKind,
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
  ExcusePattern,
  MemorySubsystemsSynapse,
  MemorySubsystemsEpisode,
  MemorySubsystemsMemoryEntry,
  MemorySubsystemsMemoryEntryError,
  MemorySubsystemsUserModelItem,
  MemorySubsystemsUserModelError,
  MemorySubsystemsUserModelPrompt,
  MemorySubsystemsDraftSkillCandidate,
  MemorySubsystemsDelegationRequest,
  MemorySubsystemsResponse,
  KeeperMemoryHealthAlert,
  KeeperMemoryHealthAlertCode,
  KeeperMemoryHealthAlertSeverity,
  KeeperMemoryHealthAlertTarget,
  KeeperMemoryHealthKeeperEntry,
  KeeperMemoryHealthResponse,
  VerificationRequestStatus,
  VerificationRequestVerdict,
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
  fetchExcusePatterns,
  updateExcusePatterns,
  fetchMemorySubsystems,
  fetchKeeperMemoryHealth,
  fetchVerificationRequests,
  resolveVerificationRequest,
  fetchTlaSpecs,
  fetchTlcResults,
  fetchAuditLedger,
} from './dashboard-misc'
