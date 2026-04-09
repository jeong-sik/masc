// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import { isRecord, asBoolean, asInt, asNumber, asStringArray } from '../components/common/normalize'
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
  DashboardProofResponse,
  DashboardPlanningResponse,
  DashboardGoalsTreeResponse,
  DashboardNamespaceTruthResponse,
  DashboardShellResponse,
  BoardSortMode,
  GovernanceCaseBundle,
  GovernanceDecisionItem,
  GovernanceJudgment,
  KeeperApprovalQueueItem,
  GovernanceTimelineEvent,
  PendingConfirmation,
  CommandPlaneHelpResponse,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneSnapshot,
  CommandPlaneSummarySnapshot,
} from '../types'

// --- Dashboard projections ---

export function fetchDashboardShell(): Promise<DashboardShellResponse> {
  return get('/api/v1/dashboard/shell')
}

// --- System logs ---

export interface LogEntry {
  seq: number
  ts: string
  level: string
  raw_level: string
  normalized_level: string
  source: string
  legacy_classified: boolean
  module: string
  message: string
  details?: Record<string, unknown> | null
}

export interface LogsResponse {
  total: number
  entries: LogEntry[]
}

export function fetchLogs(opts?: {
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
  return get(`/api/v1/dashboard/logs${qs ? `?${qs}` : ''}`)
}

export interface ToolHostFailureReport {
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

export interface AgentTimelineEvent {
  ts: string
  type: string
  detail: Record<string, unknown>
}

export interface AgentTimelineResponse {
  agent: string
  period: { from: string; to: string }
  events: AgentTimelineEvent[]
  summary: {
    tasks_completed: number
    tasks_claimed: number
    messages_sent: number
    tool_calls?: number
    active_duration_minutes: number
    total_events: number
  }
}

export function fetchAgentTimeline(
  agentName: string,
  sinceHours = 4,
  limit = 20,
): Promise<AgentTimelineResponse> {
  return get(`/api/v1/agent-timeline?agent_name=${encodeURIComponent(agentName)}&since_hours=${sinceHours}&limit=${limit}`)
}

export type AgentCollaborator = {
  name: string
  collaborations: number
  last_collab: string | null
}

export type AgentRelation = {
  type: string
  category: string | null
  confidence: number | null
  note: string | null
  participants: { kind: string; display_name: string | null; role: string | null }[]
}

export type AgentRelationsResponse = {
  agent_name: string
  collaborators: AgentCollaborator[]
  interests: string[]
  relations: AgentRelation[]
}

export function fetchAgentRelations(agentName: string): Promise<AgentRelationsResponse> {
  return get(`/api/v1/agent-relations?agent_name=${encodeURIComponent(agentName)}`)
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

export function fetchDashboardNamespaceTruth(): Promise<DashboardNamespaceTruthResponse> {
  return get('/api/v1/dashboard/namespace-truth', { timeoutMs: NAMESPACE_TRUTH_GET_TIMEOUT_MS })
}

export function fetchDashboardExecution(): Promise<DashboardExecutionResponse> {
  return get('/api/v1/dashboard/execution')
}

export type ToolQualityToolStat = {
  name: string
  calls: number
  success_pct: number
  avg_ms: number
  output_truncated_count?: number
  avg_output_chars?: number
}

export type ToolQualityKeeperStat = {
  name: string
  calls: number
  success_pct: number
}

export type ToolQualityFailureCategory = {
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
  total: number
  success: number
  failure: number
  success_rate: number
  by_tool: ToolQualityToolStat[]
  by_keeper: ToolQualityKeeperStat[]
  failure_categories: ToolQualityFailureCategory[]
  hourly_trend?: ToolQualityHourlyPoint[]
}

export function fetchToolQuality(opts?: { n?: number }): Promise<ToolQualityResponse> {
  const params = new URLSearchParams()
  if (opts?.n != null) params.set('n', String(opts.n))
  const qs = params.toString()
  return get<ToolQualityResponse>(`/api/v1/dashboard/tool-quality${qs ? `?${qs}` : ''}`)
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

export function fetchDashboardMemory(
  sortMode: BoardSortMode,
  opts?: { excludeSystem?: boolean; excludeAutomation?: boolean; author?: string },
): Promise<DashboardMemoryResponse> {
  const params = new URLSearchParams()
  params.set('sort_by', sortMode)
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
      case_tracking_available:
        typeof raw.case_tracking_available === 'boolean' ? raw.case_tracking_available : undefined,
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

export interface RuntimeParamMeta {
  description: string
  value_type: string
  min_value?: number
  max_value?: number
}

export interface RuntimeParam {
  key: string
  current: unknown
  default: unknown
  has_override: boolean
  meta?: RuntimeParamMeta | null
}

export interface RuntimeParamsSurface {
  id: string
  description: string
  risk: string
  param_keys: string[]
}

export interface RuntimeParamsResponse {
  parameters: RuntimeParam[]
  surfaces: RuntimeParamsSurface[]
}

export function fetchRuntimeParams(): Promise<RuntimeParamsResponse> {
  return get('/api/v1/governance/params')
}

export function setRuntimeParam(paramKey: string, value: unknown, reason = ''): Promise<{ ok: boolean; message: string }> {
  return post('/api/v1/governance/params/set', { param_key: paramKey, value, reason })
}

export function clearRuntimeParam(paramKey: string): Promise<{ ok: boolean; message: string }> {
  return post('/api/v1/governance/params/clear', { param_key: paramKey })
}

export interface ParamAuditEntry {
  timestamp: number
  key: string
  old_value: unknown
  new_value: unknown
  actor: string
  case_id?: string
}

export interface ParamAuditResponse {
  entries: ParamAuditEntry[]
  count: number
}

export function fetchParamAudit(limit = 50): Promise<ParamAuditResponse> {
  return get(`/api/v1/governance/params/audit?limit=${limit}`)
}

export function fetchDashboardMission(): Promise<DashboardMissionResponse> {
  return get('/api/v1/dashboard/mission')
}

export function fetchDashboardMissionSession(sessionId: string): Promise<DashboardMissionSessionDetailResponse> {
  const query = `?session_id=${encodeURIComponent(sessionId)}`
  return get(`/api/v1/dashboard/session${query}`)
}

export interface DashboardRuntimeProviderDiscovery {
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
  } | null
  providers: DashboardRuntimeProviderSnapshot[]
}

export interface DashboardRuntimeModelMetric {
  model_id: string
  entry_count?: number | null
  avg_tok_per_sec?: number | null
  p50_tok_per_sec?: number | null
  p95_tok_per_sec?: number | null
  avg_latency_ms?: number | null
  p50_latency_ms?: number | null
  p95_latency_ms?: number | null
  total_input_tokens?: number | null
  total_output_tokens?: number | null
  total_cache_read_tokens?: number | null
  total_reasoning_tokens?: number | null
  fallback_count?: number | null
}

export interface DashboardRuntimeModelMetricsResponse {
  window_minutes?: number
  total_entries?: number
  models: DashboardRuntimeModelMetric[]
}

export function fetchRuntimeProviders(): Promise<DashboardRuntimeProvidersResponse> {
  return get('/api/v1/providers')
}

export function fetchRuntimeModelMetrics(windowMinutes = 30): Promise<DashboardRuntimeModelMetricsResponse> {
  return get(`/api/v1/models/metrics?window=${windowMinutes}`)
}

export interface DashboardVerificationRef {
  kind: string
  label: string
  value: string
}

export function fetchDashboardMissionBriefing(force = false): Promise<DashboardMissionBriefingResponse> {
  const query = force ? '?force=1' : ''
  return get(`/api/v1/dashboard/mission/briefing${query}`)
}

export function fetchDashboardProof(
  sessionId?: string | null,
  operationId?: string | null,
): Promise<DashboardProofResponse> {
  const params = new URLSearchParams()
  if (sessionId) params.set('session_id', sessionId)
  if (operationId) params.set('operation_id', operationId)
  const query = params.toString()
  return get(`/api/v1/dashboard/proof${query ? `?${query}` : ''}`)
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

export interface SurfaceSummaryEntry {
  count: number
  tools: string[]
}

export interface DashboardToolInventoryResponse {
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

export interface DashboardConfigResolutionItem {
  path: string
  exists: boolean
  source: string
}

export interface DashboardConfigResolution {
  status: 'ready' | 'warn' | 'invalid_env' | 'missing'
  warnings: string[]
  config_root: DashboardConfigResolutionItem
  cascade: DashboardConfigResolutionItem
  prompts: DashboardConfigResolutionItem
  keepers: DashboardConfigResolutionItem
  personas: DashboardConfigResolutionItem
}

export interface DashboardRuntimeDiagnostic {
  ts: string
  kind: string
  signal?: string
  message: string
}

export interface DashboardBuildIdentity {
  release_version: string
  commit: string | null
  started_at: string
  uptime_seconds: number
}

export interface DashboardRuntimeResolution {
  status: 'ready' | 'warn' | string
  warnings: string[]
  base_path: DashboardConfigResolutionItem
  workspace_path: DashboardConfigResolutionItem
  resolved_base_path: DashboardConfigResolutionItem
  data_root: DashboardConfigResolutionItem
  prompt_markdown_dir: DashboardConfigResolutionItem
  workspace_git_commit: string | null
  resolved_base_git_commit: string | null
  source_mismatch: boolean
  diagnostics: DashboardRuntimeDiagnostic[]
  build: DashboardBuildIdentity
}

export function fetchToolMetrics(): Promise<ToolMetricsResponse> {
  return get('/api/v1/tool-metrics')
}

export async function fetchDashboardTools(): Promise<DashboardToolsResponse> {
  const raw = await get<DashboardToolsResponse>('/api/v1/dashboard/tools')
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

function asNullableString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed !== '' ? trimmed : null
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
      runtime_blocker_manual_reconcile:
        typeof runtime.runtime_blocker_manual_reconcile === 'boolean'
          ? runtime.runtime_blocker_manual_reconcile
          : (typeof runtime.runtime_blocker_manual_reconcile === 'string'
              ? asLooseBoolean(runtime.runtime_blocker_manual_reconcile)
              : null),
    },
    coordination: {
      room_scope: asNullableString(coordination.room_scope) ?? 'current',
      scope_kind: asNullableString(coordination.scope_kind) ?? 'current',
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

// --- Command Plane ---

export function fetchCommandPlaneSnapshot(): Promise<CommandPlaneSnapshot> {
  return get('/api/v1/command-plane')
}

export function fetchCommandPlaneSummary(): Promise<CommandPlaneSummarySnapshot> {
  return get('/api/v1/command-plane/summary')
}

export function fetchChainSummary(): Promise<CommandPlaneChainSummary> {
  return get('/api/v1/chains/summary')
}

export function fetchChainRun(runId: string): Promise<CommandPlaneChainRunResponse> {
  return get(`/api/v1/chains/runs/${encodeURIComponent(runId)}`)
}
export function fetchCommandPlaneHelp(): Promise<CommandPlaneHelpResponse> {
  return get('/api/v1/command-plane/help')
}

export function runCommandPlaneAction(
  path: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return post(path, body)
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
): Promise<TrajectoryResponse> {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  // Always send include_thinking explicitly — backend defaults to false,
  // so omitting the param means "don't include".
  params.set('include_thinking', includeThinking ? 'true' : 'false')
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

export function fetchKeeperToolStats(
  name: string,
  windowHours?: number,
): Promise<ToolStatsResponse> {
  const params = windowHours != null ? `?window_hours=${windowHours}` : ''
  return get<ToolStatsResponse>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-stats${params}`,
  )
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

export function fetchKeeperToolCalls(
  name: string,
  limit?: number,
): Promise<ToolCallsResponse> {
  const params = limit != null ? `?limit=${limit}` : ''
  return get<ToolCallsResponse>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-calls${params}`,
  )
}

// ── Unified telemetry ──────────────────────────────────

export type TelemetrySource =
  | 'keeper_metric'
  | 'agent_event'
  | 'tool_call_io'
  | 'tool_usage'
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
  entries: TelemetryEntry[]
}

export type TelemetrySourceSummary = {
  source: string
  path?: string
  exists?: boolean
  entry_count: number
  keepers?: Array<{ name: string; path: string }>
  keeper_count?: number
}

export type TelemetrySummaryResponse = {
  generated_at: string
  sources: TelemetrySourceSummary[]
  total_entries: number
}

export function fetchTelemetry(opts?: {
  source?: TelemetrySource
  keeper?: string
  session_id?: string
  operation_id?: string
  worker_run_id?: string
  n?: number
}): Promise<TelemetryResponse> {
  const params = new URLSearchParams()
  if (opts?.source) params.set('source', opts.source)
  if (opts?.keeper) params.set('keeper', opts.keeper)
  if (opts?.session_id) params.set('session_id', opts.session_id)
  if (opts?.operation_id) params.set('operation_id', opts.operation_id)
  if (opts?.worker_run_id) params.set('worker_run_id', opts.worker_run_id)
  if (opts?.n) params.set('n', String(opts.n))
  const qs = params.toString()
  return get<TelemetryResponse>(`/api/v1/dashboard/telemetry${qs ? '?' + qs : ''}`)
}

export function fetchTelemetrySummary(): Promise<TelemetrySummaryResponse> {
  return get<TelemetrySummaryResponse>('/api/v1/dashboard/telemetry/summary')
}

// --- Excuse Patterns ---

export type ExcusePattern = [string, string]

export function fetchExcusePatterns(): Promise<ExcusePattern[]> {
  return get<ExcusePattern[]>('/api/v1/dashboard/config/excuse-patterns')
}

export function updateExcusePatterns(patterns: ExcusePattern[]): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/dashboard/config/excuse-patterns', patterns)
}

// --- Keeper Cascade Config ---

export function fetchCascadeProfiles(): Promise<{ profiles: string[] }> {
  return get<{ profiles: string[] }>('/api/v1/keeper/cascades')
}

export function updateKeeperCascade(keeper: string, cascade_name: string): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/keeper/cascade', { keeper, cascade_name })
}
