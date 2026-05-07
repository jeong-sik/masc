// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import { isRecord, asBoolean, asInt, asNullableString, asNumber, asRecordArray, asString, asStringArray } from '../components/common/normalize'
import {
  asNullableIsoTimestamp,
  normalizeGovernanceDecisionItem,
  normalizeGovernanceTimelineEvent,
  normalizeGovernanceJudgeSummary,
  normalizeGovernanceJudgment,
  normalizeKeeperApprovalQueueItem,
  normalizePendingConfirmation,
} from './board'
import { normalizeKeeperTrustTerminalReason } from '../keeper-store-normalize'
import { currentDashboardActor, get, post, patch, withRetries, NAMESPACE_TRUTH_GET_TIMEOUT_MS } from './core'
import {
  parseAgentRelationsResponse,
  type AgentRelationsResponse,
} from './schemas/agent-relations'
import {
  parseAgentTimelineResponse,
  type AgentTimelineEvent,
  type AgentTimelineResponse,
} from './schemas/agent-timeline'
import { parseLogsResponse, type LogEntry, type LogsResponse } from './schemas/logs'
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
  GoalTreeNode,
  GoalTreeSummary,
  GoalTreeTask,
  GoalVerificationRequest,
  GoalVerificationSummary,
  GoalVerificationVote,
  DashboardNamespaceTruthResponse,
  DashboardShellResponse,
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
export {
  fetchCascadeAuditRuns,
  fetchCascadeClientCapacity,
  fetchCascadeClientCapacityHistory,
  fetchCascadeConfig,
  fetchCascadeConfigRaw,
  fetchCascadeHealth,
  fetchCascadeProfiles,
  fetchCascadeSlo,
  fetchCascadeStrategyTrace,
  updateCascadeConfigRaw,
  updateKeeperCascade,
} from './dashboard-cascade'
export type {
  CascadeAuditHop,
  CascadeAuditHopStatus,
  CascadeAuditRun,
  CascadeAuditRunsResponse,
  CascadeCandidate,
  CascadeCapacityEventKind,
  CascadeClientCapacityEntry,
  CascadeClientCapacityHistoryEvent,
  CascadeClientCapacityHistoryResponse,
  CascadeClientCapacityResponse,
  CascadeConfigResponse,
  CascadeHealthProvider,
  CascadeHealthResponse,
  CascadeProviderStatus,
  CascadeInvalidProfile,
  CascadeKeeperProfile,
  CascadeProfile,
  CascadeRawConfigResponse,
  CascadeSloResponse,
  CascadeSloStatus,
  CascadeStrategyTraceEvent,
  CascadeStrategyTraceKind,
  CascadeStrategyTraceResponse,
  CascadeValidationStatus,
} from './dashboard-cascade'
export { reportToolHostFailure } from './tool-host-failure'

// --- Dashboard projections ---

type AbortableRequestOptions = {
  signal?: AbortSignal
}

type DashboardShellRequestOptions = AbortableRequestOptions & {
  light?: boolean
}

export function fetchDashboardShell(opts?: DashboardShellRequestOptions): Promise<DashboardShellResponse> {
  const qs = opts?.light ? '?light=true' : ''
  return get(`/api/v1/dashboard/shell${qs}`, { signal: opts?.signal })
}

// --- System logs ---

export type { LogEntry, LogsResponse }
export { LogsSchemaDriftError } from './schemas/logs'

export async function fetchLogs(opts?: {
  limit?: number
  level?: string
  module?: string
  since_seq?: number
}): Promise<LogsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit) params.set('limit', String(opts.limit))
  if (opts?.level) params.set('level', opts.level)
  if (opts?.module) params.set('module', opts.module)
  if (typeof opts?.since_seq === 'number' && opts.since_seq >= 0) {
    params.set('since_seq', String(opts.since_seq))
  }
  const qs = params.toString()
  const raw = await get<unknown>(`/api/v1/dashboard/logs${qs ? `?${qs}` : ''}`)
  return parseLogsResponse(raw)
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

export type ConfigEntrySource = 'env' | 'default' | 'derived' | 'runtime'

export interface ConfigEntryProvenance {
  kind: ConfigEntrySource
  detail: string
  derived_from?: string[]
}

export interface ConfigEntry {
  env: string
  description: string
  value: string | null
  default: string
  source: ConfigEntrySource
  source_detail?: string
  provenance?: ConfigEntryProvenance
  sensitive: boolean
}

export interface DashboardConfigResponse {
  generated_at: string
  server: {
    version: string
    git_commit: string | null
    ocaml_version: string
    uptime_seconds: number
    pid: number
  }
  categories: Record<string, ConfigEntry[]>
}

export function fetchDashboardConfig(): Promise<DashboardConfigResponse> {
  return get('/api/v1/dashboard/config')
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

export function fetchDashboardNamespaceTruth(opts?: AbortableRequestOptions): Promise<DashboardNamespaceTruthResponse> {
  return get('/api/v1/dashboard/project-snapshot', {
    timeoutMs: NAMESPACE_TRUTH_GET_TIMEOUT_MS,
    signal: opts?.signal,
  })
}

export function fetchDashboardExecution(opts?: AbortableRequestOptions): Promise<DashboardExecutionResponse> {
  return get('/api/v1/dashboard/execution', { signal: opts?.signal })
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

export type ToolQualityResponse = {
  source?: string
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  freshness_slo_s?: number
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
  health?: string
  stale_reason?: string | null
  entry_count?: number
  exists?: boolean
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
    max_risk: asNullableString(raw.max_risk) ?? undefined,
    created_at: asNullableIsoTimestamp(raw.created_at_iso ?? raw.created_at),
    created_by: asNullableString(raw.created_by),
    last_matched_at:
      asNullableIsoTimestamp(raw.last_matched_at_iso ?? raw.last_matched_at),
    match_count: asInt(raw.match_count) ?? undefined,
    source_approval_id: asNullableString(raw.source_approval_id),
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

export function fetchDashboardMission(): Promise<DashboardMissionResponse> {
  return get('/api/v1/dashboard/mission')
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
  kind?: string | null
  runtime_kind?: string | null
  auth_kind?: string | null
  status?: string | null
  available?: boolean
  supports_single_agent_run?: boolean
  default_model?: string | null
  model_count?: number | null
  models: string[]
  source?: string | null
  endpoint_url?: string | null
  note?: string | null
  discovery?: DashboardRuntimeProviderDiscovery | null
}

export interface DashboardRuntimeProvidersResponse {
  updated_at?: string
  summary?: {
    providers?: number
    local_models?: number
    cloud_models?: number
    cli_models?: number
  } | null
  providers: DashboardRuntimeProviderSnapshot[]
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
   * think=true. Reflects the Keeper_turn_intent adaptive classifier decision
   * (Cognitive=true → thinking, Mechanical=false → no thinking). Null when no
   * entry in the window reported thinking_enabled (older rows or providers
   * that don't expose the field).
   */
  thinking_fraction?: number | null
  avg_latency_ms?: number | null
  p50_latency_ms?: number | null
  p95_latency_ms?: number | null
  total_input_tokens?: number | null
  total_output_tokens?: number | null
  total_cache_read_tokens?: number | null
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

function decodeRuntimeProviderDiscovery(raw: unknown): DashboardRuntimeProviderDiscovery | null {
  if (!isRecord(raw)) return null
  return {
    healthy: asBoolean(raw.healthy),
    discovered_model: asNullableString(raw.discovered_model),
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
    kind: asNullableString(raw.kind),
    runtime_kind: asNullableString(raw.runtime_kind),
    auth_kind: asNullableString(raw.auth_kind),
    status: asNullableString(raw.status),
    available: asBoolean(raw.available),
    supports_single_agent_run: asBoolean(raw.supports_single_agent_run),
    default_model: asNullableString(raw.default_model),
    model_count: asNumber(raw.model_count) ?? null,
    models: asStringArray(raw.models),
    source: asNullableString(raw.source),
    endpoint_url: asNullableString(raw.endpoint_url),
    note: asNullableString(raw.note),
    discovery: decodeRuntimeProviderDiscovery(raw.discovery),
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
          local_models: asNumber(summary.local_models),
          cloud_models: asNumber(summary.cloud_models),
          cli_models: asNumber(summary.cli_models),
        }
      : null,
    providers: asRecordArray(raw.providers)
      .map(decodeRuntimeProviderSnapshot)
      .filter((provider): provider is DashboardRuntimeProviderSnapshot => provider !== null),
  }
}

function decodeRuntimeModelMetric(raw: unknown): DashboardRuntimeModelMetric | null {
  if (!isRecord(raw)) return null
  const modelId = asString(raw.model_id)
  if (!modelId) return null
  return {
    model_id: modelId,
    provider: asNullableString(raw.provider),
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
      .map(decodeRuntimeModelMetric)
      .filter((metric): metric is DashboardRuntimeModelMetric => metric !== null),
  }
}

export async function fetchRuntimeProviders(opts?: AbortableRequestOptions): Promise<DashboardRuntimeProvidersResponse> {
  const raw = await get<Record<string, unknown>>('/api/v1/providers', { signal: opts?.signal })
  const decoded = decodeRuntimeProvidersResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 runtime providers payload')
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
  return {
    keeper_name: keeperName,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? 0,
    total_input_tokens: asNumber(raw.total_input_tokens) ?? 0,
    total_output_tokens: asNumber(raw.total_output_tokens) ?? 0,
    total_tokens: asNumber(raw.total_tokens) ?? 0,
    p50_latency_ms: asNumber(raw.p50_latency_ms) ?? null,
    p95_latency_ms: asNumber(raw.p95_latency_ms) ?? null,
    sample_count: asNumber(raw.sample_count) ?? 0,
    model_breakdown: Array.isArray(raw.model_breakdown)
      ? (raw.model_breakdown as unknown[])
          .filter(isRecord)
          .map(b => ({ model: asString(b.model) ?? '', cost_usd: asNumber(b.cost_usd) ?? 0 }))
          .filter(b => b.model.length > 0)
      : [],
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
  windowMinutes = 1440,
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
}

export interface KeeperDecisionsResponse {
  events: KeeperDecision[]
  limit: number
  generated_at: number | null
}

function decodeKeeperDecision(raw: unknown): KeeperDecision | null {
  if (!isRecord(raw)) return null
  return {
    ts_unix: asNumber(raw.ts_unix) ?? null,
    keeper_name: asString(raw.keeper_name) ?? '',
    event_type: asString(raw.event_type) ?? 'turn',
    outcome: asNullableString(raw.outcome),
    model_used: asNullableString(raw.model_used),
    latency_ms: asNumber(raw.latency_ms) ?? null,
    cost_usd: asNumber(raw.cost_usd) ?? null,
    input_tokens: asNumber(raw.input_tokens) ?? null,
    output_tokens: asNumber(raw.output_tokens) ?? null,
    stop_reason: asNullableString(raw.stop_reason),
    error_category: asNullableString(raw.error_category),
    tool: asNullableString(raw.tool),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    match_count: asNumber(raw.match_count) ?? null,
  }
}

function decodeKeeperDecisionsResponse(raw: unknown): KeeperDecisionsResponse | null {
  if (!isRecord(raw)) return null
  return {
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

export interface HeuristicEvent {
  module: string
  site: string
  raw_value: number
  threshold: number
  triggered: boolean
  provenance: { type: string; detail: string }
  timestamp: number
  detail?: string
}

export interface HeuristicFiring {
  id: string
  ts: number
  rule_id: string
  agent?: string
  action: string
  cooldown_remaining_ms?: number
}

export interface HeuristicsResponse {
  limit: number
  count: number
  events: HeuristicEvent[]
  heuristics: HeuristicFiring[]
}

function decodeHeuristicEvent(raw: unknown): HeuristicEvent | null {
  if (!isRecord(raw)) return null
  const prov = isRecord(raw.provenance) ? raw.provenance : null
  return {
    module: asString(raw.module) ?? '',
    site: asString(raw.site) ?? '',
    raw_value: asNumber(raw.raw_value) ?? 0,
    threshold: asNumber(raw.threshold) ?? 0,
    triggered: asBoolean(raw.triggered) ?? false,
    provenance: prov
      ? { type: asString(prov.type) ?? '', detail: asString(prov.detail) ?? '' }
      : { type: '', detail: '' },
    timestamp: asNumber(raw.timestamp) ?? 0,
    detail: asNullableString(raw.detail) ?? undefined,
  }
}

function decodeHeuristicFiring(raw: unknown): HeuristicFiring | null {
  if (!isRecord(raw)) return null
  return {
    id: asString(raw.id) ?? '',
    ts: asNumber(raw.ts) ?? 0,
    rule_id: asString(raw.rule_id) ?? '',
    agent: asNullableString(raw.agent) ?? undefined,
    action: asString(raw.action) ?? '',
    cooldown_remaining_ms: raw.cooldown_remaining_ms === undefined
      ? undefined
      : (asInt(raw.cooldown_remaining_ms) ?? 0),
  }
}

function decodeHeuristicsResponse(raw: unknown): HeuristicsResponse | null {
  if (!isRecord(raw)) return null
  return {
    limit: asInt(raw.limit) ?? 0,
    count: asInt(raw.count) ?? 0,
    events: asRecordArray(raw.events)
      .map(decodeHeuristicEvent)
      .filter((e): e is HeuristicEvent => e !== null),
    heuristics: asRecordArray(raw.heuristics)
      .map(decodeHeuristicFiring)
      .filter((e): e is HeuristicFiring => e !== null),
  }
}

export async function fetchHeuristics(
  limit = 100,
  opts?: AbortableRequestOptions,
): Promise<HeuristicsResponse> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/heuristics?limit=${limit}`, { signal: opts?.signal })
  const decoded = decodeHeuristicsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 heuristics payload')
  return decoded
}

export interface StressKind {
  type: string
  count?: number
  consecutive?: number
  threshold?: number
  counted_toward_crash?: boolean
  recoverable?: boolean
  error_kind?: string
}

export interface StressEvent {
  agent_name: string
  room_id: string
  kind: StressKind
  timestamp: number
}

export interface StressResponse {
  limit: number
  count: number
  events: StressEvent[]
  agent_stress: AgentStressRow[]
}

export interface AgentStressRow {
  agent: string
  budget_pressure: number
  ctx_pressure: number
  queue_depth: number
  blocked_on?: string
  ts: number
  budget_pressure_source?: string
  ctx_pressure_source?: string
  queue_depth_source?: string
}

function decodeStressKind(raw: unknown): StressKind | null {
  if (!isRecord(raw)) return null
  return {
    type: asString(raw.type) ?? '',
    count: asInt(raw.count) ?? undefined,
    consecutive: asInt(raw.consecutive) ?? undefined,
    threshold: asInt(raw.threshold) ?? undefined,
    counted_toward_crash: raw.counted_toward_crash === undefined ? undefined : (asBoolean(raw.counted_toward_crash) ?? false),
    recoverable: raw.recoverable === undefined ? undefined : (asBoolean(raw.recoverable) ?? false),
    error_kind: asNullableString(raw.error_kind) ?? undefined,
  }
}

function decodeStressEvent(raw: unknown): StressEvent | null {
  if (!isRecord(raw)) return null
  const kind = decodeStressKind(raw.kind)
  if (!kind) return null
  return {
    agent_name: asString(raw.agent_name) ?? '',
    room_id: asString(raw.room_id) ?? '',
    kind,
    timestamp: asNumber(raw.timestamp) ?? 0,
  }
}

function decodeAgentStressRow(raw: unknown): AgentStressRow | null {
  if (!isRecord(raw)) return null
  return {
    agent: asString(raw.agent) ?? '',
    budget_pressure: asNumber(raw.budget_pressure) ?? 0,
    ctx_pressure: asNumber(raw.ctx_pressure) ?? 0,
    queue_depth: asInt(raw.queue_depth) ?? 0,
    blocked_on: asNullableString(raw.blocked_on) ?? undefined,
    ts: asNumber(raw.ts) ?? 0,
    budget_pressure_source: asNullableString(raw.budget_pressure_source) ?? undefined,
    ctx_pressure_source: asNullableString(raw.ctx_pressure_source) ?? undefined,
    queue_depth_source: asNullableString(raw.queue_depth_source) ?? undefined,
  }
}

function decodeStressResponse(raw: unknown): StressResponse | null {
  if (!isRecord(raw)) return null
  return {
    limit: asInt(raw.limit) ?? 0,
    count: asInt(raw.count) ?? 0,
    events: asRecordArray(raw.events)
      .map(decodeStressEvent)
      .filter((e): e is StressEvent => e !== null),
    agent_stress: asRecordArray(raw.agent_stress)
      .map(decodeAgentStressRow)
      .filter((row): row is AgentStressRow => row !== null),
  }
}

export async function fetchStress(
  limit = 100,
  opts?: AbortableRequestOptions,
): Promise<StressResponse> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/stress?limit=${limit}`, { signal: opts?.signal })
  const decoded = decodeStressResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 stress payload')
  return decoded
}

export interface CoverageSite {
  module: string
  site: string
  count: number
  triggered_count: number
}

export interface HeuristicCoverage {
  total_events: number
  decision_shape_count: number
  mixed_outcome_sites: number
  unique_decision_tuples: number
  sites: CoverageSite[]
}

function decodeCoverageSite(raw: unknown): CoverageSite | null {
  if (!isRecord(raw)) return null
  return {
    module: asString(raw.module) ?? '',
    site: asString(raw.site) ?? '',
    count: asInt(raw.count) ?? 0,
    triggered_count: asInt(raw.triggered_count) ?? 0,
  }
}

function decodeHeuristicCoverage(raw: unknown): HeuristicCoverage | null {
  if (!isRecord(raw)) return null
  const decisionShapeCount = asInt(raw.decision_shape_count) ?? asInt(raw.unique_decision_tuples) ?? 0
  return {
    total_events: asInt(raw.total_events) ?? 0,
    decision_shape_count: decisionShapeCount,
    mixed_outcome_sites: asInt(raw.mixed_outcome_sites) ?? 0,
    unique_decision_tuples: decisionShapeCount,
    sites: asRecordArray(raw.sites)
      .map(decodeCoverageSite)
      .filter((s): s is CoverageSite => s !== null),
  }
}

export async function fetchHeuristicCoverage(
  limit = 100,
  opts?: AbortableRequestOptions,
): Promise<HeuristicCoverage> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/heuristics/coverage?limit=${limit}`, { signal: opts?.signal })
  const decoded = decodeHeuristicCoverage(raw)
  if (!decoded) throw new Error('유효하지 않은 heuristic coverage payload')
  return decoded
}

export function fetchDashboardMissionBriefing(
  force = false,
  opts?: { signal?: AbortSignal },
): Promise<DashboardMissionBriefingResponse> {
  const query = force ? '?force=1' : ''
  return get(`/api/v1/dashboard/mission/briefing${query}`, { signal: opts?.signal })
}

export function fetchDashboardPlanning(): Promise<DashboardPlanningResponse> {
  return get('/api/v1/dashboard/planning')
}

function decodeGoalVerificationPrincipal(
  raw: unknown,
): GoalVerificationRequest['requested_by'] | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const id = asString(raw.id)
  if (!kind || !id) return null
  return {
    kind,
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
  }
}

function decodeGoalKeeperTrustApprovalState(raw: unknown): GoalKeeperTrustApprovalState | null {
  if (!isRecord(raw)) return null
  return {
    state: asNullableString(raw.state),
    summary: asNullableString(raw.summary),
    pending_count: asInt(raw.pending_count) ?? null,
  }
}

function decodeGoalKeeperTrustExecutionSummary(raw: unknown): GoalKeeperTrustExecutionSummary | null {
  if (!isRecord(raw)) return null
  return {
    tool_contract_result: asNullableString(raw.tool_contract_result),
    sandbox_summary: asNullableString(raw.sandbox_summary),
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
  return {
    id,
    title,
    horizon: asString(raw.horizon, 'unknown'),
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
    due_date: asNullableString(raw.due_date),
    parent_goal_id: asNullableString(raw.parent_goal_id),
    convergence: asNumber(raw.convergence, 0),
    convergence_pct: asInt(raw.convergence_pct) ?? 0,
    attainment: decodeGoalAttainmentProjection(raw.attainment, {
      metric,
      targetValue,
      taskDoneCount,
      taskCount,
    }),
    tasks,
    task_count: taskCount,
    task_done_count: taskDoneCount,
    verification_summary: decodeGoalVerificationSummary(raw.verification_summary),
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
  const cascadeName = asString(raw.cascade_name)
  if (!name || !agentName || !sandboxProfile || !networkMode || !cascadeName) return null
  return {
    name,
    agent_name: agentName,
    current_task_id: asNullableString(raw.current_task_id),
    active_goal_ids: asStringArray(raw.active_goal_ids),
    sandbox_profile: sandboxProfile,
    network_mode: networkMode,
    cascade_name: cascadeName,
    approval_profile: asNullableString(raw.approval_profile),
    cascade_outcome: asNullableString(raw.cascade_outcome),
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

export interface ToolMetricsResponse {
  source?: string
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  freshness_slo_s?: number | null
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
  health?: string
  stale_reason?: string | null
  entry_count?: number
  exists?: boolean
  total_calls: number
  distinct_tools_called: number
  top_20: ToolMetricsTopEntry[]
  never_called_count: number
  tool_distribution?: { total: number; public: number; visible: number; hidden: number } | null
  dispatch_v2_enabled: boolean
  registered_count: number
}

export interface DashboardToolsResponse {
  generated_at?: string
  config_resolution?: DashboardConfigResolution
  runtime_resolution?: DashboardRuntimeResolution
  tool_inventory: DashboardToolInventoryResponse
  tool_usage: ToolMetricsResponse
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

interface DashboardRuntimeProbePayload {
  source?: string
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
  probe?: DashboardRuntimeProbePayload | null
}

export function fetchToolMetrics(): Promise<ToolMetricsResponse> {
  return get('/api/v1/tool-metrics')
}

export function fetchDashboardRuntimeProbe(
  force = false,
  opts?: AbortableRequestOptions,
): Promise<DashboardRuntimeProbeResponse> {
  const query = force ? '?force=1' : ''
  return get(`/api/v1/dashboard/runtime-probe${query}`, { signal: opts?.signal })
}

export async function fetchDashboardTools(opts?: AbortableRequestOptions): Promise<DashboardToolsResponse> {
  const raw = await get<DashboardToolsResponse>('/api/v1/dashboard/tools', { signal: opts?.signal })
  const normalizedTools = raw.tool_inventory?.tools?.map(t => ({
    ...t,
    category: t.category ?? 'uncategorized',
    tier: t.tier ?? 'standard',
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

function normalizeKeeperConfigActiveGoals(raw: unknown): KeeperConfig['coordination']['active_goals'] {
  return asRecordArray(raw)
    .map((item) => {
      const id = asNullableString(item.id)
      const title = asNullableString(item.title)
      const horizon = asNullableString(item.horizon)
      if (!id || !title || !horizon) return null
      return { id, title, horizon }
    })
    .filter((item): item is KeeperConfig['coordination']['active_goals'][number] => item !== null)
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

function normalizeCascadeCatalogSourceKind(
  value: unknown,
): KeeperConfig['sources']['cascade_catalog_source_kind'] {
  const sourceKind = asNullableString(value)
  switch (sourceKind) {
    case 'json':
    case 'toml':
      return sourceKind
    default:
      return null
  }
}

function normalizeRuntimeBlockerClass(value: unknown): KeeperConfig['runtime']['runtime_blocker_class'] {
  const blockerClass = asNullableString(value)
  switch (blockerClass) {
    case 'ambiguous_post_commit_timeout':
    case 'ambiguous_post_commit_failure':
    case 'autonomous_slot_wait_timeout':
    case 'admission_queue_wait_timeout':
    case 'turn_timeout_after_queue_wait':
    case 'oas_timeout_budget':
    case 'turn_timeout':
    case 'completion_contract_violation':
    case 'cascade_exhausted':
    case 'no_tool_capable_provider':
    case 'provider_runtime_error':
    case 'tool_required_unsatisfied':
    case 'fiber_unresolved':
    case 'stale_turn_timeout':
    case 'stale_termination_storm':
    case 'heartbeat_failures':
    case 'turn_failures':
    case 'exception':
    case 'stale_fleet_batch':
    case 'awaiting_operator':
    case 'awaiting_sandbox_egress':
    case 'supervisor_paused':
    case 'synthetic_stall':
    case 'self_imposed_idle':
      return blockerClass
    default:
      return null
  }
}

function normalizeKeeperSandboxEnvironment(
  raw: unknown,
): KeeperConfig['sandbox_environment'] {
  if (!isRecord(raw)) return undefined
  return {
    base_path: asNullableString(raw.base_path),
    project_root: asNullableString(raw.project_root),
    docker_playground_enabled: asLooseBoolean(raw.docker_playground_enabled),
    docker_container_name: asNullableString(raw.docker_container_name),
    container_playground_root: asNullableString(raw.container_playground_root),
    docker_image: asNullableString(raw.docker_image),
    pids_limit: asInt(raw.pids_limit),
    memory: asNullableString(raw.memory),
    tmpfs_size: asNullableString(raw.tmpfs_size),
    seccomp_profile: asNullableString(raw.seccomp_profile),
    require_rootless: asLooseBoolean(raw.require_rootless),
    require_userns: asLooseBoolean(raw.require_userns),
  }
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
  const coordination = isRecord(data.coordination) ? data.coordination : {}
  const tools = isRecord(data.tools) ? data.tools : {}
  const sources = isRecord(data.sources) ? data.sources : {}
  const metrics = isRecord(data.metrics) ? data.metrics : {}
  const sandboxEnvironment = normalizeKeeperSandboxEnvironment(data.sandbox_environment)
  const perProviderTimeoutSec = asLooseNullableNumber(execution.per_provider_timeout_sec)
  const lastLatencyMs = asInt(metrics.last_latency_ms)

  return {
    name: asNullableString(data.name) ?? requestedName,
    active_goal_ids: normalizeStringList(data.active_goal_ids),
    sandbox_profile: asNullableString(data.sandbox_profile) ?? 'local',
    network_mode: asNullableString(data.network_mode) ?? 'inherit',
    sandbox_last_error: asNullableString(data.sandbox_last_error),
    effective_sandbox_image: asNullableString(data.effective_sandbox_image),
    private_workspace_root: asNullableString(data.private_workspace_root),
    sandbox_environment: sandboxEnvironment,
    allowed_paths: normalizeStringList(data.allowed_paths),
    effective_allowed_paths: normalizeStringList(data.effective_allowed_paths),
    prompt: {
      goal: asNullableString(prompt.goal) ?? '',
      short_goal: asNullableString(prompt.short_goal) ?? '',
      mid_goal: asNullableString(prompt.mid_goal) ?? '',
      long_goal: asNullableString(prompt.long_goal) ?? '',
      will: asNullableString(prompt.will) ?? '',
      needs: asNullableString(prompt.needs) ?? '',
      desires: asNullableString(prompt.desires) ?? '',
      instructions: asNullableString(prompt.instructions) ?? '',
      system_prompt_blocks: {
        constitution: normalizePromptBlock(promptBlocks.constitution, 'keeper.constitution'),
        world: normalizePromptBlock(promptBlocks.world, 'keeper.world'),
        capabilities: normalizePromptBlock(promptBlocks.capabilities, 'keeper.capabilities'),
      },
      effective_system_prompt: asNullableString(prompt.effective_system_prompt) ?? '',
    },
    execution: {
      models: normalizeStringList(execution.models),
      active_model: asNullableString(execution.active_model) ?? '',
      active_model_label: asNullableString(execution.active_model_label),
      last_model_used_label: asNullableString(execution.last_model_used_label),
      per_provider_timeout_sec: perProviderTimeoutSec,
      per_provider_timeout_mode:
        asNullableString(execution.per_provider_timeout_mode)
        ?? (perProviderTimeoutSec != null
            ? 'override'
            : 'turn_budget_heuristic'),
      verify: asLooseBoolean(execution.verify),
      selected_cascade_name: asNullableString(execution.selected_cascade_name) ?? '',
      selected_cascade_canonical:
        asNullableString(execution.selected_cascade_canonical)
        ?? asNullableString(execution.selected_cascade_name)
        ?? '',
    },
    compaction: {
      profile: asNullableString(compaction.profile) ?? 'balanced',
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
      enabled:
        typeof drift.enabled === 'boolean'
          ? drift.enabled
          : (typeof drift.enabled === 'string'
              ? asLooseBoolean(drift.enabled)
              : null),
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
          deny_list_count: asInt(hooks.deny_list_count) ?? 0,
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
      presence_keepalive: asLooseBoolean(runtime.presence_keepalive),
      presence_keepalive_sec: asInt(runtime.presence_keepalive_sec) ?? 0,
      runtime_blocker_class: normalizeRuntimeBlockerClass(runtime.runtime_blocker_class),
      active_model_label: asNullableString(runtime.active_model_label),
      last_model_used_label: asNullableString(runtime.last_model_used_label),
      runtime_blocker_summary: asNullableString(runtime.runtime_blocker_summary),
      runtime_blocker_continue_gate:
        typeof runtime.runtime_blocker_continue_gate === 'boolean'
          ? runtime.runtime_blocker_continue_gate
          : (typeof runtime.runtime_blocker_continue_gate === 'string'
              ? asLooseBoolean(runtime.runtime_blocker_continue_gate)
              : null),
    },
    runtime_trust: runtimeTrust,
    coordination: {
      mention_targets: normalizeStringList(coordination.mention_targets),
      joined_room_ids: normalizeStringList(coordination.joined_room_ids),
      active_goal_ids: normalizeStringList(coordination.active_goal_ids),
      active_goals: normalizeKeeperConfigActiveGoals(coordination.active_goals),
      active_goal_count: asInt(coordination.active_goal_count) ?? 0,
      missing_active_goal_ids: normalizeStringList(coordination.missing_active_goal_ids),
    },
    tools: {
      tool_access: tools.tool_access ?? {},
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
      cascade_catalog_source_kind:
        normalizeCascadeCatalogSourceKind(sources.cascade_catalog_source_kind),
      cascade_catalog_source_path:
        asNullableString(sources.cascade_catalog_source_path),
      cascade_runtime_json_path:
        asNullableString(sources.cascade_runtime_json_path),
      cascade_runtime_json_editable:
        typeof sources.cascade_runtime_json_editable === 'boolean'
          ? sources.cascade_runtime_json_editable
          : asLooseBoolean(sources.cascade_runtime_json_editable),
    },
    metrics: {
      generation: asInt(metrics.generation) ?? 0,
      total_turns: asInt(metrics.total_turns) ?? 0,
      total_input_tokens: asInt(metrics.total_input_tokens) ?? 0,
      total_output_tokens: asInt(metrics.total_output_tokens) ?? 0,
      total_tokens: asInt(metrics.total_tokens) ?? 0,
      total_cost_usd: asLooseNumber(metrics.total_cost_usd) ?? 0,
      last_model_used: asNullableString(metrics.last_model_used) ?? '',
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
export type SharedMemoryScope = 'disabled' | 'room'

export type KeeperConfigUpdatePayload = {
  active_goal_ids?: string[]
  allowed_paths?: string[]
  // Sandbox
  sandbox_profile?: SandboxProfile
  network_mode?: SandboxNetworkMode
  // Prompt fields
  goal?: string
  short_goal?: string
  mid_goal?: string
  long_goal?: string
  will?: string
  needs?: string
  desires?: string
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

export function patchKeeperConfig(
  name: string,
  payload: KeeperConfigUpdatePayload,
): Promise<KeeperConfig> {
  return patch<unknown>(
    `/api/v1/keepers/${encodeURIComponent(name)}/config`,
    payload,
  ).then(raw => normalizeKeeperConfig(raw, name))
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
  // Backend caps at 10000 for results, 50000 for thinking content.
  if (fullOutput) {
    params.set('result_max_len', '10000')
    params.set('content_max_len', '50000')
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
  freshness_slo_s?: number | null
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
  health?: string
  stale_reason?: string | null
  entry_count?: number
  exists?: boolean
}

function decodeTelemetryFreshnessMetadata(raw: Record<string, unknown>): TelemetryFreshnessMetadata {
  return {
    source: asString(raw.source),
    producer: asString(raw.producer),
    durable_store: asString(raw.durable_store),
    dashboard_surface: asString(raw.dashboard_surface),
    freshness_slo_s: asNumber(raw.freshness_slo_s),
    latest_ts_unix: asNumber(raw.latest_ts_unix),
    latest_ts_iso: asNullableString(raw.latest_ts_iso),
    latest_age_s: asNumber(raw.latest_age_s),
    health: asString(raw.health),
    stale_reason: asNullableString(raw.stale_reason),
    entry_count: asNumber(raw.entry_count),
    exists: asBoolean(raw.exists),
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
  duration_ms: number
  model?: string
  trace_id?: string
  session_id?: string
  turn?: number
  keeper_turn_id?: number
  task_id?: string
  lane?: string
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
    duration_ms: asNumber(raw.duration_ms, 0),
    model: asString(raw.model),
    trace_id: asString(raw.trace_id),
    session_id: asString(raw.session_id),
    turn: asNumber(raw.turn),
    keeper_turn_id: asNumber(raw.keeper_turn_id),
    task_id: asString(raw.task_id),
    lane: asString(raw.lane),
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
  count: number
  total_matching_entries?: number
  truncated?: boolean
  entries: TelemetryEntry[]
}

export type TelemetrySourceSummary = {
  source: string
  path?: string
  exists?: boolean
  entry_count: number
  keepers?: Array<{ name: string; path: string }>
  keeper_count?: number
  freshness_slo_s?: number | null
  producer?: string
  durable_store?: string
  dashboard_surface?: string
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
  health?: string
  stale_reason?: string | null
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
    count: asNumber(raw.count, 0),
    total_matching_entries: asNumber(raw.total_matching_entries, asNumber(raw.count, 0)),
    truncated: asBoolean(raw.truncated, false),
    entries: asRecordArray(raw.entries)
      .map(decodeTelemetryEntry)
      .filter((entry): entry is TelemetryEntry => entry !== null),
  }
}

function decodeTelemetrySourceSummary(raw: unknown): TelemetrySourceSummary | null {
  if (!isRecord(raw)) return null
  const source = asString(raw.source)
  if (!source) return null
  return {
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
    freshness_slo_s: asNumber(raw.freshness_slo_s),
    producer: asString(raw.producer),
    durable_store: asString(raw.durable_store),
    dashboard_surface: asString(raw.dashboard_surface),
    latest_ts_unix: asNumber(raw.latest_ts_unix),
    latest_ts_iso: asString(raw.latest_ts_iso),
    latest_age_s: asNumber(raw.latest_age_s),
    health: asString(raw.health),
    stale_reason: asNullableString(raw.stale_reason),
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
  const providers = asStringArray(raw.providers)
  const models = asStringArray(raw.models)
  const grid = Array.isArray(raw.grid)
    ? (raw.grid as unknown[]).map(row =>
        Array.isArray(row)
          ? (row as unknown[]).map(v => asNumber(v) ?? 0)
          : []
      )
    : []
  return { providers, models, grid }
}

function decodeCostLatencyResponse(raw: unknown): CostLatencyResponse | null {
  if (!isRecord(raw)) return null
  const matrix = decodeCostMatrix(raw.matrix)
  if (!matrix) return null
  return {
    perAgent: asRecordArray(raw.perAgent)
      .map(decodeCostPerAgentRow)
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
    window_minutes: asNumber(raw.window_minutes) ?? 1440,
    generated_at: asNumber(raw.generated_at) ?? 0,
  }
}

export async function fetchCostLatency(
  windowMinutes = 1440,
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
