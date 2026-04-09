// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import { get, post, patch, NAMESPACE_TRUTH_GET_TIMEOUT_MS } from './core'
import type {
  KeeperConfig,
  DashboardExecutionResponse,
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
  return get<KeeperConfig>(`/api/v1/keepers/${encodeURIComponent(name)}/config`)
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
  return patch<KeeperConfig>(
    `/api/v1/keepers/${encodeURIComponent(name)}/config`,
    payload,
  )
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
