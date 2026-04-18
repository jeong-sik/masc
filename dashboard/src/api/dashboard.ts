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
import { get, post, patch, withRetries, NAMESPACE_TRUTH_GET_TIMEOUT_MS } from './core'
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
  DashboardNamespaceTruthResponse,
  DashboardShellResponse,
  DashboardConfigResolution,
  DashboardConfigResolutionItem,
  DashboardRuntimeDiagnostic,
  DashboardRuntimeResolution,
  ServerBuildIdentity,
  BoardSortMode,
  GovernanceCaseBundle,
  GovernanceDecisionItem,
  GovernanceJudgment,
  KeeperApprovalQueueItem,
  GovernanceTimelineEvent,
  PendingConfirmation,
} from '../types'

// --- Dashboard projections ---

type AbortableRequestOptions = {
  signal?: AbortSignal
}

export function fetchDashboardShell(opts?: AbortableRequestOptions): Promise<DashboardShellResponse> {
  return get('/api/v1/dashboard/shell', { signal: opts?.signal })
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

interface ToolHostFailureReport {
  agent_name?: string
  client_name?: string
  tool_name: string
  transport?: string
  phase?: string
  message: string
  request_id?: string
  session_id?: string
  trace_id?: string
  timeout_ms?: number
}

export function reportToolHostFailure(
  report: ToolHostFailureReport,
): Promise<{ ok: boolean }> {
  return post('/api/v1/dashboard/logs/tool-host-failures', report, undefined, 3000)
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
  AgentCollaborator,
  AgentRelation,
  AgentRelationsResponse,
} from './schemas/agent-relations'
export { AgentRelationsSchemaDriftError } from './schemas/agent-relations'

export async function fetchAgentRelations(agentName: string): Promise<AgentRelationsResponse> {
  const raw = await get<unknown>(`/api/v1/agent-relations?agent_name=${encodeURIComponent(agentName)}`)
  return parseAgentRelationsResponse(raw)
}

export interface ConfigEntry {
  env: string
  description: string
  value: string | null
  default: string
  source: 'env' | 'default'
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

export function fetchDashboardNamespaceTruth(opts?: AbortableRequestOptions): Promise<DashboardNamespaceTruthResponse> {
  return get('/api/v1/dashboard/namespace-truth', {
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
  const hasFilter = opts?.excludeSystem || opts?.excludeAutomation || opts?.author
  const defaultLimit = hasFilter ? 200 : 100
  const limit = Math.max(1, Math.min(500, opts?.limit ?? defaultLimit))
  const offset = Math.max(0, Math.min(5000, opts?.offset ?? 0))
  params.set('limit', String(limit))
  if (offset > 0) params.set('offset', String(offset))
  if (opts?.excludeSystem) params.set('exclude_system', 'true')
  if (opts?.excludeAutomation) params.set('exclude_automation', 'true')
  if (opts?.author) params.set('author', opts.author)
  return get(`/api/v1/dashboard/board${params.toString() ? `?${params}` : ''}`)
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
    }
  })
}

export function resolveGovernanceApproval(
  id: string,
  decision: 'approve' | 'reject',
  reason?: string,
): Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject' }> {
  return post('/api/v1/dashboard/governance/approvals/resolve', {
    id,
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
  p50_latency_ms: number
  p95_latency_ms: number
  error_rate: number
  total_cost_usd: number
  cache_hit_ratio: number
}

export interface DashboardRuntimeModelMetric {
  model_id: string
  entry_count?: number | null
  avg_tok_per_sec?: number | null
  p50_tok_per_sec?: number | null
  p95_tok_per_sec?: number | null
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
  fallback_count?: number | null
  success_count?: number | null
  error_count?: number | null
  total_cost_usd?: number | null
  avg_tool_calls_per_turn?: number | null
  total_tool_calls?: number | null
  top_tools?: Array<{ tool: string; count: number }> | null
  recent_entries?: Array<{
    ts_unix: number
    input_tokens: number
    output_tokens: number
    latency_ms: number
    cost_usd: number
    tools_count: number
  }> | null
  buckets?: BucketMetric[] | null
}

export interface DashboardRuntimeModelMetricsResponse {
  window_minutes?: number
  bucket_minutes?: number
  total_entries?: number
  total_error_entries?: number
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
    entry_count: asNumber(raw.entry_count) ?? null,
    avg_tok_per_sec: asNumber(raw.avg_tok_per_sec) ?? null,
    p50_tok_per_sec: asNumber(raw.p50_tok_per_sec) ?? null,
    p95_tok_per_sec: asNumber(raw.p95_tok_per_sec) ?? null,
    hw_decode_avg_tok_per_sec: asNumber(raw.hw_decode_avg_tok_per_sec) ?? null,
    hw_decode_p50_tok_per_sec: asNumber(raw.hw_decode_p50_tok_per_sec) ?? null,
    hw_decode_p95_tok_per_sec: asNumber(raw.hw_decode_p95_tok_per_sec) ?? null,
    thinking_fraction: asNumber(raw.thinking_fraction) ?? null,
    avg_latency_ms: asNumber(raw.avg_latency_ms) ?? null,
    p50_latency_ms: asNumber(raw.p50_latency_ms) ?? null,
    p95_latency_ms: asNumber(raw.p95_latency_ms) ?? null,
    total_input_tokens: asNumber(raw.total_input_tokens) ?? null,
    total_output_tokens: asNumber(raw.total_output_tokens) ?? null,
    total_cache_read_tokens: asNumber(raw.total_cache_read_tokens) ?? null,
    total_reasoning_tokens: asNumber(raw.total_reasoning_tokens) ?? null,
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
            input_tokens: asNumber(r.input_tokens) ?? 0,
            output_tokens: asNumber(r.output_tokens) ?? 0,
            latency_ms: asNumber(r.latency_ms) ?? 0,
            cost_usd: asNumber(r.cost_usd) ?? 0,
            tools_count: asNumber(r.tools_count) ?? 0,
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
            p50_latency_ms: asNumber(b.p50_latency_ms) ?? 0,
            p95_latency_ms: asNumber(b.p95_latency_ms) ?? 0,
            error_rate: asNumber(b.error_rate) ?? 0,
            total_cost_usd: asNumber(b.total_cost_usd) ?? 0,
            cache_hit_ratio: asNumber(b.cache_hit_ratio) ?? 0,
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
    models: asRecordArray(raw.models)
      .map(decodeRuntimeModelMetric)
      .filter((metric): metric is DashboardRuntimeModelMetric => metric !== null),
  }
}

export async function fetchRuntimeProviders(opts?: AbortableRequestOptions): Promise<DashboardRuntimeProvidersResponse> {
  const raw = await get<Record<string, unknown>>('/api/v1/providers', { signal: opts?.signal })
  const decoded = decodeRuntimeProvidersResponse(raw)
  if (!decoded) throw new Error('invalid runtime providers payload')
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
  if (!decoded) throw new Error('invalid runtime model metrics payload')
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

export function fetchDashboardGoalsTree(): Promise<DashboardGoalsTreeResponse> {
  return get('/api/v1/dashboard/goals')
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
}

export interface DashboardRuntimeProbeLoadedModel {
  name?: string | null
  model?: string | null
  size_vram_bytes?: number | null
  context_length?: number | null
  expires_at?: string | null
}

export interface DashboardRuntimeProbeRun {
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

export interface DashboardRuntimeProbeAssessment {
  signal?: string | null
  baseline_run_index?: number | null
  best_repeat_run_index?: number | null
  baseline_prompt_eval_duration_ms?: number | null
  best_repeat_prompt_eval_duration_ms?: number | null
  prompt_eval_duration_reduction_ratio?: number | null
  note?: string | null
  limitation?: string | null
}

export interface DashboardRuntimeProbePayload {
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

export interface DashboardPromptsResponse {
  prompts: DashboardPromptItem[]
}

export interface PromptMutationResponse {
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

function normalizeToolPreset(value: unknown): KeeperConfig['tools']['tool_preset'] {
  const preset = asNullableString(value)
  switch (preset) {
    case 'minimal':
    case 'messaging':
    case 'coding':
    case 'research':
    case 'full':
      return preset
    default:
      return null
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

function normalizeRuntimeBlockerClass(value: unknown): KeeperConfig['runtime']['runtime_blocker_class'] {
  const blockerClass = asNullableString(value)
  switch (blockerClass) {
    case 'ambiguous_post_commit_timeout':
    case 'ambiguous_post_commit_failure':
    case 'autonomous_slot_wait_timeout':
    case 'admission_queue_wait_timeout':
    case 'turn_timeout_after_queue_wait':
    case 'turn_timeout':
    case 'completion_contract_violation':
      return blockerClass
    default:
      return null
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
  const autoTeamSession = isRecord(data.auto_team_session) ? data.auto_team_session : {}
  const handoff = isRecord(data.handoff) ? data.handoff : {}
  const hooks = isRecord(data.hooks) ? data.hooks : null
  const runtime = isRecord(data.runtime) ? data.runtime : {}
  const coordination = isRecord(data.coordination) ? data.coordination : {}
  const tools = isRecord(data.tools) ? data.tools : {}
  const sources = isRecord(data.sources) ? data.sources : {}
  const metrics = isRecord(data.metrics) ? data.metrics : {}

  return {
    name: asNullableString(data.name) ?? requestedName,
    execution_scope: asNullableString(data.execution_scope) ?? 'workspace',
    sandbox_profile: asNullableString(data.sandbox_profile) ?? 'legacy_local',
    network_mode: asNullableString(data.network_mode) ?? 'inherit',
    shared_memory_scope: asNullableString(data.shared_memory_scope) ?? 'disabled',
    sandbox_last_error: asNullableString(data.sandbox_last_error),
    effective_sandbox_image: asNullableString(data.effective_sandbox_image),
    private_workspace_root: asNullableString(data.private_workspace_root),
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
      verify: asLooseBoolean(execution.verify),
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
    auto_team_session: {
      status: normalizeKeeperFeatureStatus(autoTeamSession.status),
      enabled:
        typeof autoTeamSession.enabled === 'boolean'
          ? autoTeamSession.enabled
          : (typeof autoTeamSession.enabled === 'string'
              ? asLooseBoolean(autoTeamSession.enabled)
              : null),
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
      runtime_blocker_summary: asNullableString(runtime.runtime_blocker_summary),
      runtime_blocker_continue_gate:
        typeof runtime.runtime_blocker_continue_gate === 'boolean'
          ? runtime.runtime_blocker_continue_gate
          : (typeof runtime.runtime_blocker_continue_gate === 'string'
              ? asLooseBoolean(runtime.runtime_blocker_continue_gate)
              : null),
    },
    coordination: {
      room_scope: asNullableString(coordination.room_scope) ?? 'current',
      mention_targets: normalizeStringList(coordination.mention_targets),
      joined_room_ids: normalizeStringList(coordination.joined_room_ids),
    },
    tools: {
      tool_access: tools.tool_access ?? {},
      tool_policy_mode: asNullableString(tools.tool_policy_mode) ?? 'preset',
      tool_preset: normalizeToolPreset(tools.tool_preset),
      tool_also_allow: normalizeStringList(tools.tool_also_allow),
      tool_custom_allowlist: normalizeStringList(tools.tool_custom_allowlist),
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
      last_model_used: asNullableString(metrics.last_model_used) ?? '',
      last_input_tokens: asInt(metrics.last_input_tokens) ?? 0,
      last_output_tokens: asInt(metrics.last_output_tokens) ?? 0,
      last_total_tokens: asInt(metrics.last_total_tokens) ?? 0,
      last_latency_ms: asInt(metrics.last_latency_ms) ?? 0,
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

export type KeeperConfigUpdatePayload = {
  // Scope
  execution_scope?: 'observe_only' | 'workspace' | 'local'
  allowed_paths?: string[]
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

export type TrajectoryGate = {
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

export type ToolStatsResponse = {
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
    if (!decoded) throw new Error('invalid keeper tool stats payload')
    return decoded
  })
}

// ── Keeper tool call log (full I/O) ──────────────────────

export type ToolCallEntry = {
  ts: number
  keeper: string
  tool: string
  input: unknown
  output: string
  success: boolean
  duration_ms: number
  model?: string
}

export type ToolCallsResponse = {
  keeper: string
  count: number
  entries: ToolCallEntry[]
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
    output: asString(raw.output, ''),
    success: asBoolean(raw.success, false),
    duration_ms: asNumber(raw.duration_ms, 0),
    model: asString(raw.model),
  }
}

function decodeToolCallsResponse(raw: unknown): ToolCallsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
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
    if (!decoded) throw new Error('invalid keeper tool call payload')
    return decoded
  })
}

// ── Unified telemetry ──────────────────────────────────

export type TelemetrySource =
  | 'keeper_metric'
  | 'agent_event'
  | 'tool_call_io'
  | 'tool_usage'
  | 'oas_event'
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
  latest_ts_unix?: number | null
  latest_ts_iso?: string | null
  latest_age_s?: number | null
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
    case 'tool_usage':
    case 'oas_event':
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
    latest_ts_unix: asNumber(raw.latest_ts_unix),
    latest_ts_iso: asString(raw.latest_ts_iso),
    latest_age_s: asNumber(raw.latest_age_s),
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
      if (!decoded) throw new Error('invalid telemetry payload')
      return decoded
    })
}

export function fetchTelemetrySummary(opts?: AbortableRequestOptions): Promise<TelemetrySummaryResponse> {
  return get<Record<string, unknown>>('/api/v1/dashboard/telemetry/summary', { signal: opts?.signal })
    .then((raw) => {
      const decoded = decodeTelemetrySummaryResponse(raw)
      if (!decoded) throw new Error('invalid telemetry summary payload')
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
  filters: {
    keepers: string[]
    outcomes: string[]
  }
}

export interface MemorySubsystemsQuery {
  limit?: number
  keeper?: string
  outcome?: string
  q?: string
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
  const qs = params.toString()
  return get<MemorySubsystemsResponse>(
    `/api/v1/dashboard/memory-subsystems${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

// --- Keeper Cascade Config ---

export function fetchCascadeProfiles(): Promise<{ profiles: string[] }> {
  return get<{ profiles: string[] }>('/api/v1/keeper/cascades')
}

export function updateKeeperCascade(keeper: string, cascade_name: string): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/keeper/cascade', { keeper, cascade_name })
}

// ── Cascade config + health (observability) ─────────────

export interface CascadeCandidate {
  model: string
  config_weight: number
  effective_weight: number
  success_rate: number
  in_cooldown: boolean
}

export interface CascadeProfile {
  name: string
  source: 'named' | 'default_fallback' | 'hardcoded_defaults'
  candidates: CascadeCandidate[]
}

export interface CascadeKeeperProfile {
  keeper: string
  cascade_name: string
  canonical: string
}

export interface CascadeConfigResponse {
  updated_at: string
  config_path: string | null
  profiles: CascadeProfile[]
  keeper_profiles: CascadeKeeperProfile[]
}

export interface CascadeHealthProvider {
  provider_key: string
  success_rate: number
  consecutive_failures: number
  in_cooldown: boolean
  cooldown_expires_at: number | null
  events_in_window: number
  /** Subset of [events_in_window] with outcome "rejected" — response
   *  arrived but was rejected by the cascade's accept predicate. Split
   *  so the dashboard can tell "provider down" from "provider returns
   *  unusable output".
   *  @since 0.160.0 — optional for backward compat with older servers. */
  rejected_in_window?: number
}

export interface CascadeHealthResponse {
  updated_at: string
  window_sec: number
  cooldown_threshold: number
  cooldown_sec: number
  providers: CascadeHealthProvider[]
}

export function fetchCascadeConfig(opts?: AbortableRequestOptions): Promise<CascadeConfigResponse> {
  return get<CascadeConfigResponse>('/api/v1/cascade/config', { signal: opts?.signal })
}

export function fetchCascadeHealth(opts?: AbortableRequestOptions): Promise<CascadeHealthResponse> {
  return get<CascadeHealthResponse>('/api/v1/cascade/health', { signal: opts?.signal })
}

export type CascadeCapacityKind = 'cli' | 'ollama' | 'other'

export interface CascadeClientCapacityEntry {
  key: string
  kind: CascadeCapacityKind
  total: number
  active: number
  available: number
}

export interface CascadeClientCapacityResponse {
  updated_at: string
  entries: CascadeClientCapacityEntry[]
}

export function fetchCascadeClientCapacity(
  opts?: AbortableRequestOptions,
): Promise<CascadeClientCapacityResponse> {
  return get<CascadeClientCapacityResponse>('/api/v1/cascade/client_capacity', {
    signal: opts?.signal,
  })
}

export type CascadeCapacityEventKind = 'acquired' | 'released' | 'rejected_full'

export interface CascadeClientCapacityHistoryEvent {
  ts: number
  key: string
  kind: CascadeCapacityEventKind
  active_after: number
}

export interface CascadeClientCapacityHistoryResponse {
  updated_at: string
  total_events: number
  events: CascadeClientCapacityHistoryEvent[]
}

export function fetchCascadeClientCapacityHistory(opts?: {
  limit?: number
  kind?: CascadeCapacityKind
  signal?: AbortSignal
}): Promise<CascadeClientCapacityHistoryResponse> {
  const params = new URLSearchParams()
  if (typeof opts?.limit === 'number' && opts.limit > 0) {
    params.set('limit', String(opts.limit))
  }
  if (opts?.kind) params.set('kind', opts.kind)
  const qs = params.toString()
  return get<CascadeClientCapacityHistoryResponse>(
    `/api/v1/cascade/client_capacity/history${qs ? `?${qs}` : ''}`,
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

export interface FetchVerificationRequestsOptions {
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

export interface ResolveVerificationRequestOptions {
  task_id: string
  verification_id: string
  decision: 'approve' | 'reject'
  reason?: string
}

export interface ResolveVerificationResponse {
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

export type CascadeStrategyTraceKind = 'ordered' | 'filtered_empty' | 'exhausted'

export interface CascadeStrategyTraceEvent {
  ts: number
  cascade_name: string
  strategy: string
  cycle: number
  candidates_in: number
  candidates_out: number
  backoff_ms: number
  kind: CascadeStrategyTraceKind
}

export interface CascadeStrategyTraceResponse {
  updated_at: string
  total_events: number
  events: CascadeStrategyTraceEvent[]
}

export function fetchCascadeStrategyTrace(opts?: {
  limit?: number
  cascade?: string
  signal?: AbortSignal
}): Promise<CascadeStrategyTraceResponse> {
  const params = new URLSearchParams()
  if (typeof opts?.limit === 'number' && opts.limit > 0) {
    params.set('limit', String(opts.limit))
  }
  if (opts?.cascade) params.set('cascade', opts.cascade)
  const qs = params.toString()
  return get<CascadeStrategyTraceResponse>(
    `/api/v1/cascade/strategy_trace${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

export type CascadeSloStatus = 'ok' | 'warn' | 'violated'

export interface CascadeSloTargets {
  ordered_ratio_min: number
  exhaustion_count_max: number
  burn_rate_max: number
}

export interface CascadeSloCurrent {
  ordered_ratio: number
  exhaustion_count: number
  burn_rate: number
  total_events: number
}

export interface CascadeSloResponse {
  updated_at: string
  window_sample_size: number
  targets: CascadeSloTargets
  current: CascadeSloCurrent
  status: CascadeSloStatus
  violations: string[]
}

export function fetchCascadeSlo(
  opts?: AbortableRequestOptions,
): Promise<CascadeSloResponse> {
  return get<CascadeSloResponse>('/api/v1/cascade/slo', {
    signal: opts?.signal,
  })
}
