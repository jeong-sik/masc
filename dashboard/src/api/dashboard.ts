// MASC Dashboard — Dashboard projections, resource fetchers, tool metrics

import { get, withRetries, ROOM_TRUTH_GET_TIMEOUT_MS, post } from './core'
import {
  normalizeGovernanceDecisionItem,
  normalizePendingConfirmation,
  asNullableIsoTimestamp,
  normalizeGovernanceTimelineEvent,
  normalizeGovernanceJudgeSummary,
} from './board'
import { asInt } from './trpg'
import { isRecord } from '../components/common/normalize'
import type {
  DashboardExecutionResponse,
  DashboardGovernanceResponse,
  DashboardMemoryResponse,
  DashboardMissionBriefingResponse,
  DashboardMissionResponse,
  DashboardMissionSessionDetailResponse,
  DashboardProofResponse,
  DashboardPlanningResponse,
  DashboardRoomTruthResponse,
  DashboardShellResponse,
  DashboardSemanticsResponse,
  BoardSortMode,
  GovernanceDecisionItem,
  GovernanceTimelineEvent,
  PendingConfirmation,
  OperatorSnapshot,
  OperatorDigest,
  CommandPlaneHelpResponse,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneSnapshot,
  CommandPlaneSwarmResponse,
  CommandPlaneOrchestraResponse,
  CommandPlaneSummarySnapshot,
} from '../types'

// --- Dashboard projections ---

export function fetchDashboardShell(): Promise<DashboardShellResponse> {
  return get('/api/v1/dashboard/shell')
}

export interface AgentActivityEntry {
  agent_id: string
  tool_calls: number
  success_count: number
  failure_count: number
  first_seen: number
  last_seen: number
}

export interface AgentActivityResponse {
  hours: number
  agents: AgentActivityEntry[]
}

export function fetchAgentActivity(hours = 24): Promise<AgentActivityResponse> {
  return get(`/api/v1/agent-activity?hours=${hours}`)
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

export function fetchDashboardRoomTruth(): Promise<DashboardRoomTruthResponse> {
  return get('/api/v1/dashboard/room-truth', { timeoutMs: ROOM_TRUTH_GET_TIMEOUT_MS })
}

export function fetchDashboardExecution(): Promise<DashboardExecutionResponse> {
  return get('/api/v1/dashboard/execution')
}

export function fetchDashboardMemory(
  sortMode: BoardSortMode,
  opts?: { excludeSystem?: boolean },
): Promise<DashboardMemoryResponse> {
  const params = new URLSearchParams()
  params.set('sort_by', sortMode)
  if (opts?.excludeSystem) params.set('exclude_system', 'true')
  return get(`/api/v1/dashboard/memory${params.toString() ? `?${params}` : ''}`)
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
    return {
      generated_at: asNullableIsoTimestamp(raw.generated_at) ?? undefined,
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
      pending_actions: pendingActions,
    }
  })
}

export interface RuntimeParam {
  key: string
  current: unknown
  default: unknown
  has_override: boolean
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

export function fetchGovernanceFeed(filter = 'decisions', limit = 20): Promise<unknown[]> {
  return get(`/api/v1/governance/feed?filter=${filter}&limit=${limit}`)
}

export function fetchDashboardSemantics(): Promise<DashboardSemanticsResponse> {
  return get('/api/v1/dashboard/semantics')
}

export function fetchDashboardMission(): Promise<DashboardMissionResponse> {
  return get('/api/v1/dashboard/mission')
}

export function fetchDashboardMissionSession(sessionId: string): Promise<DashboardMissionSessionDetailResponse> {
  const query = `?session_id=${encodeURIComponent(sessionId)}`
  return get(`/api/v1/dashboard/session${query}`)
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
  tier: string
}

export interface ToolMetricsResponse {
  total_calls: number
  distinct_tools_called: number
  top_20: ToolMetricsTopEntry[]
  never_called_count: number
  tier_distribution: { essential: number; standard: number; full: number }
  dispatch_v2_enabled: boolean
  registered_count: number
}

export interface DashboardToolsResponse {
  generated_at?: string
  tool_inventory: DashboardToolInventoryResponse
  tool_usage: ToolMetricsResponse
}

export function fetchToolMetrics(): Promise<ToolMetricsResponse> {
  return get('/api/v1/tool-metrics')
}

export function fetchDashboardTools(): Promise<DashboardToolsResponse> {
  return get('/api/v1/dashboard/tools')
}

// --- Individual resource fetchers (selective SSE-driven refresh) ---

export interface PaginatedAgentsResponse {
  agents: unknown[]
  limit: number
  offset: number
  total: number
}

export interface PaginatedTasksResponse {
  tasks: unknown[]
  limit: number
  offset: number
  total: number
}

export interface PaginatedMessagesResponse {
  messages: unknown[]
  limit: number
  since_seq: number
  total: number
}

export function fetchAgentsList(): Promise<PaginatedAgentsResponse> {
  return get('/api/v1/agents?limit=100')
}

export function fetchTasksList(opts?: {
  includeDone?: boolean
  includeCancelled?: boolean
}): Promise<PaginatedTasksResponse> {
  const params = new URLSearchParams({ limit: '200' })
  if (opts?.includeDone) params.set('include_done', 'true')
  if (opts?.includeCancelled) params.set('include_cancelled', 'true')
  return get(`/api/v1/tasks?${params}`)
}

export function fetchMessagesList(sinceSeq?: number): Promise<PaginatedMessagesResponse> {
  const params = new URLSearchParams({ limit: '50' })
  if (sinceSeq != null && sinceSeq > 0) params.set('since_seq', String(sinceSeq))
  return get(`/api/v1/messages?${params}`)
}

export interface FetchMdalLoopsOptions {
  limit?: number
  historyLimit?: number
  status?: 'running' | 'interrupted' | 'completed' | 'stopped' | 'error'
}

export interface MdalLoopsResponse {
  loops?: unknown[]
  total?: number
  returned?: number
  limit?: number
  history_limit?: number
  status?: string | null
}

export function fetchMdalLoops(options: FetchMdalLoopsOptions = {}): Promise<MdalLoopsResponse> {
  return withRetries('fetchMdalLoops', async () => {
    const params = new URLSearchParams()
    if (options.limit != null) params.set('limit', String(options.limit))
    if (options.historyLimit != null) params.set('history_limit', String(options.historyLimit))
    if (options.status) params.set('status', options.status)
    const query = params.toString()
    return get<MdalLoopsResponse>(`/api/v1/mdal/loops${query ? `?${query}` : ''}`)
  })
}

export function fetchOperatorSnapshot(): Promise<OperatorSnapshot> {
  return get('/api/v1/operator')
}

export function fetchOperatorDigest(options: {
  targetType?: 'room' | 'team_session'
  targetId?: string
  includeWorkers?: boolean
} = {}): Promise<OperatorDigest> {
  const params = new URLSearchParams()
  if (options.targetType) params.set('target_type', options.targetType)
  if (options.targetId) params.set('target_id', options.targetId)
  if (options.includeWorkers != null) params.set('include_workers', options.includeWorkers ? 'true' : 'false')
  const query = params.toString()
  return get(`/api/v1/operator/digest${query ? `?${query}` : ''}`)
}

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

export function fetchCommandPlaneSwarm(
  runId?: string,
  operationId?: string,
): Promise<CommandPlaneSwarmResponse> {
  const params = new URLSearchParams()
  if (runId) params.set('run_id', runId)
  if (operationId) params.set('operation_id', operationId)
  const query = params.toString()
  return get(`/api/v1/command-plane/swarm${query ? `?${query}` : ''}`)
}

export function fetchCommandPlaneOrchestra(
  runId?: string,
  operationId?: string,
): Promise<CommandPlaneOrchestraResponse> {
  const params = new URLSearchParams()
  if (runId) params.set('run_id', runId)
  if (operationId) params.set('operation_id', operationId)
  const query = params.toString()
  return get(`/api/v1/command-plane/orchestra${query ? `?${query}` : ''}`)
}
