// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import { isRecord, asBoolean, asInt, asNullableString, asNumber, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import {
  asNullableIsoTimestamp,
  normalizeGovernanceDecisionItem,
  normalizeGovernanceTimelineEvent,
  normalizeGovernanceJudgeSummary,
  normalizeGovernanceJudgment,
  normalizeKeeperApprovalQueueItem,
} from './board'
import { normalizePendingConfirmation } from '../pending-confirm'
import { normalizeKeeperTrustTerminalReason } from '../keeper-store-normalize'
import { currentDashboardActor, get, post, withRetries, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { DEFAULT_WINDOW_MINUTES_24H } from '../config/constants'
import {
  parseAgentRelationsResponse,
  type AgentRelationsResponse,
} from './schemas/agent-relations'
import {
  parseAgentTimelineResponse,
  type AgentTimelineEvent,
  type AgentTimelineResponse,
} from './schemas/agent-timeline'
import {
  parseDashboardConfigResponse,
  type DashboardConfigResponse,
} from './schemas/dashboard-config'
import { parseLogsResponse, type LogEntry, type LogsResponse } from './schemas/logs'
import {
  parseRuntimeDefaultsResponse,
  type RuntimeDefaultsResponse,
  type RuntimeEntry,
  type KeeperAssignment,
  type ModelRouting,
} from './schemas/runtime-defaults'
import {
  parseProviderLogTailResponse,
  parseProviderLogsCatalogResponse,
  type ProviderLogCatalogEntry,
  type ProviderLogsCatalogResponse,
  type ProviderLogTailLine,
  type ProviderLogTailResponse,
} from './schemas/provider-logs'
import { asKeeperRuntimeBlockerClass } from '../lib/runtime-blocker-class'
import { asKeeperApprovalRiskLevel } from '../lib/governance-risk-level'
import type {
  KeeperConfig,
  KeeperFeatureStatus,
  KeeperHookSlot,
  DashboardExecutionResponse,
  DashboardGovernanceResponse,
  DashboardMemoryResponse,
  DashboardMissionBriefingResponse,
  DashboardMissionResponse,
  DashboardMissionSessionDetailResponse,
  DashboardPlanningResponse,
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
  BoardSortMode,
  GovernanceCaseBundle,
  GovernanceDecisionItem,
  GovernanceJudgment,
  KeeperApprovalRule,
  KeeperApprovalQueueItem,
  GovernanceTimelineEvent,
  PendingConfirmation,
  DashboardConfigResolution,
  DashboardRuntimeResolution,
} from '../types'
export { DashboardConfigSchemaDriftError } from './schemas/dashboard-config'
export type {
  ConfigEntry,
  ConfigEntryProvenance,
  ConfigEntrySource,
  DashboardConfigResponse,
} from './schemas/dashboard-config'
export { reportToolHostFailure } from './tool-host-failure'
export { fetchDashboardBootstrap, fetchDashboardShell } from './dashboard-hot'

// --- Dashboard projections ---

export type DashboardFeedRetention = Record<string, unknown> & {
  scope?: string
  durable_store?: string
  durable_replay_surface?: string
}

export type DashboardFeedMetadata = {
  generated_at_iso?: string
  dashboard_surface?: string
  source?: string
  retention?: DashboardFeedRetention
}

function decodeDashboardFeedMetadata(raw: Record<string, unknown>): DashboardFeedMetadata {
  return {
    generated_at_iso: asString(raw.generated_at_iso),
    dashboard_surface: asString(raw.dashboard_surface),
    source: asString(raw.source),
    retention: isRecord(raw.retention) ? raw.retention : undefined,
  }
}

// --- System logs ---

export type { LogEntry, LogsResponse }
export { LogsSchemaDriftError } from './schemas/logs'
export { RuntimeDefaultsSchemaDriftError } from './schemas/runtime-defaults'
export type { RuntimeDefaultsResponse, RuntimeEntry, KeeperAssignment, ModelRouting }
export type {
  ProviderLogCatalogEntry,
  ProviderLogsCatalogResponse,
  ProviderLogTailLine,
  ProviderLogTailResponse,
}
export { ProviderLogsSchemaDriftError } from './schemas/provider-logs'

export async function fetchLogs(opts?: {
  limit?: number
  level?: string
  module?: string
  since_seq?: number
  before_seq?: number
  category?: string
  exclude_category?: string
}): Promise<LogsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit) params.set('limit', String(opts.limit))
  if (opts?.level) params.set('level', opts.level)
  if (opts?.module) params.set('module', opts.module)
  if (typeof opts?.since_seq === 'number' && opts.since_seq >= 0) {
    params.set('since_seq', String(opts.since_seq))
  }
  if (typeof opts?.before_seq === 'number' && opts.before_seq >= 0) {
    params.set('before_seq', String(opts.before_seq))
  }
  if (opts?.category) params.set('category', opts.category)
  if (opts?.exclude_category) params.set('exclude_category', opts.exclude_category)
  const qs = params.toString()
  const raw = await get<unknown>(`/api/v1/dashboard/logs${qs ? `?${qs}` : ''}`)
  return parseLogsResponse(raw)
}

export async function fetchProviderLogsCatalog(): Promise<ProviderLogsCatalogResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/provider-logs')
  return parseProviderLogsCatalogResponse(raw)
}

export async function fetchProviderLogTail(
  provider: string,
  opts?: { lines?: number },
): Promise<ProviderLogTailResponse> {
  const params = new URLSearchParams()
  params.set('provider', provider)
  if (opts?.lines) params.set('lines', String(opts.lines))
  const raw = await get<unknown>(`/api/v1/dashboard/provider-logs/tail?${params.toString()}`)
  return parseProviderLogTailResponse(raw)
}

export type { AgentTimelineEvent, AgentTimelineResponse }
export { AgentTimelineSchemaDriftError } from './schemas/agent-timeline'

export async function fetchAgentTimeline(
  agentName: string,
  sinceHours = 4,
  limit = 20,
): Promise<AgentTimelineResponse> {
  const raw = await get<unknown>(
    `/api/v1/agent-timeline?agent_name=${encodeURIComponent(agentName)}&since_hours=${sinceHours}&limit=${limit}`,
  )
  return parseAgentTimelineResponse(raw)
}

export type {
  AgentRelation,
  AgentRelationsResponse,
} from './schemas/agent-relations'
export { AgentRelationsSchemaDriftError } from './schemas/agent-relations'

export async function fetchAgentRelations(agentName: string): Promise<AgentRelationsResponse> {
  const raw = await get<unknown>(`/api/v1/agent-relations?agent_name=${encodeURIComponent(agentName)}`)
  return parseAgentRelationsResponse(raw)
}

export async function fetchDashboardConfig(): Promise<DashboardConfigResponse> {
  await ensureDevToken()
  return get<unknown>('/api/v1/dashboard/config').then(parseDashboardConfigResponse)
}

/** Parse runtime context-ratio thresholds from the dashboard config response.
    Falls back to the compiled defaults when keys are missing or malformed. */
export function parseContextThresholds(
  data: DashboardConfigResponse,
  defaults: { critical: number; warn: number; compacting: number },
): { critical: number; warn: number; compacting: number } {
  const cat = data.categories.dashboard ?? []
  const find = (env: string): number | null => {
    const entry = cat.find(e => e.env === env)
    if (!entry || entry.value == null) return null
    const n = parseFloat(entry.value)
    return Number.isFinite(n) ? n : null
  }
  return {
    critical: find('MASC_DASHBOARD_CTX_HANDOFF_IMMINENT') ?? defaults.critical,
    warn: find('MASC_DASHBOARD_CTX_PREPARING') ?? defaults.warn,
    compacting: find('MASC_DASHBOARD_CTX_COMPACTING') ?? defaults.compacting,
  }
}

// Re-export from the hot-path API barrel where the SSOT definition lives
// alongside `fetchDashboardShell` / `fetchDashboardBootstrap` (all three
// share the same hot/bootstrap consumer profile). Until 2026-05-27 the
// implementation was duplicated here verbatim, with `namespace-truth-actions`
// importing the hot variant and `telemetry-unified` / `fleet-telemetry-panel`
// the dashboard.ts variant — same endpoint, same timeout, two definitions
// that could drift independently. SSOT now lives in `./dashboard-hot`.
export { fetchDashboardNamespaceTruth } from './dashboard-hot'

// --- RFC-0266 §7 Phase 4: fusion run registry (in-progress + recent) ---

/** Status of a tracked fusion deliberation, mirroring the backend
    Fusion_run_registry.status_label vocabulary: a run is `running`, or finished
    `completed` (judge ok) / `failed` (denied / sink-failed / aborted). */
export type FusionRunStatusLabel = 'running' | 'completed' | 'failed'

/** One row of the fusion run registry from GET /api/v1/dashboard/fusion-runs.
    The registry tracks what the board-post view cannot: an in-progress
    deliberation has no board post yet, so only the registry shows it as
    `running`. Distinct from `FusionRunView` (board-meta-derived detail). */
export interface FusionRunRecord {
  runId: string
  keeper: string
  preset: string
  startedAt: number // unix seconds
  status: FusionRunStatusLabel
}

export interface DashboardFusionRunsResponse {
  runs: FusionRunRecord[]
  count: number
  generatedAt: string | null
}

// The backend emits a closed three-label enum, so an unrecognized value can only
// come from a protocol break. Map it to `failed` (conservative: never let a
// garbled row pose as a healthy `completed` or an active `running`) rather than
// to a convenient default — see CLAUDE.md "Unknown → Permissive Default".
function asFusionRunStatus(value: unknown): FusionRunStatusLabel {
  return value === 'running' || value === 'completed' || value === 'failed' ? value : 'failed'
}

export function parseFusionRunsResponse(raw: unknown): DashboardFusionRunsResponse {
  const root = isRecord(raw) ? raw : {}
  const runs: FusionRunRecord[] = asRecordArray(root.runs)
    .map(row => ({
      runId: asString(row.run_id) ?? '',
      keeper: asString(row.keeper) ?? '',
      preset: asString(row.preset) ?? '',
      startedAt: asNumber(row.started_at) ?? 0,
      status: asFusionRunStatus(row.status),
    }))
    .filter(run => run.runId.length > 0)
  return {
    runs,
    count: asInt(root.count) ?? runs.length,
    generatedAt: asString(root.generated_at) ?? null,
  }
}

export async function fetchFusionRuns(
  opts?: AbortableRequestOptions,
): Promise<DashboardFusionRunsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/fusion-runs', { signal: opts?.signal })
  return parseFusionRunsResponse(raw)
}

type DashboardExecutionRequestOptions = AbortableRequestOptions & {
  force?: boolean
}

export function fetchDashboardExecution(opts?: DashboardExecutionRequestOptions): Promise<DashboardExecutionResponse> {
  const query = opts?.force ? '?force=1' : ''
  return get(`/api/v1/dashboard/execution${query}`, { signal: opts?.signal })
}

export type DashboardExecutionTrustKeeper = Record<string, unknown> & {
  name?: string
  agent_name?: string | null
  keeper_id?: string | null
  phase?: string | null
  pipeline_stage?: string | null
  status?: string | null
  trace_id?: string | null
  trust?: unknown
}

export type DashboardExecutionTrustResponse = TelemetryFreshnessMetadata & {
  generated_at?: string
  total: number
  keepers: DashboardExecutionTrustKeeper[]
}

export function fetchDashboardExecutionTrust(opts?: AbortableRequestOptions): Promise<DashboardExecutionTrustResponse> {
  return get<DashboardExecutionTrustResponse>('/api/v1/dashboard/execution-trust', { signal: opts?.signal })
}

type ToolQualityToolStat = {
  name: string
  calls: number
  success_pct: number
  avg_ms: number
  output_truncated_count?: number
  avg_output_chars?: number
}

type ToolQualityKeeperStat = {
  name: string
  calls: number
  success_pct: number
}

type ToolQualityFailureCategory = {
  category: string
  count: number
}

export type ToolQualityHourlyPoint = {
  hour: string
  calls: number
  success: number
  success_rate: number
}

export type ToolQualityResponse = TelemetryFreshnessMetadata & {
  generated_at?: string
  sampling_mode?: 'recent_n' | 'window_hours' | string
  sample_limit?: number | null
  window_hours?: number | null
  total: number
  success: number
  failure: number
  success_rate: number
  by_tool: ToolQualityToolStat[]
  by_keeper: ToolQualityKeeperStat[]
  by_runtime?: ToolQualityKeeperStat[]
  failure_categories: ToolQualityFailureCategory[]
  hourly_trend?: ToolQualityHourlyPoint[]
}

export function fetchToolQuality(opts?: { n?: number; windowHours?: number; signal?: AbortSignal }): Promise<ToolQualityResponse> {
  const params = new URLSearchParams()
  if (opts?.n != null) params.set('n', String(opts.n))
  if (opts?.windowHours != null) params.set('window_hours', String(opts.windowHours))
  const qs = params.toString()
  return get<ToolQualityResponse>(`/api/v1/dashboard/tool-quality${qs ? `?${qs}` : ''}`, { signal: opts?.signal })
}

export interface DashboardPerfRow {
  benchmark: string
  avg_ms: number
  p50_ms: number
  p95_ms: number
  max_ms: number
  notes: string
  note_tags?: Record<string, string>
}

export interface DashboardPerfComparisonRow {
  benchmark: string
  avg_delta_ms: number
  avg_delta_pct?: number | null
  p95_delta_ms: number
  p95_delta_pct?: number | null
  max_delta_ms: number
  verdict: 'improved' | 'stable' | 'mixed' | 'regressed' | string
}

export interface DashboardPerfResponse {
  generated_at?: string
  status: 'ok' | 'empty' | string
  message?: string
  candidate_dirs?: string[]
  source?: {
    results_dir: string
    result_file: string
    meta_file?: string | null
    baseline_file?: string | null
  }
  latest_run?: {
    timestamp?: string | null
    started_at?: string | null
    pattern?: string | null
    iterations?: number | null
    warmup_iterations?: number | null
    session_warmup_iterations?: number | null
    benchmark_count?: number
  }
  highlights?: {
    session_init?: DashboardPerfRow | null
    worst_live_mcp?: DashboardPerfRow | null
    runtime_status?: DashboardPerfRow | null
    runtime_single?: DashboardPerfRow | null
  }
  benchmarks: DashboardPerfRow[]
  comparison?: {
    baseline_file?: string | null
    verdict_counts?: {
      improved?: number
      stable?: number
      mixed?: number
      regressed?: number
    }
    top_changes?: DashboardPerfComparisonRow[]
  } | null
}

export function fetchDashboardPerf(): Promise<DashboardPerfResponse> {
  return get('/api/v1/dashboard/perf')
}

interface FetchDashboardMemoryOptions {
  excludeSystem?: boolean
  excludeAutomation?: boolean
  author?: string
  hearth?: string
  /** Page size. Defaults to 200 when any filter is active, else 100. */
  limit?: number
  /** Number of posts to skip from the start of the sorted list. Defaults to 0. */
  offset?: number
}

export function fetchDashboardMemory(
  sortMode: BoardSortMode,
  opts?: FetchDashboardMemoryOptions,
): Promise<DashboardMemoryResponse> {
  const params = new URLSearchParams()
  params.set('sort_by', sortMode)
  const hasFilter = opts?.excludeSystem || opts?.excludeAutomation || opts?.author || opts?.hearth
  const defaultLimit = hasFilter ? 200 : 100
  const limit = Math.max(1, Math.min(500, opts?.limit ?? defaultLimit))
  const offset = Math.max(0, Math.min(5000, opts?.offset ?? 0))
  params.set('limit', String(limit))
  if (offset > 0) params.set('offset', String(offset))
  params.set('voter', currentDashboardActor())
  params.set('blind_votes', 'true')
  if (opts?.excludeSystem) params.set('exclude_system', 'true')
  if (opts?.excludeAutomation) params.set('exclude_automation', 'true')
  if (opts?.author) params.set('author', opts.author)
  if (opts?.hearth) params.set('hearth', opts.hearth)
  return get(`/api/v1/dashboard/board${params.toString() ? `?${params}` : ''}`)
}

function normalizeKeeperApprovalRule(raw: unknown): KeeperApprovalRule | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const keeperName = asString(raw.keeper_name, '').trim()
  const toolName = asString(raw.tool_name, '').trim()
  if (!id || !keeperName || !toolName) return null
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    sandbox_profile: asNullableString(raw.sandbox_profile),
    backend: asNullableString(raw.backend),
    request_fingerprint: asNullableString(raw.request_fingerprint) ?? undefined,
    request_fingerprint_preview:
      asNullableString(raw.request_fingerprint_preview) ?? undefined,
    max_risk: asKeeperApprovalRiskLevel(raw.max_risk) ?? undefined,
    created_at: asNullableIsoTimestamp(raw.created_at_iso ?? raw.created_at),
    created_by: asNullableString(raw.created_by),
    last_matched_at:
      asNullableIsoTimestamp(raw.last_matched_at_iso ?? raw.last_matched_at),
    match_count: asInt(raw.match_count) ?? undefined,
    source_approval_id: asNullableString(raw.source_approval_id),
  }
}

function normalizeHitlStatus(raw: unknown): DashboardGovernanceResponse['hitl'] | undefined {
  if (!isRecord(raw)) return undefined
  return {
    enabled: asBoolean(raw.enabled) ?? false,
    disabled_by_env: asBoolean(raw.disabled_by_env) ?? false,
    env_name: asString(raw.env_name, 'MASC_DISABLE_HITL'),
    default_enabled: asBoolean(raw.default_enabled) ?? true,
  }
}

export function fetchDashboardGovernance(): Promise<DashboardGovernanceResponse> {
  return withRetries('fetchDashboardGovernance', async () => {
    const raw = await get<Record<string, unknown>>('/api/v1/dashboard/governance')
    const items = Array.isArray(raw.items)
      ? raw.items
          .map(item => normalizeGovernanceDecisionItem(item))
          .filter((item): item is GovernanceDecisionItem => item !== null)
      : []
    const pendingActions = Array.isArray(raw.pending_actions)
      ? raw.pending_actions
          .map(item => normalizePendingConfirmation(item))
          .filter((item): item is PendingConfirmation => item !== null)
      : []
    const approvalQueue = Array.isArray(raw.approval_queue)
      ? raw.approval_queue
          .map(item => normalizeKeeperApprovalQueueItem(item))
          .filter((item): item is KeeperApprovalQueueItem => item !== null)
      : []
    const approvalRules = Array.isArray(raw.approval_rules)
      ? raw.approval_rules
          .map(item => normalizeKeeperApprovalRule(item))
          .filter((item): item is KeeperApprovalRule => item !== null)
      : []
    return {
      generated_at: asNullableIsoTimestamp(raw.generated_at) ?? undefined,
      note: typeof raw.note === 'string' && raw.note.trim() !== '' ? raw.note.trim() : undefined,
      summary: isRecord(raw.summary)
        ? {
            cases_open: asInt(raw.summary.cases_open) ?? undefined,
            pending_ruling: asInt(raw.summary.pending_ruling) ?? undefined,
            ready_auto_execute: asInt(raw.summary.ready_auto_execute) ?? undefined,
            needs_human_gate: asInt(raw.summary.needs_human_gate) ?? undefined,
            executed: asInt(raw.summary.executed) ?? undefined,
            blocked: asInt(raw.summary.blocked) ?? undefined,
            ready_to_execute: asInt(raw.summary.ready_to_execute) ?? undefined,
            oldest_open_case_age_s:
              typeof raw.summary.oldest_open_case_age_s === 'number'
                ? raw.summary.oldest_open_case_age_s
                : null,
            last_activity_age_s:
              typeof raw.summary.last_activity_age_s === 'number'
                ? raw.summary.last_activity_age_s
                : null,
            judge_online:
              typeof raw.summary.judge_online === 'boolean'
                ? raw.summary.judge_online
                : undefined,
            judge_last_seen_at: asNullableIsoTimestamp(raw.summary.judge_last_seen_at),
          }
        : undefined,
      items,
      activity: Array.isArray(raw.activity)
        ? raw.activity
            .map(item => normalizeGovernanceTimelineEvent(item))
            .filter((item): item is GovernanceTimelineEvent => item !== null)
        : [],
      judge: normalizeGovernanceJudgeSummary(raw.judge),
      judgments: Array.isArray(raw.judgments)
        ? raw.judgments
            .map(item => normalizeGovernanceJudgment(item))
            .filter((item): item is GovernanceJudgment => item !== null)
        : [],
      pending_actions: pendingActions,
      approval_queue: approvalQueue,
      approval_rules: approvalRules,
      hitl: normalizeHitlStatus(raw.hitl),
    }
  })
}

export function resolveGovernanceApproval(
  id: string,
  decision: 'approve' | 'reject',
  rememberRule?: boolean,
  reason?: string,
): Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject'; rule_id?: string | null }> {
  return post('/api/v1/dashboard/governance/approvals/resolve', {
    id,
    decision,
    remember_rule: rememberRule,
    reason,
  })
}

export function deleteGovernanceApprovalRule(
  id: string,
): Promise<{ ok: boolean; id: string }> {
  return post('/api/v1/dashboard/governance/approvals/rules/delete', { id })
}

export type DashboardScheduleDecision = 'approve' | 'reject'

export interface DashboardScheduleResolveResponse {
  ok: boolean
  schedule_id: string
  decision: DashboardScheduleDecision
  approved_by?: unknown
  schedule?: unknown
}

export function resolveScheduleApproval(
  scheduleId: string,
  decision: DashboardScheduleDecision,
  reason?: string,
): Promise<DashboardScheduleResolveResponse> {
  return post('/api/v1/dashboard/schedule/resolve', {
    schedule_id: scheduleId,
    decision,
    reason,
  })
}

export function fetchGovernanceCaseStatus(caseId: string): Promise<GovernanceCaseBundle> {
  return get(`/api/v1/governance/cases/${encodeURIComponent(caseId)}`)
}

function governanceCasesRetiredError(): Error {
  return new Error('Governance case write APIs are retired; use live judge and HITL approvals instead.')
}

export async function submitGovernancePetition(_title: string): Promise<{ case: { id: string } }> {
  throw governanceCasesRetiredError()
}

export async function submitGovernanceCaseBrief(
  _caseId: string,
  _stance: 'support' | 'oppose' | 'neutral',
  _summary: string,
): Promise<GovernanceCaseBundle> {
  throw governanceCasesRetiredError()
}

export async function decideGovernanceExecutionOrder(
  _caseId: string,
  _decision: 'confirm' | 'deny',
): Promise<void> {
  throw governanceCasesRetiredError()
}

export function fetchDashboardBriefing(): Promise<DashboardMissionResponse> {
  return get('/api/v1/dashboard/briefing')
}

export function fetchDashboardMission(): Promise<DashboardMissionResponse> {
  return fetchDashboardBriefing()
}

export function fetchDashboardMissionSession(
  sessionId: string,
  opts?: { signal?: AbortSignal },
): Promise<DashboardMissionSessionDetailResponse> {
  const query = `?session_id=${encodeURIComponent(sessionId)}`
  return get(`/api/v1/dashboard/session${query}`, { signal: opts?.signal })
}

interface DashboardRuntimeProviderDiscovery {
  healthy?: boolean
  discovered_model?: string | null
  ctx_size?: number | null
  total_slots?: number | null
  busy_slots?: number | null
  idle_slots?: number | null
}

export interface DashboardRuntimeProviderSnapshot {
  provider: string
  runtime_id?: string | null
  provider_id?: string | null
  provider_display_name?: string | null
  model_id?: string | null
  model_api_name?: string | null
  protocol?: string | null
  transport?: string | null
  kind?: string | null
  runtime_kind?: string | null
  auth_kind?: string | null
  status?: string | null
  available?: boolean
  is_default_runtime?: boolean
  max_context?: number | null
  tools_support?: boolean
  thinking_support?: boolean
  streaming?: boolean
  model_count?: number | null
  models: string[]
  source?: string | null
  endpoint_url?: string | null
  note?: string | null
  discovery?: DashboardRuntimeProviderDiscovery | null
}

export interface DashboardRuntimeAssignment {
  keeper: string
  runtime_id: string
  matches_default?: boolean
}

export interface DashboardRuntimeAssignmentGovernance {
  schema?: string | null
  source?: string | null
  status?: string | null
  degraded: boolean
  operator_action_required: boolean
  blast_radius?: string | null
  assignment_count: number
  assigned_runtime_count: number
  default_assignment_count: number
  default_runtime_id?: string | null
  librarian_runtime_id?: string | null
  warnings: string[]
  assigned_runtimes: string[]
  assignments: DashboardRuntimeAssignment[]
}

export interface DashboardRuntimeProvidersResponse {
  updated_at?: string
  summary?: {
    providers?: number
    runtimes?: number
    local_models?: number
    cloud_models?: number
    cli_models?: number
    default_runtime_id?: string | null
  } | null
  providers: DashboardRuntimeProviderSnapshot[]
  assignment_governance?: DashboardRuntimeAssignmentGovernance | null
  // Resolved filesystem path of the runtime.toml the server actually loaded
  // (Runtime.config_path); answers "which config is live" in the monitor.
  config_path?: string | null
}

export interface BucketMetric {
  ts_start: number
  entry_count: number
  success_count: number
  error_count: number
  p50_latency_ms: number | null
  p95_latency_ms: number | null
  error_rate: number
  total_cost_usd: number | null
  cache_hit_ratio: number | null
}

export interface DashboardRuntimeModelMetric {
  model_id: string
  provider?: string | null
  entry_count?: number | null
  avg_tok_per_sec?: number | null
  p50_tok_per_sec?: number | null
  p95_tok_per_sec?: number | null
  prompt_avg_tok_per_sec?: number | null
  prompt_p50_tok_per_sec?: number | null
  prompt_p95_tok_per_sec?: number | null
  /**
   * Hardware decode rate (eval_count / eval_duration from Ollama) aggregated
   * across the telemetry window. Distinct from `avg_tok_per_sec` which is
   * wall-clock (includes queue wait + prefill + thinking in the denominator).
   * Null when no entry in the window carried timings (non-Ollama providers or
   * legacy rows before OAS started emitting inference_timings).
   */
  hw_decode_avg_tok_per_sec?: number | null
  hw_decode_p50_tok_per_sec?: number | null
  hw_decode_p95_tok_per_sec?: number | null
  max_peak_memory_gb?: number | null
  /**
   * Fraction [0.0, 1.0] of turns in the window where the model received
   * think=true. Null when no entry in the window reported thinking_enabled
   * (older rows or providers that don't expose the field).
   */
  thinking_fraction?: number | null
  avg_latency_ms?: number | null
  p50_latency_ms?: number | null
  p95_latency_ms?: number | null
  total_input_tokens?: number | null
  total_output_tokens?: number | null
  total_cache_read_tokens?: number | null
  total_cache_creation_tokens?: number | null
  total_reasoning_tokens?: number | null
  usage_sample_count?: number | null
  telemetry_sample_count?: number | null
  usage_missing_count?: number | null
  telemetry_missing_count?: number | null
  coverage_status?: 'full' | 'partial' | 'none' | 'error_only' | null
  primary_coverage_stage?: string | null
  primary_coverage_reason?: string | null
  coverage_reason_counts?: Array<{ reason: string; count: number }> | null
  fallback_count?: number | null
  success_count?: number | null
  error_count?: number | null
  total_cost_usd?: number | null
  avg_tool_calls_per_turn?: number | null
  total_tool_calls?: number | null
  top_tools?: Array<{ tool: string; count: number }> | null
  recent_entries?: Array<{
    ts_unix: number
    outcome?: string | null
    stop_reason?: string | null
    turn_lane?: string | null
    input_tokens: number | null
    output_tokens: number | null
    latency_ms: number | null
    prompt_tok_per_sec?: number | null
    peak_memory_gb?: number | null
    cost_usd: number | null
    tools_count: number
    usage_reported?: boolean | null
    telemetry_reported?: boolean | null
    usage_trust?: string | null
    usage_anomaly_reasons?: string[] | null
    coverage_reason?: string | null
    coverage_stage?: string | null
    streaming_ttfrc_ms?: number | null
    streaming_inter_chunk_count?: number | null
    streaming_inter_chunk_avg_ms?: number | null
  }> | null
  buckets?: BucketMetric[] | null
}

export interface LatencyBucket {
  lo_ms: number
  hi_ms: number | null
  count: number
}

export interface DashboardRuntimeModelMetricsResponse {
  window_minutes?: number
  bucket_minutes?: number
  total_entries?: number
  total_error_entries?: number
  latency_buckets?: LatencyBucket[] | null
  models: DashboardRuntimeModelMetric[]
}

function runtimeLaneLabel(index: number): string {
  return `runtime_lane_${index + 1}`
}

function decodeRuntimeProviderDiscovery(raw: unknown): DashboardRuntimeProviderDiscovery | null {
  if (!isRecord(raw)) return null
  return {
    healthy: asBoolean(raw.healthy),
    discovered_model: null,
    ctx_size: asNumber(raw.ctx_size) ?? null,
    total_slots: asNumber(raw.total_slots) ?? null,
    busy_slots: asNumber(raw.busy_slots) ?? null,
    idle_slots: asNumber(raw.idle_slots) ?? null,
  }
}

function decodeRuntimeProviderSnapshot(raw: unknown): DashboardRuntimeProviderSnapshot | null {
  if (!isRecord(raw)) return null
  const provider = asString(raw.provider)
  if (!provider) return null
  return {
    provider,
    runtime_id: asNullableString(raw.runtime_id),
    provider_id: asNullableString(raw.provider_id),
    provider_display_name: asNullableString(raw.provider_display_name),
    model_id: asNullableString(raw.model_id),
    model_api_name: asNullableString(raw.model_api_name),
    protocol: asNullableString(raw.protocol),
    transport: asNullableString(raw.transport),
    kind: asNullableString(raw.kind),
    runtime_kind: asNullableString(raw.runtime_kind),
    auth_kind: asNullableString(raw.auth_kind),
    status: asNullableString(raw.status),
    available: asBoolean(raw.available),
    is_default_runtime: asBoolean(raw.is_default_runtime),
    max_context: asNumber(raw.max_context) ?? null,
    tools_support: asBoolean(raw.tools_support),
    thinking_support: asBoolean(raw.thinking_support),
    streaming: asBoolean(raw.streaming),
    model_count: asNumber(raw.model_count) ?? null,
    models: asStringArray(raw.models),
    source: asNullableString(raw.source),
    endpoint_url: asNullableString(raw.endpoint_url),
    note: asNullableString(raw.note),
    discovery: decodeRuntimeProviderDiscovery(raw.discovery),
  }
}

function decodeRuntimeAssignment(raw: unknown): DashboardRuntimeAssignment | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const runtimeId = asString(raw.runtime_id)
  if (!keeper || !runtimeId) return null
  return {
    keeper,
    runtime_id: runtimeId,
    matches_default: asBoolean(raw.matches_default),
  }
}

function decodeRuntimeAssignmentGovernance(raw: unknown): DashboardRuntimeAssignmentGovernance | null {
  if (!isRecord(raw)) return null
  return {
    schema: asNullableString(raw.schema),
    source: asNullableString(raw.source),
    status: asNullableString(raw.status),
    degraded: asBoolean(raw.degraded) ?? false,
    operator_action_required: asBoolean(raw.operator_action_required) ?? false,
    blast_radius: asNullableString(raw.blast_radius),
    assignment_count: asNumber(raw.assignment_count) ?? 0,
    assigned_runtime_count: asNumber(raw.assigned_runtime_count) ?? 0,
    default_assignment_count: asNumber(raw.default_assignment_count) ?? 0,
    default_runtime_id: asNullableString(raw.default_runtime_id),
    librarian_runtime_id: asNullableString(raw.librarian_runtime_id),
    warnings: asStringArray(raw.warnings),
    assigned_runtimes: asStringArray(raw.assigned_runtimes),
    assignments: asRecordArray(raw.assignments)
      .map(decodeRuntimeAssignment)
      .filter((item): item is DashboardRuntimeAssignment => item !== null),
  }
}

function decodeRuntimeProvidersResponse(raw: unknown): DashboardRuntimeProvidersResponse | null {
  if (!isRecord(raw)) return null
  const summary = isRecord(raw.summary) ? raw.summary : null
  return {
    updated_at: asString(raw.updated_at),
    summary: summary
      ? {
          providers: asNumber(summary.providers),
          runtimes: asNumber(summary.runtimes),
          local_models: asNumber(summary.local_models),
          cloud_models: asNumber(summary.cloud_models),
          cli_models: asNumber(summary.cli_models),
          default_runtime_id: asNullableString(summary.default_runtime_id),
        }
      : null,
    providers: asRecordArray(raw.providers)
      .map(decodeRuntimeProviderSnapshot)
      .filter((provider): provider is DashboardRuntimeProviderSnapshot => provider !== null),
    assignment_governance: decodeRuntimeAssignmentGovernance(raw.assignment_governance),
    config_path: asNullableString(raw.config_path),
  }
}

function decodeRuntimeModelMetric(raw: unknown): DashboardRuntimeModelMetric | null {
  if (!isRecord(raw)) return null
  const modelId = asString(raw.model_id)
  if (!modelId) return null
  return {
    model_id: modelId,
    provider: null,
    entry_count: asNumber(raw.entry_count) ?? null,
    avg_tok_per_sec: asNumber(raw.avg_tok_per_sec) ?? null,
    p50_tok_per_sec: asNumber(raw.p50_tok_per_sec) ?? null,
    p95_tok_per_sec: asNumber(raw.p95_tok_per_sec) ?? null,
    prompt_avg_tok_per_sec: asNumber(raw.prompt_avg_tok_per_sec) ?? null,
    prompt_p50_tok_per_sec: asNumber(raw.prompt_p50_tok_per_sec) ?? null,
    prompt_p95_tok_per_sec: asNumber(raw.prompt_p95_tok_per_sec) ?? null,
    hw_decode_avg_tok_per_sec: asNumber(raw.hw_decode_avg_tok_per_sec) ?? null,
    hw_decode_p50_tok_per_sec: asNumber(raw.hw_decode_p50_tok_per_sec) ?? null,
    hw_decode_p95_tok_per_sec: asNumber(raw.hw_decode_p95_tok_per_sec) ?? null,
    max_peak_memory_gb: asNumber(raw.max_peak_memory_gb) ?? null,
    thinking_fraction: asNumber(raw.thinking_fraction) ?? null,
    avg_latency_ms: asNumber(raw.avg_latency_ms) ?? null,
    p50_latency_ms: asNumber(raw.p50_latency_ms) ?? null,
    p95_latency_ms: asNumber(raw.p95_latency_ms) ?? null,
    total_input_tokens: asNumber(raw.total_input_tokens) ?? null,
    total_output_tokens: asNumber(raw.total_output_tokens) ?? null,
    total_cache_read_tokens: asNumber(raw.total_cache_read_tokens) ?? null,
    total_cache_creation_tokens: asNumber(raw.total_cache_creation_tokens) ?? null,
    total_reasoning_tokens: asNumber(raw.total_reasoning_tokens) ?? null,
    usage_sample_count: asNumber(raw.usage_sample_count) ?? null,
    telemetry_sample_count: asNumber(raw.telemetry_sample_count) ?? null,
    usage_missing_count: asNumber(raw.usage_missing_count) ?? null,
    telemetry_missing_count: asNumber(raw.telemetry_missing_count) ?? null,
    coverage_status: asNullableString(raw.coverage_status) as DashboardRuntimeModelMetric['coverage_status'],
    primary_coverage_stage: asNullableString(raw.primary_coverage_stage),
    primary_coverage_reason: asNullableString(raw.primary_coverage_reason),
    coverage_reason_counts: Array.isArray(raw.coverage_reason_counts)
      ? (raw.coverage_reason_counts as unknown[])
          .filter(isRecord)
          .map(item => ({ reason: asString(item.reason) ?? '', count: asNumber(item.count) ?? 0 }))
          .filter(item => item.reason.length > 0)
      : null,
    fallback_count: asNumber(raw.fallback_count) ?? null,
    success_count: asNumber(raw.success_count) ?? null,
    error_count: asNumber(raw.error_count) ?? null,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? null,
    avg_tool_calls_per_turn: asNumber(raw.avg_tool_calls_per_turn) ?? null,
    total_tool_calls: asNumber(raw.total_tool_calls) ?? null,
    top_tools: Array.isArray(raw.top_tools)
      ? (raw.top_tools as unknown[])
          .filter(isRecord)
          .map(t => ({ tool: asString(t.tool) ?? '', count: asNumber(t.count) ?? 0 }))
          .filter(t => t.tool.length > 0)
      : null,
    recent_entries: Array.isArray(raw.recent_entries)
      ? (raw.recent_entries as unknown[])
          .filter(isRecord)
          .map(r => ({
            ts_unix: asNumber(r.ts_unix) ?? 0,
            outcome: asNullableString(r.outcome),
            stop_reason: asNullableString(r.stop_reason),
            turn_lane: asNullableString(r.turn_lane),
            input_tokens: asNumber(r.input_tokens) ?? null,
            output_tokens: asNumber(r.output_tokens) ?? null,
            latency_ms: asNumber(r.latency_ms) ?? null,
            prompt_tok_per_sec: asNumber(r.prompt_tok_per_sec) ?? null,
            peak_memory_gb: asNumber(r.peak_memory_gb) ?? null,
            cost_usd: asNumber(r.cost_usd) ?? null,
            tools_count: asNumber(r.tools_count) ?? 0,
            usage_reported: asBoolean(r.usage_reported),
            telemetry_reported: asBoolean(r.telemetry_reported),
            usage_trust: asNullableString(r.usage_trust),
            usage_anomaly_reasons: Array.isArray(r.usage_anomaly_reasons)
              ? (r.usage_anomaly_reasons as unknown[])
                  .map(item => asString(item) ?? '')
                  .filter(item => item.length > 0)
              : null,
            coverage_reason: asNullableString(r.coverage_reason),
            coverage_stage: asNullableString(r.coverage_stage),
            streaming_ttfrc_ms: asNumber(r.streaming_ttfrc_ms) ?? null,
            streaming_inter_chunk_count: asNumber(r.streaming_inter_chunk_count) ?? null,
            streaming_inter_chunk_avg_ms: asNumber(r.streaming_inter_chunk_avg_ms) ?? null,
          }))
      : null,
    buckets: Array.isArray(raw.buckets)
      ? (raw.buckets as unknown[])
          .filter(isRecord)
          .map(b => ({
            ts_start: asNumber(b.ts_start) ?? 0,
            entry_count: asNumber(b.entry_count) ?? 0,
            success_count: asNumber(b.success_count) ?? 0,
            error_count: asNumber(b.error_count) ?? 0,
            p50_latency_ms: asNumber(b.p50_latency_ms) ?? null,
            p95_latency_ms: asNumber(b.p95_latency_ms) ?? null,
            error_rate: asNumber(b.error_rate) ?? 0,
            total_cost_usd: asNumber(b.total_cost_usd) ?? null,
            cache_hit_ratio: asNumber(b.cache_hit_ratio) ?? null,
          }))
      : null,
  }
}

function decodeRuntimeModelMetricsResponse(raw: unknown): DashboardRuntimeModelMetricsResponse | null {
  if (!isRecord(raw)) return null
  return {
    window_minutes: asNumber(raw.window_minutes),
    bucket_minutes: asNumber(raw.bucket_minutes),
    total_entries: asNumber(raw.total_entries),
    total_error_entries: asNumber(raw.total_error_entries),
    latency_buckets: Array.isArray(raw.latency_buckets)
      ? (raw.latency_buckets as unknown[])
          .filter(isRecord)
          .map(b => ({
            lo_ms: asNumber(b.lo) ?? 0,
            hi_ms: b.hi == null ? null : (asNumber(b.hi) ?? null),
            count: asNumber(b.n) ?? 0,
          }))
      : null,
    models: asRecordArray(raw.models)
      .map(metric => decodeRuntimeModelMetric(metric))
      .filter((metric): metric is DashboardRuntimeModelMetric => metric !== null),
  }
}

export async function fetchRuntimeProviders(opts?: AbortableRequestOptions): Promise<DashboardRuntimeProvidersResponse> {
  const raw = await get<Record<string, unknown>>('/api/v1/providers', { signal: opts?.signal })
  const decoded = decodeRuntimeProvidersResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 runtime lanes payload')
  return decoded
}

export async function fetchRuntimeModelMetrics(
  windowMinutes = 30,
  bucketMinutes = 5,
  opts?: AbortableRequestOptions,
): Promise<DashboardRuntimeModelMetricsResponse> {
  const bParam = bucketMinutes > 0 ? `&bucket_min=${bucketMinutes}` : ''
  const raw = await get<Record<string, unknown>>(`/api/v1/models/metrics?window=${windowMinutes}${bParam}`, { signal: opts?.signal })
  const decoded = decodeRuntimeModelMetricsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 runtime model metrics payload')
  return decoded
}

export interface KeeperCostMetric {
  keeper_name: string
  total_cost_usd: number
  total_input_tokens: number
  total_output_tokens: number
  total_tokens: number
  p50_latency_ms: number | null
  p95_latency_ms: number | null
  sample_count: number
  model_breakdown: Array<{ model: string; cost_usd: number }>
}

export interface KeeperCostMetricsResponse {
  window_minutes?: number
  keepers: KeeperCostMetric[]
  generated_at?: number | null
}

function decodeKeeperCostMetric(raw: unknown): KeeperCostMetric | null {
  if (!isRecord(raw)) return null
  const keeperName = asString(raw.keeper_name)
  if (!keeperName) return null
  const runtimeCost = Array.isArray(raw.model_breakdown)
    ? (raw.model_breakdown as unknown[])
        .filter(isRecord)
        .reduce((sum, item) => sum + (asNumber(item.cost_usd) ?? 0), 0)
    : 0
  return {
    keeper_name: keeperName,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? 0,
    total_input_tokens: asNumber(raw.total_input_tokens) ?? 0,
    total_output_tokens: asNumber(raw.total_output_tokens) ?? 0,
    total_tokens: asNumber(raw.total_tokens) ?? 0,
    p50_latency_ms: asNumber(raw.p50_latency_ms) ?? null,
    p95_latency_ms: asNumber(raw.p95_latency_ms) ?? null,
    sample_count: asNumber(raw.sample_count) ?? 0,
    model_breakdown: runtimeCost > 0 ? [{ model: 'runtime', cost_usd: runtimeCost }] : [],
  }
}

function decodeKeeperCostMetricsResponse(raw: unknown): KeeperCostMetricsResponse | null {
  if (!isRecord(raw)) return null
  return {
    window_minutes: asNumber(raw.window_minutes),
    keepers: asRecordArray(raw.keepers)
      .map(decodeKeeperCostMetric)
      .filter((metric): metric is KeeperCostMetric => metric !== null),
    generated_at: asNumber(raw.generated_at) ?? null,
  }
}

export async function fetchKeeperCostMetrics(
  windowMinutes = DEFAULT_WINDOW_MINUTES_24H,
  opts?: AbortableRequestOptions,
): Promise<KeeperCostMetricsResponse> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/keeper-costs?window=${windowMinutes}`, { signal: opts?.signal })
  const decoded = decodeKeeperCostMetricsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 keeper cost metrics payload')
  return decoded
}

export interface KeeperDecision {
  ts_unix: number | null
  keeper_name: string
  event_type: string
  outcome: string | null
  choice: string | null
  reason: string | null
  context: KeeperDecisionContext | null
  model_used: string | null
  latency_ms: number | null
  cost_usd: number | null
  input_tokens: number | null
  output_tokens: number | null
  stop_reason: string | null
  error_category: string | null
  tool: string | null
  duration_ms: number | null
  match_count: number | null
  // Closed-sum terminal cause of the turn (completed / api_error /
  // runtime_exhausted / tool_contract / required_tool_use_unsatisfied),
  // computed by dashboard_http_keeper_feeds.ml; the table can only show the
  // coarse `outcome` without it.
  terminal_reason_code: string | null
}

export interface KeeperDecisionContext {
  file_path?: string | null
  line?: number | null
  goal_id?: string
  task_id?: string
  board_post_id?: string
  comment_id?: string
  pr_id?: string
  git_ref?: string
  log_id?: string
  session_id?: string
  operation_id?: string
  worker_run_id?: string
}

export interface KeeperDecisionsResponse extends DashboardFeedMetadata {
  events: KeeperDecision[]
  limit: number
  generated_at: number | null
}

function decodeKeeperDecisionContext(raw: unknown): KeeperDecisionContext | null {
  if (!isRecord(raw)) return null
  const context: KeeperDecisionContext = {}
  const filePath = asNullableString(raw.file_path)
  if (filePath !== null) context.file_path = filePath
  const line = asNumber(raw.line)
  if (line !== undefined) context.line = line
  const stringFields = [
    ['goal_id', 'goal_id'],
    ['task_id', 'task_id'],
    ['board_post_id', 'board_post_id'],
    ['comment_id', 'comment_id'],
    ['pr_id', 'pr_id'],
    ['git_ref', 'git_ref'],
    ['log_id', 'log_id'],
    ['session_id', 'session_id'],
    ['operation_id', 'operation_id'],
    ['worker_run_id', 'worker_run_id'],
  ] as const
  for (const [sourceKey, targetKey] of stringFields) {
    const value = asString(raw[sourceKey])
    if (value !== undefined) context[targetKey] = value
  }
  return Object.keys(context).length > 0 ? context : null
}

function decodeKeeperDecision(raw: unknown): KeeperDecision | null {
  if (!isRecord(raw)) return null
  return {
    ts_unix: asNumber(raw.ts_unix) ?? null,
    keeper_name: asString(raw.keeper_name) ?? '',
    event_type: asString(raw.event_type) ?? '(unknown event_type)',
    outcome: asNullableString(raw.outcome),
    choice: asNullableString(raw.choice),
    reason: asNullableString(raw.reason),
    context: decodeKeeperDecisionContext(raw.context),
    model_used: null,
    latency_ms: asNumber(raw.latency_ms) ?? null,
    cost_usd: asNumber(raw.cost_usd) ?? null,
    input_tokens: asNumber(raw.input_tokens) ?? null,
    output_tokens: asNumber(raw.output_tokens) ?? null,
    stop_reason: asNullableString(raw.stop_reason),
    error_category: asNullableString(raw.error_category),
    tool: asNullableString(raw.tool),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    match_count: asNumber(raw.match_count) ?? null,
    terminal_reason_code: asNullableString(raw.terminal_reason_code),
  }
}

function decodeKeeperDecisionsResponse(raw: unknown): KeeperDecisionsResponse | null {
  if (!isRecord(raw)) return null
  return {
    ...decodeDashboardFeedMetadata(raw),
    events: asRecordArray(raw.events)
      .map(decodeKeeperDecision)
      .filter((d): d is KeeperDecision => d !== null),
    limit: asInt(raw.limit) ?? 0,
    generated_at: asNumber(raw.generated_at) ?? null,
  }
}

export async function fetchKeeperDecisions(
  limit = 200,
  opts?: AbortableRequestOptions,
): Promise<KeeperDecisionsResponse> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/keeper-decisions?limit=${limit}`, { signal: opts?.signal })
  const decoded = decodeKeeperDecisionsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 keeper decisions payload')
  return decoded
}

export function fetchDashboardMissionBriefing(
  force = false,
  opts?: { signal?: AbortSignal },
): Promise<DashboardMissionBriefingResponse> {
  const query = force ? '?force=1' : ''
  return get(`/api/v1/dashboard/briefing/sections${query}`, { signal: opts?.signal })
}

export function fetchDashboardPlanning(): Promise<DashboardPlanningResponse> {
  return get('/api/v1/dashboard/planning')
}

function decodeGoalVerificationPrincipal(
  raw: unknown,
): GoalVerificationRequest['requested_by'] | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  if (!id) return null
  return {
    id,
    display_name: asNullableString(raw.display_name),
  }
}

function decodeGoalVerificationPolicySnapshot(
  raw: unknown,
): GoalVerificationRequest['policy_snapshot'] | null {
  if (!isRecord(raw)) return null
  const principals = asRecordArray(raw.principals)
    .map(decodeGoalVerificationPrincipal)
    .filter(
      (
        principal,
      ): principal is NonNullable<GoalVerificationRequest['policy_snapshot']>['principals'][number] =>
        principal !== null,
    )
  const eligiblePrincipals = asRecordArray(raw.eligible_principals)
    .map(decodeGoalVerificationPrincipal)
    .filter(
      (
        principal,
      ): principal is NonNullable<GoalVerificationRequest['policy_snapshot']>['eligible_principals'][number] =>
        principal !== null,
    )
  return {
    principals,
    eligible_principals: eligiblePrincipals,
    required_verdicts: asInt(raw.required_verdicts) ?? 0,
  }
}

function decodeGoalVerificationVote(raw: unknown): GoalVerificationVote | null {
  if (!isRecord(raw)) return null
  const principal = decodeGoalVerificationPrincipal(raw.principal)
  const decision = asString(raw.decision)
  const submittedAt = asString(raw.submitted_at)
  if (!principal || !decision || !submittedAt) return null
  return {
    principal,
    decision,
    note: asNullableString(raw.note),
    evidence_refs: asStringArray(raw.evidence_refs),
    submitted_at: submittedAt,
  }
}

function decodeGoalVerificationRequest(raw: unknown): GoalVerificationRequest | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const goalId = asString(raw.goal_id)
  const targetPhase = asString(raw.target_phase)
  const requestedBy = decodeGoalVerificationPrincipal(raw.requested_by)
  const policySnapshot = decodeGoalVerificationPolicySnapshot(raw.policy_snapshot)
  const status = asString(raw.status)
  const createdAt = asString(raw.created_at)
  if (!id || !goalId || !targetPhase || !requestedBy || !policySnapshot || !status || !createdAt) {
    return null
  }
  return {
    id,
    goal_id: goalId,
    target_phase: targetPhase,
    requested_by: requestedBy,
    policy_snapshot: policySnapshot,
    votes: asRecordArray(raw.votes)
      .map(decodeGoalVerificationVote)
      .filter((vote): vote is GoalVerificationVote => vote !== null),
    status,
    created_at: createdAt,
    resolved_at: asNullableString(raw.resolved_at),
  }
}

function decodeGoalVerificationSummary(raw: unknown): GoalVerificationSummary {
  if (!isRecord(raw)) {
    return {
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    }
  }
  return {
    effective_policy: decodeGoalVerificationPolicySnapshot(raw.effective_policy),
    open_request: decodeGoalVerificationRequest(raw.open_request),
    latest_request: decodeGoalVerificationRequest(raw.latest_request),
    approve_count: asInt(raw.approve_count) ?? 0,
    reject_count: asInt(raw.reject_count) ?? 0,
    remaining_possible: asInt(raw.remaining_possible) ?? 0,
  }
}

function decodeGoalTreeTask(raw: unknown): GoalTreeTask | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  if (!id || !title) return null
  return {
    id,
    title,
    status: asString(raw.status, 'unknown'),
    status_color: asString(raw.status_color, ''),
    priority: asInt(raw.priority) ?? 0,
    assignee: asNullableString(raw.assignee),
    goal_id: asNullableString(raw.goal_id),
    linkage_source: asString(raw.linkage_source, 'none'),
    is_terminal: asBoolean(raw.is_terminal, false),
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
  }
}

function decodeGoalFsmProjection(raw: unknown, phase: string) {
  if (!isRecord(raw)) {
    return {
      state: phase,
      source: 'goal.phase',
      state_kind: phase,
      next_actions: [],
      activity_observation: 'goal_metadata',
      stagnation_status: 'recent',
    }
  }
  return {
    state: asString(raw.state, phase),
    source: asString(raw.source, 'goal.phase'),
    state_kind: asString(raw.state_kind, phase),
    next_actions: asStringArray(raw.next_actions),
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
    stagnation_status: asString(raw.stagnation_status, 'recent'),
  }
}

function decodeGoalKeeperTrustLatestEvent(raw: unknown): GoalKeeperTrustLatestEvent | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const ts = asString(raw.ts)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const severity = asString(raw.severity)
  if (!kind || !ts || !title || !summary || !severity) return null
  return {
    kind,
    ts,
    ts_unix: asNumber(raw.ts_unix) ?? null,
    keeper_turn_id: asInt(raw.keeper_turn_id) ?? null,
    task_id: asNullableString(raw.task_id),
    goal_ids: asStringArray(raw.goal_ids),
    title,
    summary,
    severity,
    next_human_action: asNullableString(raw.next_human_action),
    trace_id: asNullableString(raw.trace_id),
  }
}

function decodeGoalKeeperTrustApprovalState(raw: unknown): GoalKeeperTrustApprovalState | null {
  if (!isRecord(raw)) return null
  const pendingFirst = isRecord(raw.pending_first) ? raw.pending_first : null
  return {
    state: asNullableString(raw.state),
    summary: asNullableString(raw.summary),
    pending_count: asInt(raw.pending_count) ?? null,
    pending_first: pendingFirst
      ? {
          id: asNullableString(pendingFirst.id),
          tool_name: asNullableString(pendingFirst.tool_name),
          task_id: asNullableString(pendingFirst.task_id),
          blocker_class: asNullableString(pendingFirst.blocker_class),
        }
      : null,
    latest_event_at: asNullableString(raw.latest_event_at),
  }
}

function decodeGoalKeeperTrustExecutionSummary(raw: unknown): GoalKeeperTrustExecutionSummary | null {
  if (!isRecord(raw)) return null
  return {
    provider_attempt_count: asInt(raw.provider_attempt_count) ?? null,
    provider_fallback_applied:
      typeof raw.provider_fallback_applied === 'boolean'
        ? raw.provider_fallback_applied
        : null,
    provider_selected_model: asNullableString(raw.provider_selected_model),
    runtime_outcome: asNullableString(raw.runtime_outcome),
    sandbox_summary: asNullableString(raw.sandbox_summary),
    sandbox_root: asNullableString(raw.sandbox_root),
    mutation_guard_summary: asNullableString(raw.mutation_guard_summary),
    latest_receipt_at: asNullableString(raw.latest_receipt_at),
  }
}

function decodeGoalKeeperTrustSummary(raw: unknown): GoalKeeperTrustSummary | null {
  if (!isRecord(raw)) return null
  return {
    disposition: asNullableString(raw.disposition),
    disposition_reason: asNullableString(raw.disposition_reason),
    operator_disposition: asNullableString(raw.operator_disposition),
    operator_disposition_reason: asNullableString(raw.operator_disposition_reason),
    needs_attention:
      typeof raw.needs_attention === 'boolean'
        ? raw.needs_attention
        : null,
    attention_reason: asNullableString(raw.attention_reason),
    next_human_action: asNullableString(raw.next_human_action),
    latest_terminal_reason: normalizeKeeperTrustTerminalReason(raw.latest_terminal_reason),
    latest_next_action: asNullableString(raw.latest_next_action),
    approval_state: decodeGoalKeeperTrustApprovalState(raw.approval_state ?? raw.approval),
    execution_summary:
      decodeGoalKeeperTrustExecutionSummary(raw.execution_summary ?? raw.execution),
    latest_causal_event: decodeGoalKeeperTrustLatestEvent(raw.latest_causal_event),
  }
}

function decodeGoalAttainmentProjection(
  raw: unknown,
  fallback: {
    metric: string | null
    targetValue: string | null
    taskDoneCount: number
    taskCount: number
  },
): GoalAttainmentProjection {
  if (!isRecord(raw)) {
    return {
      state: 'unmeasured',
      basis: 'unmeasured',
      metric: fallback.metric,
      target_value: fallback.targetValue,
      target_parse_status: fallback.targetValue ? 'unparseable' : 'absent',
      unit: 'unknown',
      observed_value: null,
      target_numeric: null,
      attainment_pct: null,
      task_done_count: fallback.taskDoneCount,
      task_count: fallback.taskCount,
      note: 'Attainment projection missing from payload.',
    }
  }
  return {
    state: asString(raw.state, 'unmeasured'),
    basis: asString(raw.basis, 'unmeasured'),
    metric: asNullableString(raw.metric) ?? fallback.metric,
    target_value: asNullableString(raw.target_value) ?? fallback.targetValue,
    target_parse_status: asString(raw.target_parse_status, 'absent'),
    unit: asString(raw.unit, 'unknown'),
    observed_value: asNumber(raw.observed_value) ?? null,
    target_numeric: asNumber(raw.target_numeric) ?? null,
    attainment_pct: asInt(raw.attainment_pct) ?? null,
    task_done_count: asInt(raw.task_done_count) ?? fallback.taskDoneCount,
    task_count: asInt(raw.task_count) ?? fallback.taskCount,
    note: asString(raw.note, ''),
  }
}

function decodeNumberRecord(raw: unknown): Record<string, number> {
  if (!isRecord(raw)) return {}
  const out: Record<string, number> = {}
  for (const [key, value] of Object.entries(raw)) {
    const count = asInt(value)
    if (count != null) out[key] = count
  }
  return out
}

function decodeGoalTaskSummary(
  raw: unknown,
  fallback: { taskCount: number; taskDoneCount: number; tasks: GoalTreeTask[] },
): GoalTaskSummary | undefined {
  if (!isRecord(raw)) return undefined
  const terminal = asInt(raw.terminal) ?? fallback.tasks.filter(task => task.is_terminal).length
  return {
    total: asInt(raw.total) ?? fallback.taskCount,
    done: asInt(raw.done) ?? fallback.taskDoneCount,
    open: asInt(raw.open) ?? Math.max(0, fallback.taskCount - terminal),
    terminal,
    awaiting_verification: asInt(raw.awaiting_verification) ?? 0,
    cancelled: asInt(raw.cancelled) ?? 0,
    unassigned: asInt(raw.unassigned) ?? 0,
    completion_pct: asInt(raw.completion_pct) ?? null,
    by_status: decodeNumberRecord(raw.by_status),
    by_linkage_source: decodeNumberRecord(raw.by_linkage_source),
  }
}

function decodeGoalCompletionSummary(raw: unknown): GoalCompletionSummary | undefined {
  if (!isRecord(raw)) return undefined
  return {
    state: asString(raw.state, 'unmeasured'),
    pct: asInt(raw.pct) ?? null,
    pct_source: asString(raw.pct_source, 'none'),
    attainment_state: asString(raw.attainment_state, 'unmeasured'),
    attainment_basis: asString(raw.attainment_basis, 'unmeasured'),
    task_total: asInt(raw.task_total) ?? 0,
    task_done: asInt(raw.task_done) ?? 0,
    task_open: asInt(raw.task_open) ?? 0,
    is_complete: asBoolean(raw.is_complete) ?? false,
    is_terminal: asBoolean(raw.is_terminal) ?? false,
    ready_to_request_completion: asBoolean(raw.ready_to_request_completion) ?? false,
    gate: asString(raw.gate, 'none'),
    requires_verifier: asBoolean(raw.requires_verifier) ?? false,
    requires_completion_approval: asBoolean(raw.requires_completion_approval) ?? false,
    active_verification_request: asBoolean(raw.active_verification_request) ?? false,
    blocking_source: asString(raw.blocking_source, 'none'),
    blocking_reason: asString(raw.blocking_reason, ''),
  }
}

function decodeGoalTreeNode(raw: unknown): GoalTreeNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  if (!id || !title) return null
  const tasks = asRecordArray(raw.tasks)
    .map(decodeGoalTreeTask)
    .filter((task): task is GoalTreeTask => task !== null)
  const children = asRecordArray(raw.children)
    .map(decodeGoalTreeNode)
    .filter((node): node is GoalTreeNode => node !== null)
  const metric = asNullableString(raw.metric)
  const targetValue = asNullableString(raw.target_value)
  const taskCount = asInt(raw.task_count) ?? tasks.length
  const taskDoneCount = asInt(raw.task_done_count) ?? 0
  const attainment = decodeGoalAttainmentProjection(raw.attainment, {
    metric,
    targetValue,
    taskDoneCount,
    taskCount,
  })
  const verificationSummary = decodeGoalVerificationSummary(raw.verification_summary)
  return {
    id,
    title,
    status: asString(raw.status, 'unknown'),
    status_color: asString(raw.status_color, ''),
    phase: asString(raw.phase, 'unknown'),
    phase_color: asString(raw.phase_color, ''),
    goal_fsm: decodeGoalFsmProjection(raw.goal_fsm, asString(raw.phase, 'unknown')),
    health: asString(raw.health, 'at_risk'),
    health_color: asString(raw.health_color, ''),
    badges: asStringArray(raw.badges),
    status_reason: asString(raw.status_reason, ''),
    priority: asInt(raw.priority) ?? 0,
    metric,
    target_value: targetValue,
    require_completion_approval: asBoolean(raw.require_completion_approval) ?? false,
    due_date: asNullableString(raw.due_date),
    parent_goal_id: asNullableString(raw.parent_goal_id),
    convergence: asNumber(raw.convergence, 0),
    convergence_pct: asInt(raw.convergence_pct) ?? 0,
    attainment,
    tasks,
    task_count: taskCount,
    task_done_count: taskDoneCount,
    task_summary: decodeGoalTaskSummary(raw.task_summary, {
      taskCount,
      taskDoneCount,
      tasks,
    }),
    completion_summary: decodeGoalCompletionSummary(raw.completion_summary),
    verification_summary: verificationSummary,
    effective_verifier_policy: decodeGoalVerificationPolicySnapshot(raw.effective_verifier_policy),
    active_verification_request: decodeGoalVerificationRequest(raw.active_verification_request),
    pending_verification_count: asInt(raw.pending_verification_count) ?? 0,
    timeline_events: Array.isArray(raw.timeline_events) ? raw.timeline_events : [],
    children,
    child_count: asInt(raw.child_count) ?? children.length,
    last_activity_at: asString(raw.last_activity_at, ''),
    stagnation_seconds: asInt(raw.stagnation_seconds) ?? 0,
    activity_observation: asString(raw.activity_observation, 'goal_metadata'),
    stagnation_status: asString(raw.stagnation_status, 'recent'),
    linked_keeper_names: asStringArray(raw.linked_keeper_names),
    pending_approval_count: asInt(raw.pending_approval_count) ?? 0,
    infra_risk_count: asInt(raw.infra_risk_count) ?? 0,
    linkage_source: asString(raw.linkage_source, 'none'),
    linkage_warning_count: asInt(raw.linkage_warning_count) ?? 0,
    blocking_source: asString(raw.blocking_source, 'none'),
    blocking_reason: asString(raw.blocking_reason, ''),
    latest_keeper_ref: asNullableString(raw.latest_keeper_ref),
    latest_turn_ref: asInt(raw.latest_turn_ref) ?? null,
    stalled_since: asNullableString(raw.stalled_since),
    created_at: asString(raw.created_at, ''),
    updated_at: asString(raw.updated_at, ''),
  }
}

function decodeGoalTreeSummary(raw: unknown): GoalTreeSummary {
  if (!isRecord(raw)) {
    return {
      total_goals: 0,
      active_goals: 0,
      done_goals: 0,
      on_track_goals: 0,
      paused_goals: 0,
      at_risk_goals: 0,
      blocked_goals: 0,
      total_tasks: 0,
      done_tasks: 0,
      pending_approvals: 0,
      infra_risk_count: 0,
      overall_convergence: 0,
      overall_convergence_pct: 0,
    }
  }
  return {
    total_goals: asInt(raw.total_goals) ?? 0,
    active_goals: asInt(raw.active_goals) ?? 0,
    on_track_goals: asInt(raw.on_track_goals) ?? 0,
    done_goals: asInt(raw.done_goals) ?? 0,
    paused_goals: asInt(raw.paused_goals) ?? 0,
    at_risk_goals: asInt(raw.at_risk_goals) ?? 0,
    blocked_goals: asInt(raw.blocked_goals) ?? 0,
    total_tasks: asInt(raw.total_tasks) ?? 0,
    done_tasks: asInt(raw.done_tasks) ?? 0,
    pending_approvals: asInt(raw.pending_approvals) ?? 0,
    infra_risk_count: asInt(raw.infra_risk_count) ?? 0,
    overall_convergence: asNumber(raw.overall_convergence, 0),
    overall_convergence_pct: asInt(raw.overall_convergence_pct) ?? 0,
  }
}

function decodeGoalDetailKeeper(raw: unknown): GoalDetailKeeper | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  const agentName = asString(raw.agent_name)
  const sandboxProfile = asString(raw.sandbox_profile)
  const networkMode = asString(raw.network_mode)
  const runtimeName = asString(raw.runtime_id)
  if (!name || !agentName || !sandboxProfile || !networkMode || !runtimeName) return null
  return {
    name,
    agent_name: agentName,
    current_task_id: asNullableString(raw.current_task_id),
    active_goal_ids: asStringArray(raw.active_goal_ids),
    sandbox_profile: sandboxProfile,
    network_mode: networkMode,
    runtime_id: runtimeName,
    runtime_outcome: asNullableString(raw.runtime_outcome),
    latest_execution_outcome: asNullableString(raw.latest_execution_outcome),
    latest_execution_at: asNullableString(raw.latest_execution_at),
    latest_receipt: isRecord(raw.latest_receipt) ? raw.latest_receipt : null,
    runtime_trust: decodeGoalKeeperTrustSummary(raw.runtime_trust),
    latest_causal_event: decodeGoalKeeperTrustLatestEvent(raw.latest_causal_event),
  }
}

function decodeGoalDetailTimelineEvent(raw: unknown): GoalDetailTimelineEvent | null {
  if (!isRecord(raw)) return null
  const ts = asString(raw.ts)
  const kind = asString(raw.kind)
  const lane = asString(raw.lane)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const severity = asString(raw.severity)
  if (!ts || !kind || !lane || !title || !summary || !severity) return null
  return {
    ts,
    kind,
    lane,
    title,
    summary,
    severity,
  }
}

function decodeDashboardGoalsTreeResponse(raw: unknown): DashboardGoalsTreeResponse | null {
  if (!isRecord(raw)) return null
  const tree = asRecordArray(raw.tree)
    .map(decodeGoalTreeNode)
    .filter((node): node is GoalTreeNode => node !== null)
  const summary = decodeGoalTreeSummary(raw.summary)
  const generatedAt = asString(raw.generated_at)
  return generatedAt
    ? { generated_at: generatedAt, tree, summary }
    : { tree, summary }
}

function decodeDashboardGoalDetailResponse(raw: unknown): DashboardGoalDetailResponse | null {
  if (!isRecord(raw)) return null
  const goal = decodeGoalTreeNode(raw.goal)
  if (!goal) return null
  const generatedAt = asString(raw.generated_at)
  const decoded: DashboardGoalDetailResponse = {
    goal,
    linked_tasks: asRecordArray(raw.linked_tasks)
      .map(decodeGoalTreeTask)
      .filter((task): task is GoalTreeTask => task !== null),
    linked_keepers: asRecordArray(raw.linked_keepers)
      .map(decodeGoalDetailKeeper)
      .filter((keeper): keeper is GoalDetailKeeper => keeper !== null),
    approvals: asRecordArray(raw.approvals),
    execution_receipts: asRecordArray(raw.execution_receipts),
    timeline: asRecordArray(raw.timeline)
      .map(decodeGoalDetailTimelineEvent)
      .filter((event): event is GoalDetailTimelineEvent => event !== null),
  }
  return generatedAt ? { ...decoded, generated_at: generatedAt } : decoded
}

export async function fetchDashboardGoalsTree(): Promise<DashboardGoalsTreeResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/goals')
  const decoded = decodeDashboardGoalsTreeResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 dashboard goals payload')
  return decoded
}

export async function fetchDashboardGoalDetail(goalId: string): Promise<DashboardGoalDetailResponse> {
  const raw = await get<unknown>(`/api/v1/dashboard/goals/detail?goal_id=${encodeURIComponent(goalId)}`)
  const decoded = decodeDashboardGoalDetailResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 dashboard goal detail payload')
  return decoded
}

// --- Tool metrics (P4 Phase 4.5) ---

export interface DashboardToolInventoryItem {
  name: string
  description: string
  category: string
  category_description?: string | null
  enabled_in_current_mode: boolean
  direct_call_allowed: boolean
  required_permission?: string | null
  doc_refs: string[]
  prompt_hints: string[]
  surfaces: string[]
  visibility: string
  lifecycle: string
  implementationStatus: string
  tier: string
  canonicalName?: string | null
  replacement?: string | null
  reason?: string | null
}

interface SurfaceSummaryEntry {
  count: number
  tools: string[]
}

interface DashboardToolInventoryResponse {
  count: number
  tools: DashboardToolInventoryItem[]
  surface_summary?: Record<string, SurfaceSummaryEntry>
}

export interface ToolMetricsTopEntry {
  name: string
  call_count: number
}

export interface ToolMetricsResponse extends TelemetryFreshnessMetadata {
  total_calls: number
  distinct_tools_called: number
  top_20: ToolMetricsTopEntry[]
  never_called_count: number
  tool_distribution?: { total: number; public: number; visible: number; hidden: number } | null
  dispatch_v2_enabled: boolean
  registered_count: number
}

export interface DashboardScheduledAutomationFsm {
  state: string
  active_count: number
  terminal_count: number
  next_due_at?: string | null
}

export interface DashboardScheduledAutomationExecution {
  execution_id: string
  schedule_id: string
  started_at?: number
  started_at_iso?: string | null
  finished_at?: number | null
  finished_at_iso?: string | null
  due_at?: number
  payload_digest?: string
  status: string
  detail?: unknown | null
  error?: string | null
}

export interface DashboardScheduledAutomationKeeperToolStatus {
  name: string
  registered_schema?: boolean
  dispatch_registered?: boolean
  direct_call_allowed?: boolean
  visibility?: string
  surfaces?: string[]
  surface_count?: number
  effect_domain?: string | null
  read_only?: boolean | null
  requires_actor_binding?: boolean | null
}

export interface DashboardScheduledAutomationActor {
  id: string
  kind: string
  display_name?: string | null
}

export interface DashboardScheduledAutomationSignal {
  signal_id: string
  kind: string
  event_type?: string
  schedule_id: string
  emitted_at?: number
  emitted_at_iso?: string | null
  due_at?: number
  due_at_iso?: string | null
  risk_class: string
  payload_digest?: string
  payload_kind?: string | null
}

export interface DashboardScheduledAutomationRequest {
  schedule_id: string
  status: string
  effective_status?: string
  execution_readiness?: string
  operator_action?: string | null
  keeper_next_tool?: string | null
  keeper_next_tool_status?: DashboardScheduledAutomationKeeperToolStatus | null
  keeper_next_action?: string | null
  risk_class: string
  approval_required: boolean
  source: string
  requested_by?: DashboardScheduledAutomationActor | null
  scheduled_by?: DashboardScheduledAutomationActor | null
  recurrence?: {
    kind: string
    interval_sec?: number
    hour?: number
    minute?: number
    second?: number
    expression?: string
    timezone?: string
  }
  recurrence_kind?: string
  requested_at?: number
  requested_at_iso?: string
  due_at?: number
  due_at_iso?: string
  next_due_at?: number | null
  next_due_at_iso?: string | null
  expires_at?: number | null
  expires_at_iso?: string | null
  payload_digest?: string
  payload_kind?: string | null
  payload_support?: 'supported' | 'unsupported' | 'unknown'
  payload_target?: string | null
  payload_summary?: string | null
  recurrence_summary?: string | null
  requires_separate_human_grant?: boolean
  approval_policy?: string | null
  last_execution?: DashboardScheduledAutomationExecution | null
}

export interface DashboardScheduledAutomationPayloadSupport {
  supported_kinds?: string[]
  unsupported_request_count?: number
  unsupported_kinds?: Array<{ kind: string; count: number }>
  unknown_request_count?: number
}

export interface DashboardScheduledAutomation {
  schema?: string
  source?: string
  generated_at?: string
  request_count: number
  request_limit: number
  truncated: boolean
  signal_source?: string
  signal_count?: number
  signal_limit?: number
  signals?: DashboardScheduledAutomationSignal[]
  counts: Record<string, number>
  derived_counts?: Record<string, number>
  payload_support?: DashboardScheduledAutomationPayloadSupport
  fsm: DashboardScheduledAutomationFsm
  requests: DashboardScheduledAutomationRequest[]
}

export interface DashboardToolsResponse {
  generated_at?: string
  config_resolution?: DashboardConfigResolution
  runtime_resolution?: DashboardRuntimeResolution
  tool_inventory: DashboardToolInventoryResponse
  tool_usage: ToolMetricsResponse
  scheduled_automation?: DashboardScheduledAutomation
}

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

interface DashboardRuntimeProbeLoadedModel {
  name?: string | null
  model?: string | null
  size_vram_bytes?: number | null
  context_length?: number | null
  expires_at?: string | null
}

interface DashboardRuntimeProbeRun {
  run_index: number
  http_status?: number | null
  wall_clock_ms?: number | null
  total_duration_ms?: number | null
  load_duration_ms?: number | null
  prompt_eval_count?: number | null
  prompt_eval_duration_ms?: number | null
  prompt_tokens_per_second?: number | null
  eval_count?: number | null
  eval_duration_ms?: number | null
  generation_tokens_per_second?: number | null
  done?: boolean | null
  done_reason?: string | null
  thinking_present?: boolean
  response_preview?: string | null
  response_chars?: number | null
  error?: string | null
}

interface DashboardRuntimeProbeAssessment {
  signal?: string | null
  baseline_run_index?: number | null
  best_repeat_run_index?: number | null
  baseline_prompt_eval_duration_ms?: number | null
  best_repeat_prompt_eval_duration_ms?: number | null
  prompt_eval_duration_reduction_ratio?: number | null
  note?: string | null
  limitation?: string | null
}

export interface DashboardRuntimeProviderProbe {
  runtime_id?: string | null
  provider_id?: string | null
  provider_display_name?: string | null
  model_id?: string | null
  model_api_name?: string | null
  protocol?: string | null
  runtime_kind?: string | null
  transport?: string | null
  auth_kind?: string | null
  credential_required?: boolean | null
  auth_present?: boolean | null
  status?: string | null
  reachable?: boolean | null
  http_status?: number | null
  latency_ms?: number | null
  model_count?: number | null
  content_type?: string | null
  downloaded_bytes?: number | null
  endpoint_url?: string | null
  probe_url?: string | null
  error?: string | null
  checked_at?: string | null
}

export interface DashboardRuntimeProviderProbeSummary {
  runtimes?: number
  probed?: number
  reachable?: number
  failed?: number
  skipped?: number
  default_runtime_id?: string | null
}

export interface DashboardRuntimeProbePayload {
  source?: string
  status?: string | null
  checked_at?: string | null
  summary?: DashboardRuntimeProviderProbeSummary | null
  providers?: DashboardRuntimeProviderProbe[]
  server_url?: string
  ps_endpoint?: string
  generate_endpoint?: string
  configured_default_model?: string | null
  requested_model?: string | null
  effective_model?: string | null
  probe_runs_requested?: number
  probe_runs_completed?: number
  max_tokens?: number
  keep_alive?: string | null
  timeout_sec?: number
  ps_timeout_sec?: number
  prompt_chars?: number
  prompt_preview?: string
  ps_http_status_before?: number | null
  ps_http_status_after?: number | null
  loaded_models_before?: DashboardRuntimeProbeLoadedModel[]
  loaded_models_after?: DashboardRuntimeProbeLoadedModel[]
  model_loaded_before_probe?: boolean
  model_loaded_after_probe?: boolean
  runs?: DashboardRuntimeProbeRun[]
  kv_cache_assessment?: DashboardRuntimeProbeAssessment | null
  observations?: string[]
  errors?: string[]
  limitations?: string[]
  probe_ok?: boolean
}

export interface DashboardRuntimeProbeResponse {
  generated_at?: string
  refreshed_at_unix?: number
  cache_ttl_sec?: number
  cache_age_sec?: number
  cache_hit?: boolean
  // Non-blocking route freshness tag. 'served_stale' / 'warming_up' mean a
  // background refresh was scheduled and the fresh value arrives on the next
  // poll — a force=1 ("Live probe") response is not guaranteed to be fresh.
  refresh_state?: 'fresh' | 'recent' | 'served_stale' | 'warming_up'
  probe?: DashboardRuntimeProbePayload | null
}

export function fetchToolMetrics(): Promise<ToolMetricsResponse> {
  return get('/api/v1/tool-metrics')
}

export async function fetchDashboardRuntimeProbe(
  force = false,
  opts?: AbortableRequestOptions,
): Promise<DashboardRuntimeProbeResponse> {
  const query = force ? '?force=1' : ''
  await ensureDevToken()
  return get(`/api/v1/dashboard/runtime-probe${query}`, { signal: opts?.signal })
}

export async function fetchDashboardTools(opts?: AbortableRequestOptions): Promise<DashboardToolsResponse> {
  const raw = await get<DashboardToolsResponse>('/api/v1/dashboard/tools', { signal: opts?.signal })
  const normalizedTools = raw.tool_inventory?.tools?.map(t => ({
    ...t,
    category: t.category ?? 'uncategorized',
    tier: t.tier ?? '(unknown tier)',
    // Tool-layer decoupling groundwork: surface membership is consumer-owned
    // metadata, not an execution constraint. Totalize here so the field is
    // never absent downstream; consumers keep working with [] and the surface
    // filter simply degrades to zero counts. Mirrors category/tier above.
    surfaces: t.surfaces ?? [],
  }))
  return {
    ...raw,
    tool_inventory: {
      ...raw.tool_inventory,
      ...(normalizedTools ? { tools: normalizedTools } : {}),
    },
  }
}

export type PromptSource = 'override' | 'file' | 'default' | 'missing'

export interface DashboardPromptItem {
  key: string
  category: string
  description: string
  current: string
  default: string | null
  effective: string
  file_value: string | null
  override_value: string | null
  file_path: string | null
  file_exists: boolean
  source: PromptSource
  has_override: boolean
  char_count: number
  required_file: boolean
  template_variables: string[]
}

interface DashboardPromptsResponse {
  prompts: DashboardPromptItem[]
}

interface PromptMutationResponse {
  ok: boolean
  message?: string
  key?: string
  source?: PromptSource
  effective?: string
  error?: string
}

export function fetchDashboardPrompts(): Promise<DashboardPromptsResponse> {
  return get('/api/v1/prompts')
}

export function savePromptOverride(key: string, value: string): Promise<PromptMutationResponse> {
  return post('/api/v1/prompts', { action: 'set', key, value })
}

export function clearPromptOverride(key: string): Promise<PromptMutationResponse> {
  return post('/api/v1/prompts', { action: 'clear', key })
}

function asLooseBoolean(value: unknown, fallback = false): boolean {
  const booleanValue = asBoolean(value)
  if (booleanValue !== undefined) return booleanValue
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase()
    if (normalized === 'true') return true
    if (normalized === 'false') return false
  }
  return fallback
}

function asLooseNullableBoolean(value: unknown): boolean | null {
  const booleanValue = asBoolean(value)
  if (booleanValue !== undefined) return booleanValue
  if (typeof value !== 'string') return null
  return asLooseBoolean(value)
}

function asLooseNumber(value: unknown): number | undefined {
  const direct = asNumber(value)
  if (direct !== undefined) return direct
  if (typeof value !== 'string') return undefined
  const parsed = Number.parseFloat(value.trim())
  return Number.isFinite(parsed) ? parsed : undefined
}

function asLooseNullableNumber(value: unknown): number | null {
  return asLooseNumber(value) ?? null
}

function normalizeStringList(value: unknown): string[] {
  const array = asStringArray(value)
  if (array.length > 0) return array
  const single = asNullableString(value)
  return single ? [single] : []
}

function normalizeKeeperFeatureStatus(value: unknown): KeeperFeatureStatus {
  const status = asNullableString(value)
  switch (status) {
    case 'wired':
    case 'source_only':
    case 'unwired':
      return status
    default:
      return 'unwired'
  }
}

function normalizeKeeperHookSlot(raw: unknown): KeeperHookSlot | null {
  if (!isRecord(raw)) return null
  return {
    active: asLooseBoolean(raw.active),
    source: asNullableString(raw.source) ?? 'unknown',
    gates: normalizeStringList(raw.gates),
    effects: normalizeStringList(raw.effects),
    features: normalizeStringList(raw.features),
  }
}

function normalizeKeeperHookSlots(raw: unknown): Record<string, KeeperHookSlot> {
  if (!isRecord(raw)) return {}
  const slots: Record<string, KeeperHookSlot> = {}
  for (const [name, value] of Object.entries(raw)) {
    const slot = normalizeKeeperHookSlot(value)
    if (slot) slots[name] = slot
  }
  return slots
}

function normalizeKeeperConfigActiveGoals(raw: unknown): KeeperConfig['workspace']['active_goals'] {
  return asRecordArray(raw)
    .map((item) => {
      const id = asNullableString(item.id)
      const title = asNullableString(item.title)
      if (!id || !title) return null
      return { id, title }
    })
    .filter((item): item is KeeperConfig['workspace']['active_goals'][number] => item !== null)
}

function normalizePromptBlock(raw: unknown, fallbackKey: string): { key: string; source: string; text: string } {
  if (!isRecord(raw)) {
    return {
      key: fallbackKey,
      source: 'unknown',
      text: '',
    }
  }
  return {
    key: asNullableString(raw.key) ?? fallbackKey,
    source: asNullableString(raw.source) ?? 'unknown',
    text: asNullableString(raw.text) ?? '',
  }
}

function normalizeDefaultSourceKind(value: unknown): KeeperConfig['sources']['default_source_kind'] {
  const sourceKind = asNullableString(value)
  switch (sourceKind) {
    case 'toml':
    case 'persona':
      return sourceKind
    default:
      return null
  }
}

function normalizePerProviderTimeoutMode(
  raw: unknown,
  perProviderTimeoutSec: number | null,
): KeeperConfig['execution']['per_provider_timeout_mode'] {
  return asNullableString(raw) === 'override' || perProviderTimeoutSec != null
    ? 'override'
    : 'turn_budget_default'
}

function normalizeKeeperConfig(raw: unknown, requestedName: string): KeeperConfig {
  const data = isRecord(raw) ? raw : {}
  const prompt = isRecord(data.prompt) ? data.prompt : {}
  const promptBlocks = isRecord(prompt.system_prompt_blocks) ? prompt.system_prompt_blocks : {}
  const execution = isRecord(data.execution) ? data.execution : {}
  const compaction = isRecord(data.compaction) ? data.compaction : {}
  const proactive = isRecord(data.proactive) ? data.proactive : {}
  const drift = isRecord(data.drift) ? data.drift : {}
  const handoff = isRecord(data.handoff) ? data.handoff : {}
  const hooks = isRecord(data.hooks) ? data.hooks : null
  const runtime = isRecord(data.runtime) ? data.runtime : {}
  const runtimeTrust = isRecord(data.runtime_trust) ? data.runtime_trust : null
  const workspace = isRecord(data.workspace) ? data.workspace : {}
  const tools = isRecord(data.tools) ? data.tools : {}
  const sources = isRecord(data.sources) ? data.sources : {}
  const metrics = isRecord(data.metrics) ? data.metrics : {}
  const perProviderTimeoutSec = asLooseNullableNumber(execution.per_provider_timeout_sec)
  const lastLatencyMs = asInt(metrics.last_latency_ms)

  return {
    name: asNullableString(data.name) ?? requestedName,
    active_goal_ids: normalizeStringList(data.active_goal_ids),
    sandbox_profile: asNullableString(data.sandbox_profile) ?? '(unknown sandbox_profile)',
    network_mode: asNullableString(data.network_mode) ?? '(unknown network_mode)',
    sandbox_last_error: asNullableString(data.sandbox_last_error),
    allowed_paths: normalizeStringList(data.allowed_paths),
    effective_allowed_paths: normalizeStringList(data.effective_allowed_paths),
    prompt: {
      goal: asNullableString(prompt.goal) ?? '',
      instructions: asNullableString(prompt.instructions) ?? '',
      system_prompt_blocks: {
        constitution: normalizePromptBlock(promptBlocks.constitution, 'keeper.constitution'),
        world: normalizePromptBlock(promptBlocks.world, 'keeper.world'),
        capabilities: normalizePromptBlock(promptBlocks.capabilities, 'keeper.capabilities'),
      },
      effective_system_prompt: asNullableString(prompt.effective_system_prompt) ?? '',
      unified_system_prompt: asNullableString(prompt.unified_system_prompt) ?? '',
      unified_user_message_preview:
        asNullableString(prompt.unified_user_message_preview) ?? '',
    },
    execution: {
      models: normalizeStringList(execution.models),
      active_model: '',
      active_model_label: null,
      last_model_used_label: null,
      per_provider_timeout_sec: perProviderTimeoutSec,
      per_provider_timeout_mode: normalizePerProviderTimeoutMode(
        execution.per_provider_timeout_mode,
        perProviderTimeoutSec,
      ),
      verify: asLooseBoolean(execution.verify),
      selected_runtime_id: asNullableString(execution.selected_runtime_id) ?? '',
      selected_runtime_canonical:
        asNullableString(execution.selected_runtime_canonical)
        ?? asNullableString(execution.selected_runtime_id)
        ?? '',
      runtime_options: normalizeStringList(execution.runtime_options),
    },
    compaction: {
      profile: asNullableString(compaction.profile) ?? '(unknown compaction profile)',
      ratio_gate: asLooseNumber(compaction.ratio_gate) ?? 0.85,
      message_gate: asInt(compaction.message_gate) ?? 0,
      token_gate: asInt(compaction.token_gate) ?? 0,
      cooldown_sec: asInt(compaction.cooldown_sec) ?? 0,
    },
    proactive: {
      enabled: asLooseBoolean(proactive.enabled),
      idle_sec: asInt(proactive.idle_sec) ?? 0,
      cooldown_sec: asInt(proactive.cooldown_sec) ?? 0,
    },
    drift: {
      status: normalizeKeeperFeatureStatus(drift.status),
      enabled: asLooseNullableBoolean(drift.enabled),
      min_turn_gap: asInt(drift.min_turn_gap) ?? null,
      count_total: asInt(drift.count_total) ?? null,
      last_reason: asNullableString(drift.last_reason),
    },
    handoff: {
      auto: asLooseBoolean(handoff.auto),
      threshold: asLooseNumber(handoff.threshold) ?? 0.85,
      cooldown_sec: asInt(handoff.cooldown_sec) ?? 0,
    },
    hooks: hooks
      ? {
          slots: normalizeKeeperHookSlots(hooks.slots),
          deny_list: normalizeStringList(hooks.deny_list),
          // deny_list_count is derived (deny_list.length); not stored.
          destructive_check_tools: normalizeStringList(hooks.destructive_check_tools),
          cost_budget: {
            max_cost_usd: asLooseNullableNumber(isRecord(hooks.cost_budget) ? hooks.cost_budget.max_cost_usd : undefined),
            active: asLooseBoolean(isRecord(hooks.cost_budget) ? hooks.cost_budget.active : undefined),
          },
        }
      : undefined,
    runtime: {
      paused: asLooseBoolean(runtime.paused),
      registered: asLooseBoolean(runtime.registered),
      keepalive_running: asLooseBoolean(runtime.keepalive_running),
      registry_state: asNullableString(runtime.registry_state),
      fiber_health: asNullableString(runtime.fiber_health) ?? 'unknown',
      runtime_blocker_class: asKeeperRuntimeBlockerClass(runtime.runtime_blocker_class),
      active_model_label: null,
      last_model_used_label: null,
      runtime_blocker_summary: asNullableString(runtime.runtime_blocker_summary),
      runtime_blocker_continue_gate: asLooseNullableBoolean(runtime.runtime_blocker_continue_gate),
    },
    runtime_trust: runtimeTrust,
    workspace: {
      mention_targets: normalizeStringList(workspace.mention_targets),
      bound_workspace_ids: normalizeStringList(workspace.bound_workspace_ids),
      active_goal_ids: normalizeStringList(workspace.active_goal_ids),
      active_goals: normalizeKeeperConfigActiveGoals(workspace.active_goals),
      active_goal_count: asInt(workspace.active_goal_count) ?? 0,
      missing_active_goal_ids: normalizeStringList(workspace.missing_active_goal_ids),
    },
    tools: {
      tool_access: normalizeStringList(tools.tool_access),
      resolved_allowlist: normalizeStringList(tools.resolved_allowlist),
      tool_denylist: normalizeStringList(tools.tool_denylist),
      active_masc_tool_count: asInt(tools.active_masc_tool_count) ?? 0,
      active_keeper_tool_count: asInt(tools.active_keeper_tool_count) ?? 0,
      total_active: asInt(tools.total_active) ?? 0,
    },
    sources: {
      live_meta_path: asNullableString(sources.live_meta_path) ?? '',
      default_manifest_path: asNullableString(sources.default_manifest_path),
      default_source_kind: normalizeDefaultSourceKind(sources.default_source_kind),
      precedence: normalizeStringList(sources.precedence),
      has_live_override: asLooseBoolean(sources.has_live_override),
      override_fields: normalizeStringList(sources.override_fields),
    },
    metrics: {
      generation: asInt(metrics.generation) ?? 0,
      total_turns: asInt(metrics.total_turns) ?? 0,
      total_input_tokens: asInt(metrics.total_input_tokens) ?? 0,
      total_output_tokens: asInt(metrics.total_output_tokens) ?? 0,
      total_tokens: asInt(metrics.total_tokens) ?? 0,
      total_cost_usd: asLooseNumber(metrics.total_cost_usd) ?? 0,
      last_model_used: '',
      last_input_tokens: asInt(metrics.last_input_tokens) ?? 0,
      last_output_tokens: asInt(metrics.last_output_tokens) ?? 0,
      last_total_tokens: asInt(metrics.last_total_tokens) ?? 0,
      last_latency_ms: lastLatencyMs != null && lastLatencyMs > 0 ? lastLatencyMs : null,
      last_total_tokens_per_sec: asLooseNullableNumber(metrics.last_total_tokens_per_sec),
      last_output_tokens_per_sec: asLooseNullableNumber(metrics.last_output_tokens_per_sec),
      compaction_count: asInt(metrics.compaction_count) ?? 0,
    },
  }
}

// --- Keeper config (structured read-only view) ---

export function fetchKeeperConfig(name: string): Promise<KeeperConfig> {
  return get<unknown>(`/api/v1/keepers/${encodeURIComponent(name)}/config`)
    .then(raw => normalizeKeeperConfig(raw, name))
}

export type SandboxProfile = 'local' | 'docker'
export type SandboxNetworkMode = 'none' | 'inherit'
export type SharedMemoryScope = 'disabled' | 'workspace'

export type KeeperConfigUpdatePayload = {
  runtime_id?: string
  active_goal_ids?: string[]
  mention_targets?: string[]
  allowed_paths?: string[]
  // Sandbox
  sandbox_profile?: SandboxProfile
  network_mode?: SandboxNetworkMode
  // Prompt fields
  goal?: string
  instructions?: string
  // Proactive
  proactive_enabled?: boolean
  proactive_idle_sec?: number
  proactive_cooldown_sec?: number
  // Compaction
  compaction_ratio_gate?: number
  compaction_message_gate?: number
  compaction_token_gate?: number
  continuity_compaction_cooldown_sec?: number
  // Handoff
  auto_handoff?: boolean
  handoff_threshold?: number
  handoff_cooldown_sec?: number
}

export async function patchKeeperConfig(
  name: string,
  payload: KeeperConfigUpdatePayload,
): Promise<KeeperConfig> {
  await ensureDevToken()
  return post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(name)}/config`,
    payload,
  ).then(raw => normalizeKeeperConfig(raw, name))
}

// Tool policy is set atomically (tool_access + denylist) via the dedicated
// /tools endpoint with action=set_policy — a different mutation shape from the
// /config PATCH above. The caller should echo the current tool_access so that
// editing only the denylist preserves the operator's configured allowlist
// record (which feeds tool visibility + assignment telemetry). Runtime
// execution gating keys only off the denylist, not tool_access. The endpoint
// returns the updated tools block (not the full config), so we re-fetch the
// config to get a consistent normalized snapshot.
export async function setKeeperToolPolicy(
  name: string,
  policy: { tool_access: string[]; deny: string[] },
): Promise<KeeperConfig> {
  await ensureDevToken()
  await post<unknown>(`/api/v1/keepers/${encodeURIComponent(name)}/tools`, {
    action: 'set_policy',
    tool_access: policy.tool_access,
    deny: policy.deny,
  })
  return fetchKeeperConfig(name)
}

// --- Runtime config (raw runtime.toml editor) ---

export interface RuntimeTomlConfig {
  ok: boolean
  path: string | null
  file_name: string
  source_text: string
  reloaded: boolean
}

function normalizeRuntimeTomlConfig(raw: unknown): RuntimeTomlConfig {
  const record = isRecord(raw) ? raw : {}
  return {
    ok: asBoolean(record.ok) ?? true,
    path: asNullableString(record.path),
    file_name: asString(record.file_name) ?? 'runtime.toml',
    source_text: asString(record.source_text, ''),
    reloaded: asBoolean(record.reloaded) ?? false,
  }
}

export async function fetchRuntimeTomlConfig(): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return get<unknown>('/api/v1/runtime/config/raw').then(normalizeRuntimeTomlConfig)
}

// Structured, already-resolved runtime defaults / model routing (runtime.toml
// SSOT). Public read — no credentials, no raw TOML; the Settings surface
// consumes this instead of re-parsing TOML on the client.
export async function fetchRuntimeDefaults(
  opts?: AbortableRequestOptions,
): Promise<RuntimeDefaultsResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/runtime-defaults', { signal: opts?.signal })
  return parseRuntimeDefaultsResponse(raw)
}

export async function saveRuntimeTomlConfig(sourceText: string): Promise<RuntimeTomlConfig> {
  await ensureDevToken()
  return post<unknown>('/api/v1/runtime/config/raw', {
    source_text: sourceText,
  }).then(normalizeRuntimeTomlConfig)
}

// --- Keeper trajectory (tool call history) ---

type TrajectoryGate = {
  status: 'pass' | 'reject'
  reason?: string
}

export type TrajectoryEntry = {
  type?: 'thinking'  // absent for tool calls, 'thinking' for thinking blocks
  ts: number
  ts_iso: string
  turn: number
  // RFC-0233: canonical execution identity minted at dispatch (absent on pre-PR-1 rows)
  execution_id?: string
  // Tool-call fields (absent on thinking entries)
  round?: number
  tool_name?: string
  args?: Record<string, unknown> | string
  gate?: TrajectoryGate
  result?: string | null
  duration_ms?: number
  error?: string | null
  cost_usd?: number
  // Thinking-specific fields
  content?: string
  content_length?: number
  redacted?: boolean
}

export type TrajectoryResponse = {
  keeper: string
  trace_id: string
  generation: number
  total_entries: number
  showing: number
  entries: TrajectoryEntry[]
}

export function fetchKeeperTrajectory(
  name: string,
  limit?: number,
  includeThinking = true,
  fullOutput = false,
): Promise<TrajectoryResponse> {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  // Always send include_thinking explicitly — backend defaults to false,
  // so omitting the param means "don't include".
  params.set('include_thinking', includeThinking ? 'true' : 'false')
  // Request full output for session trace detail view.
  // content_max_len=0 → no cap: surface the COMPLETE reasoning text in the
  // detail view (남김없이). The backend persists thinking untruncated and
  // treats 0 as "no truncation"; size is intentionally accepted here, this is
  // the drill-in surface (the timeline list keeps the default preview cap).
  if (fullOutput) {
    params.set('result_max_len', '10000')
    params.set('content_max_len', '0')
  }
  const qs = params.toString()
  return get<TrajectoryResponse>(
    `/api/v1/keepers/${encodeURIComponent(name)}/trajectory${qs ? `?${qs}` : ''}`,
  )
}

// ── Keeper tool stats (server-side aggregation) ──────────

export type ToolStat = {
  name: string
  call_count: number
  success_count: number
  failure_count: number
  avg_duration_ms: number
  p95_duration_ms: number
  max_duration_ms: number
  total_cost_usd: number
  last_used_at: string
}

export type HourlyBucket = {
  hour: string
  call_count: number
  error_count: number
}

export type TelemetryFreshnessMetadata = {
  source?: string
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  dashboard_surface_envelope?: DashboardSurfaceEnvelope | null
  freshness_slo_s?: number | null
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
  health?: string
  stale_reason?: string | null
  entry_count?: number
  exists?: boolean
  coverage_gaps?: TelemetryCoverageGap[]
  coverage_gap_count?: number
  // Count of gaps not yet recovered (source latest_ts < gap ts), distinct from
  // the total coverage_gap_count — the actionable "still failing" number.
  active_coverage_gap_count?: number
}

export type DashboardSurfaceEnvelope = {
  schema?: string
  schema_version?: number
  surface?: string
  source?: string
  generated_at_iso?: string
  cache?: {
    state?: string
    key?: string | null
    ttl_s?: number | null
    stale?: boolean
    stale_reason?: string | null
    latest_age_s?: number | null
    health?: string | null
  }
  migration?: {
    body_shape?: string
    rule?: string
  }
}

export type TelemetryCoverageGap = {
  schema?: string
  ts?: number
  ts_iso?: string | null
  source?: string
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  stale_reason?: string
  keeper_name?: string | null
  trace_id?: string | null
  error?: string | null
  // RFC-0154 PR-2: backend-classified typed tag. Absent on v1 rows; present
  // on v2 rows. Values are the short tags from `System_error_class.to_short_tag`
  // ("fd_exhaustion" / "disk_exhaustion" / "permission_denied" /
  // "connection_refused" / "timeout" / "other"). Consumers should fall back to
  // substring matching on `error` when this field is null (legacy / pre-PR-2).
  error_class?: string | null
}

function decodeDashboardSurfaceEnvelope(raw: unknown): DashboardSurfaceEnvelope | null {
  if (!isRecord(raw)) return null
  const cache = isRecord(raw.cache)
    ? {
        state: asString(raw.cache.state),
        key: asNullableString(raw.cache.key),
        ttl_s: asNumber(raw.cache.ttl_s),
        stale: asBoolean(raw.cache.stale),
        stale_reason: asNullableString(raw.cache.stale_reason),
        latest_age_s: asNumber(raw.cache.latest_age_s),
        health: asNullableString(raw.cache.health),
      }
    : undefined
  const migration = isRecord(raw.migration)
    ? {
        body_shape: asString(raw.migration.body_shape),
        rule: asString(raw.migration.rule),
      }
    : undefined
  return {
    schema: asString(raw.schema),
    schema_version: asNumber(raw.schema_version),
    surface: asString(raw.surface),
    source: asString(raw.source),
    generated_at_iso: asString(raw.generated_at_iso),
    cache,
    migration,
  }
}

function decodeTelemetryCoverageGap(raw: unknown): TelemetryCoverageGap | null {
  if (!isRecord(raw)) return null
  return {
    schema: asString(raw.schema),
    ts: asNumber(raw.ts),
    ts_iso: asNullableString(raw.ts_iso),
    source: asString(raw.source),
    producer: asString(raw.producer),
    durable_store: asString(raw.durable_store),
    dashboard_surface: asString(raw.dashboard_surface),
    stale_reason: asString(raw.stale_reason),
    keeper_name: asNullableString(raw.keeper_name),
    trace_id: asNullableString(raw.trace_id),
    error: asNullableString(raw.error),
    error_class: asNullableString(raw.error_class),
  }
}

function decodeTelemetryFreshnessMetadata(raw: Record<string, unknown>): TelemetryFreshnessMetadata {
  const coverageGaps = asRecordArray(raw.coverage_gaps)
    .map(decodeTelemetryCoverageGap)
    .filter((gap): gap is TelemetryCoverageGap => gap !== null)
  return {
    source: asString(raw.source),
    producer: asString(raw.producer),
    durable_store: asString(raw.durable_store),
    dashboard_surface: asString(raw.dashboard_surface),
    dashboard_surface_envelope: decodeDashboardSurfaceEnvelope(raw.dashboard_surface_envelope),
    freshness_slo_s: asNumber(raw.freshness_slo_s),
    latest_ts_unix: asNumber(raw.latest_ts_unix),
    latest_ts_iso: asNullableString(raw.latest_ts_iso),
    latest_age_s: asNumber(raw.latest_age_s),
    health: asString(raw.health),
    stale_reason: asNullableString(raw.stale_reason),
    entry_count: asNumber(raw.entry_count),
    exists: asBoolean(raw.exists),
    coverage_gaps: coverageGaps,
    coverage_gap_count: asNumber(raw.coverage_gap_count, coverageGaps.length),
    active_coverage_gap_count: asNumber(raw.active_coverage_gap_count),
  }
}

export type ToolStatsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  window_hours: number
  total_entries: number
  tools: ToolStat[]
  timeline: HourlyBucket[]
}

function decodeToolStat(raw: unknown): ToolStat | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  return {
    name,
    call_count: asNumber(raw.call_count, 0),
    success_count: asNumber(raw.success_count, 0),
    failure_count: asNumber(raw.failure_count, 0),
    avg_duration_ms: asNumber(raw.avg_duration_ms, 0),
    p95_duration_ms: asNumber(raw.p95_duration_ms, 0),
    max_duration_ms: asNumber(raw.max_duration_ms, 0),
    total_cost_usd: asNumber(raw.total_cost_usd, 0),
    last_used_at: asString(raw.last_used_at, ''),
  }
}

function decodeHourlyBucket(raw: unknown): HourlyBucket | null {
  if (!isRecord(raw)) return null
  const hour = asString(raw.hour)
  if (!hour) return null
  return {
    hour,
    call_count: asNumber(raw.call_count, 0),
    error_count: asNumber(raw.error_count, 0),
  }
}

function decodeToolStatsResponse(raw: unknown): ToolStatsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    window_hours: asNumber(raw.window_hours, 24),
    total_entries: asNumber(raw.total_entries, 0),
    tools: asRecordArray(raw.tools)
      .map(decodeToolStat)
      .filter((tool): tool is ToolStat => tool !== null),
    timeline: asRecordArray(raw.timeline)
      .map(decodeHourlyBucket)
      .filter((bucket): bucket is HourlyBucket => bucket !== null),
  }
}

export function fetchKeeperToolStats(
  name: string,
  windowHours?: number,
  opts?: AbortableRequestOptions,
): Promise<ToolStatsResponse> {
  const params = windowHours != null ? `?window_hours=${windowHours}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-stats${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeToolStatsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper tool stats payload')
    return decoded
  })
}

// ── Keeper tool call log (full I/O) ──────────────────────

// Output is either an inline string (legacy / small payload) or a
// normalized blob descriptor — see lib/keeper_tool_call_log.ml
// `blob_aware_output_json`. The renderer must accept both shapes.
export type ToolCallOutputBlob = {
  _blob: {
    sha256: string
    bytes: number
    mime: string
    preview: string
  }
}

export type ToolCallEntry = {
  ts: number
  keeper: string
  tool: string
  input: unknown
  output: string | ToolCallOutputBlob
  success: boolean
  duration_ms: number | null
  model?: string
  trace_id?: string
  session_id?: string
  turn?: number
  keeper_turn_id?: number
  task_id?: string
  lane?: string
  // RFC-0233: canonical execution identity minted at dispatch (absent on pre-PR-1 rows)
  execution_id?: string
  // RFC-0233 PR-2: provider call id (oas-event join key). Equals the chat tool
  // row's tool_call_id for the same execution, so the chat ToolCallBubble can
  // join this entry's output onto the transcript. Absent when the call carried
  // no provider id (synthesised tc-<position> rows) or on pre-PR-2 logs.
  tool_use_id?: string
  // Parsed-output failure mode, distinct from the transport `success` above
  // (keeper_tool_call_log.ml semantic_outcome_of_output): success / no_match /
  // partial / blocked / timeout / runtime_error / policy_denied /
  // structured_error / tool_failure. Left open-string for forward-compat — the
  // backend can mint a new outcome ahead of the dashboard; the renderer maps
  // known values and shows the raw label otherwise.
  semantic_outcome?: string
  // Whether the parsed output signals success. A call can be transport
  // success=true while semantic_success=false (e.g. blocked/timeout), which the
  // binary `success` flag alone renders as green/ok.
  semantic_success?: boolean
  // Goal id(s) this call was attributed to (conditional on the row carrying
  // them), for goal-scoped drill-down alongside task_id/turn.
  goal_ids?: string[]
}

export type ToolCallsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  count: number
  entries: ToolCallEntry[]
}

function decodeToolCallOutput(raw: unknown): string | ToolCallOutputBlob {
  if (typeof raw === 'string') return raw
  if (
    isRecord(raw) &&
    isRecord(raw._blob) &&
    typeof raw._blob.sha256 === 'string' &&
    typeof raw._blob.bytes === 'number' &&
    typeof raw._blob.mime === 'string' &&
    typeof raw._blob.preview === 'string'
  ) {
    return {
      _blob: {
        sha256: raw._blob.sha256,
        bytes: raw._blob.bytes,
        mime: raw._blob.mime,
        preview: raw._blob.preview,
      },
    }
  }
  return ''
}

function decodeToolCallEntry(raw: unknown): ToolCallEntry | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const tool = asString(raw.tool)
  if (!keeper || !tool) return null
  return {
    ts: asNumber(raw.ts, 0),
    keeper,
    tool,
    input: raw.input,
    output: decodeToolCallOutput(raw.output),
    success: asBoolean(raw.success, false),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    model: asString(raw.model),
    trace_id: asString(raw.trace_id),
    session_id: asString(raw.session_id),
    turn: asNumber(raw.turn),
    keeper_turn_id: asNumber(raw.keeper_turn_id),
    task_id: asString(raw.task_id),
    lane: asString(raw.lane),
    execution_id: asString(raw.execution_id),
    tool_use_id: asString(raw.tool_use_id),
    semantic_outcome: asString(raw.semantic_outcome),
    semantic_success: asBoolean(raw.semantic_success),
    goal_ids: asStringArray(raw.goal_ids),
  }
}

function decodeToolCallsResponse(raw: unknown): ToolCallsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    count: asNumber(raw.count, 0),
    entries: asRecordArray(raw.entries)
      .map(decodeToolCallEntry)
      .filter((entry): entry is ToolCallEntry => entry !== null),
  }
}

export function fetchKeeperToolCalls(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<ToolCallsResponse> {
  const params = limit != null ? `?limit=${limit}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-calls${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeToolCallsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper tool call payload')
    return decoded
  })
}

// ── Keeper turn records (RFC-0233 PR-4) ─────────────────

export type TurnBlock = {
  block: string
  bytes: number
  digest: string
}

export type TurnRecordEntry = {
  execution_ids: string[]
  keeper: string
  trace_id: string
  absolute_turn: number
  blocks: TurnBlock[]
  runtime_profile: string
  // RFC-0233 §2.3 — grounded from the backend turn record (boundary-redacted
  // model label + keeper stop reason). Absent (undefined) on error turns and
  // pre-grounding rows; the inspector renders absence, never a fabricated value.
  model?: string
  finish_reason?: string
  temperature?: number
  top_p?: number
  max_tokens?: number
  thinking_budget?: number
  enable_thinking?: boolean
  input_tokens?: number
  output_tokens?: number
  // RFC-0233 §8 — runtime model metadata. context_window is the keeper-resolved
  // effective token budget (the ctx-fill% denominator); the two prices are USD
  // per 1M tokens declared on the runtime binding. Absent (undefined) when the
  // runtime is unknown or the operator left runtime.toml unset; the inspector
  // renders "미상" (unknown) rather than a fabricated 200K / Claude $3·$15.
  context_window?: number
  price_input_per_million?: number
  price_output_per_million?: number
  // RFC-0233 §9 — wall-clock duration of the provider call (ms), sourced from
  // OAS inference_telemetry.request_latency_ms. Absent when the turn errored
  // before a response existed; the inspector renders "측정 없음" rather than a
  // fabricated duration for the response-generation phase.
  request_latency_ms?: number
  // RFC-0233 §10 — time-to-first-response-chunk (ms, wall-clock), sourced from
  // OAS inference_telemetry.ttfrc_ms. Unlike request_latency_ms (end-to-end),
  // this isolates time-to-first-token on the streaming path; the streaming
  // transport fills it for every provider, so it is populated across the
  // streaming keeper fleet. Absent for non-streaming turns and on the error
  // path. The decode (post-first-chunk) duration is NOT derived from
  // request_latency_ms - ttfrc_ms (§9.6 fabrication guard).
  ttfrc_ms?: number
  ts: number
}

export type TurnBlockDiff = {
  added: TurnBlock[]
  removed: TurnBlock[]
  changed: { prev: TurnBlock; next: TurnBlock }[]
}

export type TurnRecordRow = {
  record: TurnRecordEntry
  // null on the first record of a trace (no same-trace predecessor)
  diff_vs_prev: TurnBlockDiff | null
}

export type MemoryOsEpisodeSummary = {
  trace_id: string
  generation: number
  created_at: number
  created_at_iso: string | null
  valid_until: number | null
  valid_until_iso: string | null
  current: boolean
  terminal_marker: string | null
  claim_count: number
  summary: string
}

export type MemoryOsTurnRecordSnapshot = {
  schema: string
  keeper: string
  source: string
  producer: string
  facts_store: string
  episodes_store: string
  recall_enabled: boolean
  now: number | null
  now_iso: string | null
  read_errors: { scope: string; error: string }[]
  episodes: {
    tail_limit: number
    shown: number
    current: number
    expired: number
    terminal_markers: number
    items: MemoryOsEpisodeSummary[]
  }
  facts: {
    tail_limit: number
    shown: number
    current: number
    expired: number
  }
}

export type KeeperUserModelItem = {
  claim: string
  category: string
  source: 'keeper' | 'shared' | string
  observed_by: string[]
  turn: number
  first_seen: number
  first_seen_iso: string | null
  last_verified_at: number | null
  last_verified_at_iso: string | null
}

export type KeeperUserModelSnapshot = {
  schema: string
  keeper: string
  source: string
  producer: string
  facts_store: string
  shared_facts_store: string
  enabled: boolean
  now: number | null
  now_iso: string | null
  read_errors: { scope: string; error: string }[]
  source_fact_count: number
  shared_fact_count: number
  preferences: KeeperUserModelItem[]
  constraints: KeeperUserModelItem[]
}

export type TurnRecordsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  count: number
  // malformed JSONL rows the server refused to decode (never repaired)
  skipped_rows: number
  memory_os: MemoryOsTurnRecordSnapshot | null
  user_model: KeeperUserModelSnapshot | null
  entries: TurnRecordRow[]
}

function decodeTurnBlock(raw: unknown): TurnBlock | null {
  if (!isRecord(raw)) return null
  const block = asString(raw.block)
  const digest = asString(raw.digest)
  const bytes = asNumber(raw.bytes)
  if (!block || !digest || bytes == null) return null
  return { block, bytes, digest }
}

function decodeTurnBlockList(raw: unknown): TurnBlock[] {
  return asRecordArray(raw)
    .map(decodeTurnBlock)
    .filter((block): block is TurnBlock => block !== null)
}

function decodeTurnRecordEntry(raw: unknown): TurnRecordEntry | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const trace_id = asString(raw.trace_id)
  const absolute_turn = asNumber(raw.absolute_turn)
  const runtime_profile = asString(raw.runtime_profile)
  const ts = asNumber(raw.ts)
  if (!keeper || !trace_id || absolute_turn == null || !runtime_profile || ts == null) {
    return null
  }
  const execution_ids = Array.isArray(raw.execution_ids)
    ? raw.execution_ids.filter((id): id is string => typeof id === 'string')
    : []
  return {
    execution_ids,
    keeper,
    trace_id,
    absolute_turn,
    blocks: decodeTurnBlockList(raw.blocks),
    runtime_profile,
    model: asString(raw.model),
    finish_reason: asString(raw.finish_reason),
    temperature: asNumber(raw.temperature),
    top_p: asNumber(raw.top_p),
    max_tokens: asNumber(raw.max_tokens),
    thinking_budget: asNumber(raw.thinking_budget),
    enable_thinking: typeof raw.enable_thinking === 'boolean' ? raw.enable_thinking : undefined,
    input_tokens: asNumber(raw.input_tokens),
    output_tokens: asNumber(raw.output_tokens),
    context_window: asNumber(raw.context_window),
    price_input_per_million: asNumber(raw.price_input_per_million),
    price_output_per_million: asNumber(raw.price_output_per_million),
    request_latency_ms: asNumber(raw.request_latency_ms),
    ttfrc_ms: asNumber(raw.ttfrc_ms),
    ts,
  }
}

function decodeTurnBlockDiff(raw: unknown): TurnBlockDiff | null {
  if (!isRecord(raw)) return null
  const changed = asRecordArray(raw.changed)
    .map((pair) => {
      const prev = decodeTurnBlock(pair.prev)
      const next = decodeTurnBlock(pair.next)
      return prev && next ? { prev, next } : null
    })
    .filter((pair): pair is { prev: TurnBlock; next: TurnBlock } => pair !== null)
  return {
    added: decodeTurnBlockList(raw.added),
    removed: decodeTurnBlockList(raw.removed),
    changed,
  }
}

function decodeTurnRecordRow(raw: unknown): TurnRecordRow | null {
  if (!isRecord(raw)) return null
  const record = decodeTurnRecordEntry(raw.record)
  if (!record) return null
  return {
    record,
    diff_vs_prev: decodeTurnBlockDiff(raw.diff_vs_prev),
  }
}

function decodeMemoryOsEpisode(raw: unknown): MemoryOsEpisodeSummary | null {
  if (!isRecord(raw)) return null
  const trace_id = asString(raw.trace_id)
  const generation = asNumber(raw.generation)
  const created_at = asNumber(raw.created_at)
  const summary = asString(raw.summary)
  if (!trace_id || generation == null || created_at == null || !summary) return null
  return {
    trace_id,
    generation,
    created_at,
    created_at_iso: asNullableString(raw.created_at_iso),
    valid_until: asNumber(raw.valid_until) ?? null,
    valid_until_iso: asNullableString(raw.valid_until_iso),
    current: asBoolean(raw.current, true) ?? true,
    terminal_marker: asNullableString(raw.terminal_marker),
    claim_count: asNumber(raw.claim_count, 0) ?? 0,
    summary,
  }
}

function decodeMemoryOsCounts(raw: unknown): {
  tail_limit: number
  shown: number
  current: number
  expired: number
} | null {
  if (!isRecord(raw)) return null
  return {
    tail_limit: asNumber(raw.tail_limit, 0) ?? 0,
    shown: asNumber(raw.shown, 0) ?? 0,
    current: asNumber(raw.current, 0) ?? 0,
    expired: asNumber(raw.expired, 0) ?? 0,
  }
}

function decodeMemoryOsSnapshot(raw: unknown): MemoryOsTurnRecordSnapshot | null {
  if (!isRecord(raw)) return null
  const schema = asString(raw.schema)
  const keeper = asString(raw.keeper)
  const source = asString(raw.source)
  const producer = asString(raw.producer)
  const facts_store = asString(raw.facts_store)
  const episodes_store = asString(raw.episodes_store)
  const episodesRaw = isRecord(raw.episodes) ? raw.episodes : null
  const facts = decodeMemoryOsCounts(raw.facts)
  if (!schema || !keeper || !source || !producer || !facts_store || !episodes_store || !episodesRaw || !facts) {
    return null
  }
  const episodesCounts = decodeMemoryOsCounts(episodesRaw)
  if (!episodesCounts) return null
  return {
    schema,
    keeper,
    source,
    producer,
    facts_store,
    episodes_store,
    recall_enabled: asBoolean(raw.recall_enabled, true) ?? true,
    now: asNumber(raw.now) ?? null,
    now_iso: asNullableString(raw.now_iso),
    read_errors: asRecordArray(raw.read_errors)
      .map((item) => {
        const scope = asString(item.scope)
        const error = asString(item.error)
        return scope && error ? { scope, error } : null
      })
      .filter((item): item is { scope: string; error: string } => item !== null),
    episodes: {
      ...episodesCounts,
      terminal_markers: asNumber(episodesRaw.terminal_markers, 0) ?? 0,
      items: asRecordArray(episodesRaw.items)
        .map(decodeMemoryOsEpisode)
        .filter((item): item is MemoryOsEpisodeSummary => item !== null),
    },
    facts,
  }
}

function decodeKeeperUserModelItem(raw: unknown): KeeperUserModelItem | null {
  if (!isRecord(raw)) return null
  const claim = asString(raw.claim)
  const category = asString(raw.category)
  const source = asString(raw.source)
  const turn = asNumber(raw.turn)
  const first_seen = asNumber(raw.first_seen)
  if (!claim || !category || !source || turn == null || first_seen == null) {
    return null
  }
  return {
    claim,
    category,
    source,
    observed_by: normalizeStringList(raw.observed_by),
    turn,
    first_seen,
    first_seen_iso: asNullableString(raw.first_seen_iso),
    last_verified_at: asNumber(raw.last_verified_at) ?? null,
    last_verified_at_iso: asNullableString(raw.last_verified_at_iso),
  }
}

function decodeKeeperUserModelSnapshot(raw: unknown): KeeperUserModelSnapshot | null {
  if (!isRecord(raw)) return null
  const schema = asString(raw.schema)
  const keeper = asString(raw.keeper)
  const source = asString(raw.source)
  const producer = asString(raw.producer)
  const facts_store = asString(raw.facts_store)
  const shared_facts_store = asString(raw.shared_facts_store)
  if (!schema || !keeper || !source || !producer || !facts_store || !shared_facts_store) {
    return null
  }
  return {
    schema,
    keeper,
    source,
    producer,
    facts_store,
    shared_facts_store,
    enabled: asBoolean(raw.enabled, true) ?? true,
    now: asNumber(raw.now) ?? null,
    now_iso: asNullableString(raw.now_iso),
    read_errors: asRecordArray(raw.read_errors)
      .map((item) => {
        const scope = asString(item.scope)
        const error = asString(item.error)
        return scope && error ? { scope, error } : null
      })
      .filter((item): item is { scope: string; error: string } => item !== null),
    source_fact_count: asNumber(raw.source_fact_count, 0) ?? 0,
    shared_fact_count: asNumber(raw.shared_fact_count, 0) ?? 0,
    preferences: asRecordArray(raw.preferences)
      .map(decodeKeeperUserModelItem)
      .filter((item): item is KeeperUserModelItem => item !== null),
    constraints: asRecordArray(raw.constraints)
      .map(decodeKeeperUserModelItem)
      .filter((item): item is KeeperUserModelItem => item !== null),
  }
}

function decodeTurnRecordsResponse(raw: unknown): TurnRecordsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    count: asNumber(raw.count, 0),
    skipped_rows: asNumber(raw.skipped_rows, 0),
    memory_os: decodeMemoryOsSnapshot(raw.memory_os),
    user_model: decodeKeeperUserModelSnapshot(raw.user_model),
    entries: asRecordArray(raw.entries)
      .map(decodeTurnRecordRow)
      .filter((row): row is TurnRecordRow => row !== null),
  }
}

export function fetchKeeperTurnRecords(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<TurnRecordsResponse> {
  const params = limit != null ? `?limit=${limit}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/turn-records${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeTurnRecordsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper turn record payload')
    return decoded
  })
}

// ── Keeper turn transcript (RFC-0233 §7) ────────────────
// The operator request + keeper response for one turn, joined server-side
// on the turn_ref "<trace_id>#<absolute_turn>". Lazily fetched by the turn
// inspector so the transcript (which can be large) never bloats the
// turn-records list. Content is the same load-time redacted view the chat
// history endpoint serves (RFC-0132); `found` is false when no persisted
// row carries the requested turn_ref, in which case the inspector renders
// explicit absence rather than a fabricated transcript.

export type TurnTranscriptLine = {
  role: string
  content: string
  ts?: number
  // Writer-declared row kind; present (e.g. 'transport_failure') only on
  // non-utterance assistant rows so the inspector can mark a failed reply
  // distinctly rather than quoting it as the keeper's own words.
  kind?: string
}

export type TurnTranscript = {
  keeper: string
  turn_ref: string
  found: boolean
  source: string
  user: TurnTranscriptLine[]
  assistant: TurnTranscriptLine[]
}

function decodeTurnTranscriptLine(raw: unknown): TurnTranscriptLine | null {
  if (!isRecord(raw)) return null
  const role = asString(raw.role)
  if (!role) return null
  return {
    role,
    content: asString(raw.content) ?? '',
    ts: asNumber(raw.ts),
    kind: asString(raw.kind),
  }
}

function decodeTurnTranscript(raw: unknown): TurnTranscript | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const turn_ref = asString(raw.turn_ref)
  if (!keeper || !turn_ref) return null
  const decodeLines = (value: unknown): TurnTranscriptLine[] =>
    asRecordArray(value)
      .map(decodeTurnTranscriptLine)
      .filter((line): line is TurnTranscriptLine => line !== null)
  return {
    keeper,
    turn_ref,
    found: asBoolean(raw.found, false) ?? false,
    source: asString(raw.source) ?? 'keeper_chat_store',
    user: decodeLines(raw.user),
    assistant: decodeLines(raw.assistant),
  }
}

export function fetchKeeperTurnTranscript(
  name: string,
  turnRef: string,
  opts?: AbortableRequestOptions,
): Promise<TurnTranscript> {
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/turn-transcript?turn_ref=${encodeURIComponent(turnRef)}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeTurnTranscript(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper turn transcript payload')
    return decoded
  })
}

// ── Unified telemetry ──────────────────────────────────

export type TelemetrySource =
  | 'keeper_metric'
  | 'agent_event'
  | 'tool_call_io'
  | 'trajectory_tool_call'
  | 'tool_usage'
  | 'oas_event'
  | 'execution_receipt'
  | 'goal_event'
  | 'tool_metric'

export type TelemetryEntry = Record<string, unknown> & {
  source: TelemetrySource
  ts?: number
  ts_unix?: number
  timestamp?: number
  ts_iso?: string
}

export type TelemetryResponse = {
  generated_at: string
  generated_at_iso?: string
  dashboard_surface?: string
  source?: string
  retention?: Record<string, unknown>
  query?: Record<string, unknown>
  count: number
  total_matching_entries?: number
  offset?: number
  has_more?: boolean
  truncated?: boolean
  entries: TelemetryEntry[]
}

export type DashboardCacheEntryDetail = {
  key: string
  kind: string
  ttl_remaining_ms?: number
  stale_remaining_ms?: number
  computing_for_ms?: number
  has_stale_fallback?: boolean
}

export type DashboardCacheStatsResponse = {
  entries: number
  fresh: number
  stale: number
  expired: number
  ready_fresh: number
  ready_stale: number
  computing: number
  max_entries: number
  hits_total: number
  misses_total: number
  hit_ratio: number
  timeout_circuit_open: number
  timeout_circuit_tracked: number
  entries_truncated_to: number
  entry_details: DashboardCacheEntryDetail[]
}

export type TelemetrySourceSummary = TelemetryFreshnessMetadata & {
  source: string
  path?: string
  entry_count: number
  keepers?: Array<{ name: string; path: string }>
  keeper_count?: number
}

export type TelemetrySummaryResponse = {
  generated_at: string
  sources: TelemetrySourceSummary[]
  total_entries: number
}

function decodeTelemetrySource(value: unknown): TelemetrySource | null {
  switch (value) {
    case 'keeper_metric':
    case 'agent_event':
    case 'tool_call_io':
    case 'trajectory_tool_call':
    case 'tool_usage':
    case 'oas_event':
    case 'execution_receipt':
    case 'goal_event':
    case 'tool_metric':
      return value
    default:
      return null
  }
}

function decodeTelemetryEntry(raw: unknown): TelemetryEntry | null {
  if (!isRecord(raw)) return null
  const source = decodeTelemetrySource(raw.source)
  if (!source) return null
  return {
    ...raw,
    source,
    ts: asNumber(raw.ts),
    ts_unix: asNumber(raw.ts_unix),
    timestamp: asNumber(raw.timestamp),
    ts_iso: asString(raw.ts_iso),
  }
}

function decodeTelemetryResponse(raw: unknown): TelemetryResponse | null {
  if (!isRecord(raw)) return null
  const generatedAt = asString(raw.generated_at)
  if (!generatedAt) return null
  return {
    generated_at: generatedAt,
    generated_at_iso: asString(raw.generated_at_iso),
    dashboard_surface: asString(raw.dashboard_surface),
    source: asString(raw.source),
    retention: isRecord(raw.retention) ? raw.retention : undefined,
    query: isRecord(raw.query) ? raw.query : undefined,
    count: asNumber(raw.count, 0),
    total_matching_entries: asNumber(raw.total_matching_entries, asNumber(raw.count, 0)),
    offset: asNumber(raw.offset, 0),
    has_more: asBoolean(raw.has_more, false),
    truncated: asBoolean(raw.truncated, false),
    entries: asRecordArray(raw.entries)
      .map(decodeTelemetryEntry)
      .filter((entry): entry is TelemetryEntry => entry !== null),
  }
}

function decodeDashboardCacheEntryDetail(raw: unknown): DashboardCacheEntryDetail | null {
  if (!isRecord(raw)) return null
  const key = asString(raw.key)
  const kind = asString(raw.kind)
  if (!key || !kind) return null
  return {
    key,
    kind,
    ttl_remaining_ms: asNumber(raw.ttl_remaining_ms),
    stale_remaining_ms: asNumber(raw.stale_remaining_ms),
    computing_for_ms: asNumber(raw.computing_for_ms),
    has_stale_fallback: asBoolean(raw.has_stale_fallback),
  }
}

function decodeDashboardCacheStatsResponse(raw: unknown): DashboardCacheStatsResponse | null {
  if (!isRecord(raw)) return null
  return {
    entries: asNumber(raw.entries, 0),
    fresh: asNumber(raw.fresh, 0),
    stale: asNumber(raw.stale, 0),
    expired: asNumber(raw.expired, 0),
    ready_fresh: asNumber(raw.ready_fresh, 0),
    ready_stale: asNumber(raw.ready_stale, 0),
    computing: asNumber(raw.computing, 0),
    max_entries: asNumber(raw.max_entries, 0),
    hits_total: asNumber(raw.hits_total, 0),
    misses_total: asNumber(raw.misses_total, 0),
    hit_ratio: asNumber(raw.hit_ratio, 0),
    timeout_circuit_open: asNumber(raw.timeout_circuit_open, 0),
    timeout_circuit_tracked: asNumber(raw.timeout_circuit_tracked, 0),
    entries_truncated_to: asNumber(raw.entries_truncated_to, 0),
    entry_details: asRecordArray(raw.entry_details)
      .map(decodeDashboardCacheEntryDetail)
      .filter((entry): entry is DashboardCacheEntryDetail => entry !== null),
  }
}

function decodeTelemetrySourceSummary(raw: unknown): TelemetrySourceSummary | null {
  if (!isRecord(raw)) return null
  const source = asString(raw.source)
  if (!source) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    source,
    path: asString(raw.path),
    exists: asBoolean(raw.exists),
    entry_count: asNumber(raw.entry_count, 0),
    keepers: asRecordArray(raw.keepers)
      .map((keeper) => {
        const name = asString(keeper.name)
        const path = asString(keeper.path)
        return name && path ? { name, path } : null
      })
      .filter((keeper): keeper is { name: string; path: string } => keeper !== null),
    keeper_count: asNumber(raw.keeper_count),
  }
}

function decodeTelemetrySummaryResponse(raw: unknown): TelemetrySummaryResponse | null {
  if (!isRecord(raw)) return null
  const generatedAt = asString(raw.generated_at)
  if (!generatedAt) return null
  return {
    generated_at: generatedAt,
    sources: asRecordArray(raw.sources)
      .map(decodeTelemetrySourceSummary)
      .filter((summary): summary is TelemetrySourceSummary => summary !== null),
    total_entries: asNumber(raw.total_entries, 0),
  }
}

export function fetchTelemetry(opts?: {
  source?: TelemetrySource
  keeper?: string
  session_id?: string
  operation_id?: string
  worker_run_id?: string
  since_ms?: number
  until_ms?: number
  n?: number
  offset?: number
  signal?: AbortSignal
}): Promise<TelemetryResponse> {
  const params = new URLSearchParams()
  if (opts?.source) params.set('source', opts.source)
  if (opts?.keeper) params.set('keeper', opts.keeper)
  if (opts?.session_id) params.set('session_id', opts.session_id)
  if (opts?.operation_id) params.set('operation_id', opts.operation_id)
  if (opts?.worker_run_id) params.set('worker_run_id', opts.worker_run_id)
  if (typeof opts?.since_ms === 'number') params.set('since_ms', String(opts.since_ms))
  if (typeof opts?.until_ms === 'number') params.set('until_ms', String(opts.until_ms))
  if (typeof opts?.n === 'number') params.set('n', String(opts.n))
  if (typeof opts?.offset === 'number') params.set('offset', String(opts.offset))
  const qs = params.toString()
  return get<Record<string, unknown>>(`/api/v1/dashboard/telemetry${qs ? '?' + qs : ''}`, { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeTelemetryResponse(raw)
      if (!decoded) throw new Error('유효하지 않은 telemetry payload')
      return decoded
    })
}

export function fetchTelemetrySummary(opts?: AbortableRequestOptions): Promise<TelemetrySummaryResponse> {
  return get<Record<string, unknown>>('/api/v1/dashboard/telemetry/summary', { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeTelemetrySummaryResponse(raw)
      if (!decoded) throw new Error('유효하지 않은 telemetry summary payload')
      return decoded
    })
}

export function fetchDashboardCacheStats(opts?: AbortableRequestOptions): Promise<DashboardCacheStatsResponse> {
  return get<Record<string, unknown>>('/api/v1/dashboard/cache-stats', { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeDashboardCacheStatsResponse(raw)
      if (!decoded) throw new Error('유효하지 않은 dashboard cache stats payload')
      return decoded
    })
}

// --- Excuse Patterns ---

export type ExcusePattern = [string, string]

export function fetchExcusePatterns(): Promise<ExcusePattern[]> {
  return get<ExcusePattern[]>('/api/v1/dashboard/config/excuse-patterns')
}

export function updateExcusePatterns(patterns: ExcusePattern[]): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/dashboard/config/excuse-patterns', patterns)
}

// --- Memory Subsystems ---

export interface MemorySubsystemsSynapse {
  from_agent: string
  to_agent: string
  weight: number
  success_count: number
  failure_count: number
  last_updated: number
  created_at: number
  /** Newest-first list of (unix ts seconds, weight) points, capped at 30.
      Missing for graphs produced by pre-sparkline backends. */
  weight_history?: Array<[number, number]>
}

export interface MemorySubsystemsEpisode {
  id: string
  timestamp: number
  participants: string[]
  event_type: string
  summary: string
  outcome: string
  learnings: string[]
  context: Record<string, string>
}

export interface MemorySubsystemsMemoryEntry {
  keeper: string
  kind: string
  text: string
  priority: number
  ts_unix: number
}

/** RFC-0149 §3.1 — per-keeper memory bank read failure, surfaced as
 *  a typed sibling field next to the entry rows.  `error_class` is one
 *  of the closed 4-value `Keeper_memory_recall_exn_class.t` labels
 *  (`yojson_parse_error | io_error | type_error | other`). */
export interface MemorySubsystemsMemoryEntryError {
  keeper: string
  error_class: string
}

export interface MemorySubsystemsUserModelItem {
  keeper: string
  kind: 'preference' | 'constraint' | string
  claim: string
  source_ref: string
  source_trace_id: string
  source_turn: number
  first_seen: number
  last_verified_at: number | null
  observed_by: string[]
}

export interface MemorySubsystemsUserModelError {
  keeper: string
  error: string
}

export interface MemorySubsystemsUserModelPrompt {
  enabled: boolean
  block_id: string
  injection: string
  runtime_hook: string
  producer?: string
}

export interface MemorySubsystemsDraftSkillCandidate {
  id: string
  agent_name: string
  source_kind: string
  source_ref: string
  promotion_state: string
  dir: string
  json_path: string
  toml_path: string
  skill_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsDelegationRequest {
  id: string
  requester: string
  topic: string
  goal: string | null
  promotion_state: string
  dir: string
  json_path: string
  task_seed_md_path: string
  created_at: number | null
}

export interface MemorySubsystemsResponse {
  generated_at: string
  hebbian: {
    synapses: MemorySubsystemsSynapse[]
    last_consolidation: number
  }
  episodes: {
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsEpisode[]
  }
  memory_entries?: {
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsMemoryEntry[]
    /** RFC-0149 §3.1 — per-keeper memory bank read failures.  Each
     *  entry means that keeper's `memory.jsonl` could not be read and
     *  the corresponding rows are absent from `items`; the rest of
     *  `items` is still trustworthy. */
    errors?: MemorySubsystemsMemoryEntryError[]
  }
  user_model?: {
    schema: string
    source: string
    prompt?: MemorySubsystemsUserModelPrompt
    total: number
    filtered: number
    shown: number
    limit: number
    items: MemorySubsystemsUserModelItem[]
    errors?: MemorySubsystemsUserModelError[]
  }
  draft_skill_candidates?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDraftSkillCandidate[]
    error?: string | null
  }
  delegation_requests?: {
    total: number
    shown: number
    limit: number
    index_path: string
    items: MemorySubsystemsDelegationRequest[]
    error?: string | null
  }
  filters: {
    keepers: string[]
    outcomes: string[]
    memory_kinds?: string[]
  }
}

interface MemorySubsystemsQuery {
  limit?: number
  keeper?: string
  outcome?: string
  q?: string
  includeMemoryEntries?: boolean
  signal?: AbortSignal
}

export function fetchMemorySubsystems(
  opts?: MemorySubsystemsQuery,
): Promise<MemorySubsystemsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit != null) params.set('limit', String(opts.limit))
  if (opts?.keeper) params.set('keeper', opts.keeper)
  if (opts?.outcome) params.set('outcome', opts.outcome)
  if (opts?.q) params.set('q', opts.q)
  if (opts?.includeMemoryEntries) params.set('include_memory_entries', 'true')
  const qs = params.toString()
  return get<MemorySubsystemsResponse>(
    `/api/v1/dashboard/memory-subsystems${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

// --- Keeper Memory Health ---

export interface KeeperMemoryHealthKeeperEntry {
  keeper_id: string
  facts: number
  facts_bytes: number
  events: number
  events_bytes: number
  events_to_facts_ratio: number
  ttl_expired_on_disk: number
  near_duplicate: number
  external_ref: number
}

export interface KeeperMemoryHealthResponse {
  generated_at: number
  cadence_counter_entries: number
  keepers: KeeperMemoryHealthKeeperEntry[]
  totals: {
    facts: number
    facts_bytes: number
    events_bytes: number
    ttl_expired_on_disk: number
    near_duplicate: number
  }
}

export function fetchKeeperMemoryHealth(): Promise<KeeperMemoryHealthResponse> {
  return get<KeeperMemoryHealthResponse>('/api/v1/dashboard/keeper-memory-health')
}

// --- Verification requests (Mission detail table) ---
// Backend: lib/dashboard/dashboard_verification.ml
// Route:   GET /api/v1/verification/requests?task_id=&limit=
// Shape is stable; status values match the Verification state machine's
// user-visible mapping (pending → approved | rejected, plus a reserved
// timed_out slot for the deadline watcher).

export type VerificationRequestStatus =
  | 'pending'
  | 'approved'
  | 'rejected'
  | 'timed_out'

export type VerificationRequestVerdict = 'pass' | 'fail' | 'partial' | null

export interface VerificationRequest {
  request_id: string
  task_id: string
  task_title: string
  request_kind: 'normal' | 'conflict_triage'
  request_summary: string
  next_action: string | null
  keeper: string | null
  status: VerificationRequestStatus
  created_at: string
  submitted_by: string
  approved_by: string | null
  completion_contract: string[]
  required_evidence: string[]
  verdict: VerificationRequestVerdict
  verdict_reason: string
}

export interface VerificationRequestsResponse {
  updated_at: string
  total: number
  requests: VerificationRequest[]
}

interface FetchVerificationRequestsOptions {
  taskId?: string
  limit?: number
  signal?: AbortSignal
}

export function fetchVerificationRequests(
  opts?: FetchVerificationRequestsOptions,
): Promise<VerificationRequestsResponse> {
  const params = new URLSearchParams()
  if (opts?.taskId && opts.taskId.trim() !== '') {
    params.set('task_id', opts.taskId.trim())
  }
  if (opts?.limit != null) {
    params.set('limit', String(opts.limit))
  }
  const qs = params.toString()
  const path = qs.length > 0
    ? `/api/v1/verification/requests?${qs}`
    : '/api/v1/verification/requests'
  return get<VerificationRequestsResponse>(path, { signal: opts?.signal })
}

interface ResolveVerificationRequestOptions {
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  reason?: string
}

interface ResolveVerificationResponse {
  ok: boolean
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  verifier: string
}

export function resolveVerificationRequest(
  opts: ResolveVerificationRequestOptions,
): Promise<ResolveVerificationResponse> {
  return post<ResolveVerificationResponse>('/api/v1/verification/resolve', {
    task_id: opts.task_id,
    verification_id: opts.verification_id,
    decision: opts.decision,
    reason: opts.reason ?? '',
  })
}

export type TlaSpecCategory = 'boundary' | 'bug-models' | 'other'

export interface TlaSpecEntry {
  name: string
  path: string
  category: TlaSpecCategory
  has_clean_cfg: boolean
  has_buggy_cfg: boolean
  mtime_iso: string
}

export interface TlaSpecsResponse {
  updated_at: string
  specs_dir: string | null
  count: number
  entries: TlaSpecEntry[]
}

export function fetchTlaSpecs(
  opts?: AbortableRequestOptions,
): Promise<TlaSpecsResponse> {
  return get<TlaSpecsResponse>('/api/v1/verification/specs', {
    signal: opts?.signal,
  })
}

export type TlcResultStatus =
  | 'passed'
  | 'violated'
  | 'running'
  | 'queued'
  | 'error'
  | 'not_run'

export interface TlcResultEntry {
  spec_name: string
  cfg_name: string
  category: TlaSpecCategory
  status: TlcResultStatus
  states_explored: number | null
  distinct_states: number | null
  diameter: number | null
  last_run_at: string | null
  violation: string | null
  log_path: string | null
}

export interface TlcResultsResponse {
  updated_at: string
  results_dir: string | null
  count: number
  entries: TlcResultEntry[]
}

export function fetchTlcResults(
  opts?: AbortableRequestOptions,
): Promise<TlcResultsResponse> {
  return get<TlcResultsResponse>('/api/v1/verification/tlc-results', {
    signal: opts?.signal,
  })
}

export interface AuditEntry {
  id: string
  ts: string
  actor: string
  kind: string
  target?: string
  summary: string
  severity: string
  payload?: unknown
}

export interface AuditLedgerResponse {
  entries: AuditEntry[]
  count: number
}

export interface AuditLedgerParams {
  limit?: number
  actor?: string
  kind?: string
  severity?: string
  since?: number
  until?: number
}

export function fetchAuditLedger(
  params: AuditLedgerParams = {},
  opts?: { signal?: AbortSignal },
): Promise<AuditLedgerResponse> {
  const { limit = 100, actor, kind, severity, since, until } = params
  const qs = new URLSearchParams()
  qs.set('limit', String(limit))
  if (actor) qs.set('actor', actor)
  if (kind) qs.set('kind', kind)
  if (severity) qs.set('severity', severity)
  if (since != null) qs.set('since', String(since))
  if (until != null) qs.set('until', String(until))
  return get<AuditLedgerResponse>(`/api/v1/audit?${qs.toString()}`, {
    signal: opts?.signal,
  })
}

// ── O4 Cost & Latency aggregator ─────────────────────────────────────
// Consumes /api/v1/dashboard/cost-latency and exposes the composed
// payload required by the CostPerAgent / CostMatrix / CostLatency
// frontend components (Phase 2 spec cb-group-f.jsx:291-429).

export interface CostPerAgentRow {
  agent: string
  in_tok: number
  out_tok: number
  cost: number
  p50_ms: number | null
  p95_ms: number | null
}

export interface CostMatrix {
  providers: string[]
  models: string[]
  grid: number[][]
}

export interface CostLatencyBucket {
  lo: number
  hi: number | null
  n: number
}

export interface CostLatencyResponse {
  perAgent: CostPerAgentRow[]
  matrix: CostMatrix
  latencyBuckets: CostLatencyBucket[]
  p50: number | null
  p95: number | null
  total_cost_usd: number
  window_minutes: number
  generated_at: number
}

function decodeCostPerAgentRow(raw: unknown): CostPerAgentRow | null {
  if (!isRecord(raw)) return null
  const agent = asString(raw.agent)
  if (!agent) return null
  return {
    agent,
    in_tok: asNumber(raw.in_tok) ?? 0,
    out_tok: asNumber(raw.out_tok) ?? 0,
    cost: asNumber(raw.cost) ?? 0,
    p50_ms: asNumber(raw.p50_ms) ?? null,
    p95_ms: asNumber(raw.p95_ms) ?? null,
  }
}

function decodeCostMatrix(raw: unknown): CostMatrix | null {
  if (!isRecord(raw)) return null
  const rawModels = asStringArray(raw.models)
  const rawGrid = Array.isArray(raw.grid)
    ? (raw.grid as unknown[]).map(row =>
        Array.isArray(row)
          ? (row as unknown[]).map(v => asNumber(v) ?? 0)
          : []
      )
    : []
  const colCount = Math.max(
    rawModels.length,
    rawGrid.reduce((max, row) => Math.max(max, row.length), 0),
  )
  const models = Array.from({ length: colCount }, (_, index) =>
    rawModels[index] ?? runtimeLaneLabel(index),
  )
  const providers = colCount > 0 || asStringArray(raw.providers).length > 0 ? ['runtime'] : []
  const grid = providers.length === 0
    ? []
    : [
        Array.from({ length: colCount }, (_, column) =>
          rawGrid.reduce((sum, row) => sum + (row[column] ?? 0), 0),
        ),
      ]
  return { providers, models, grid }
}

function decodeCostLatencyResponse(raw: unknown): CostLatencyResponse | null {
  if (!isRecord(raw)) return null
  const matrix = decodeCostMatrix(raw.matrix)
  if (!matrix) return null
  return {
    perAgent: asRecordArray(raw.perAgent)
      .map(row => decodeCostPerAgentRow(row))
      .filter((r): r is CostPerAgentRow => r !== null),
    matrix,
    latencyBuckets: Array.isArray(raw.latencyBuckets)
      ? (raw.latencyBuckets as unknown[])
          .filter(isRecord)
          .map(b => ({
            lo: asNumber(b.lo) ?? 0,
            hi: b.hi == null ? null : (asNumber(b.hi) ?? null),
            n: asNumber(b.n) ?? 0,
          }))
      : [],
    p50: asNumber(raw.p50) ?? null,
    p95: asNumber(raw.p95) ?? null,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? 0,
    window_minutes: asNumber(raw.window_minutes) ?? DEFAULT_WINDOW_MINUTES_24H,
    generated_at: asNumber(raw.generated_at) ?? 0,
  }
}

export async function fetchCostLatency(
  windowMinutes = DEFAULT_WINDOW_MINUTES_24H,
  opts?: AbortableRequestOptions,
): Promise<CostLatencyResponse> {
  const raw = await get<Record<string, unknown>>(
    `/api/v1/dashboard/cost-latency?window=${windowMinutes}`,
    { signal: opts?.signal },
  )
  const decoded = decodeCostLatencyResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 cost-latency payload')
  return decoded
}
