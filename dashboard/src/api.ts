// MASC Dashboard — Typed API client
// All fetch calls go through this module for consistent auth and typing

import { isRecord } from './components/common/normalize'
import {
  formatKeeperVisibleReply,
  normalizeKeeperConversationDetails,
  normalizeKeeperToolResponse,
} from './keeper-message'
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
  OperatorActionRequest,
  OperatorActionResult,
  OperatorDigest,
  OperatorSnapshot,
  KeeperConversationDetails,
  CommandPlaneHelpResponse,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneSnapshot,
  CommandPlaneSwarmResponse,
  CommandPlaneOrchestraResponse,
  CommandPlaneSummarySnapshot,
} from './types'

// --- Auth ---

function getQueryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search)
}

const DASHBOARD_AGENT_NAME_KEY = 'masc_dashboard_agent_name'

function readStoredAgentName(): string | null {
  try {
    return localStorage.getItem(DASHBOARD_AGENT_NAME_KEY)?.trim() || null
  } catch {
    return null
  }
}

export function currentDashboardActor(): string {
  const params = getQueryParams()
  return (
    params.get('agent')?.trim()
    || params.get('agent_name')?.trim()
    || readStoredAgentName()
    || 'dashboard'
  )
}

function authHeaders(): Record<string, string> {
  const params = getQueryParams()
  const headers: Record<string, string> = {}
  const token = params.get('token')
  const storedAgent = readStoredAgentName()
  const agent = params.get('agent') ?? params.get('agent_name') ?? storedAgent
  if (token) headers['Authorization'] = `Bearer ${token}`
  if (agent) headers['X-MASC-Agent'] = agent
  return headers
}

function jsonHeaders(): Record<string, string> {
  return {
    ...authHeaders(),
    'Content-Type': 'application/json',
  }
}

const DEFAULT_GET_TIMEOUT_MS = 15_000
const DEFAULT_POST_TIMEOUT_MS = 30_000
const DEFAULT_MCP_TIMEOUT_MS = 60_000
const ROOM_TRUTH_GET_TIMEOUT_MS = 30_000
const RETRYABLE_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504])

class ApiRequestError extends Error {
  method: string
  path: string
  status?: number
  statusText?: string
  timeout: boolean

  constructor(opts: {
    method: string
    path: string
    status?: number
    statusText?: string
    timeout?: boolean
    timeoutMs?: number
  }) {
    const method = opts.method.toUpperCase()
    const timeout = opts.timeout === true
    const message = timeout
      ? `${method} ${opts.path}: timeout after ${opts.timeoutMs ?? 0}ms`
      : `${method} ${opts.path}: ${opts.status ?? 'unknown'} ${opts.statusText ?? ''}`.trim()
    super(message)
    this.name = 'ApiRequestError'
    this.method = method
    this.path = opts.path
    this.status = opts.status
    this.statusText = opts.statusText
    this.timeout = timeout
  }
}

export async function fetchWithTimeout(path: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(path, {
      ...init,
      signal: controller.signal,
    })
  } catch (err) {
    if (err instanceof Error && err.name === 'AbortError') {
      const method = typeof init.method === 'string' ? init.method.toUpperCase() : 'GET'
      throw new ApiRequestError({
        method,
        path,
        timeout: true,
        timeoutMs,
      })
    }
    throw err
  } finally {
    clearTimeout(timer)
  }
}

export function defaultBoardVoter(): string {
  const params = getQueryParams()
  return (
    params.get('agent')?.trim() ||
    params.get('agent_name')?.trim() ||
    'dashboard-user'
  )
}

// --- Generic fetcher ---

export type GetOptions = {
  timeoutMs?: number
}

export async function get<T>(path: string, opts: GetOptions = {}): Promise<T> {
  const res = await fetchWithTimeout(
    path,
    { headers: authHeaders() },
    opts.timeoutMs ?? DEFAULT_GET_TIMEOUT_MS,
  )
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'GET',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.json() as Promise<T>
}

export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function parseStatusFromMessage(message: string): number | null {
  const match = message.match(/\b(\d{3})\b/)
  if (!match) return null
  const statusToken = match[1]
  if (!statusToken) return null
  const status = Number.parseInt(statusToken, 10)
  return Number.isFinite(status) ? status : null
}

function isRetryableError(err: unknown): boolean {
  if (err instanceof ApiRequestError) {
    return err.timeout || (typeof err.status === 'number' && RETRYABLE_STATUS_CODES.has(err.status))
  }

  if (!(err instanceof Error)) return false
  if (/timeout after \d+ms/i.test(err.message)) return true
  const parsedStatus = parseStatusFromMessage(err.message)
  return parsedStatus !== null && RETRYABLE_STATUS_CODES.has(parsedStatus)
}

export async function withRetries<T>(
  operation: string,
  run: () => Promise<T>,
  retries = 2,
): Promise<T> {
  let attempt = 0

  while (true) {
    try {
      return await run()
    } catch (err) {
      if (!isRetryableError(err) || attempt >= retries) throw err
      const delayMs = 250 * (attempt + 1)
      console.warn(`[dashboard/api] ${operation} failed (attempt ${attempt + 1}), retrying in ${delayMs}ms`, err)
      await sleep(delayMs)
      attempt += 1
    }
  }
}

export async function post<T>(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<T> {
  const res = await fetchWithTimeout(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  }, timeoutMs)
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'POST',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.json() as Promise<T>
}

export async function postRaw(
  path: string,
  body: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = DEFAULT_POST_TIMEOUT_MS,
): Promise<string> {
  const res = await fetchWithTimeout(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  }, timeoutMs)
  if (!res.ok) {
    throw new ApiRequestError({
      method: 'POST',
      path,
      status: res.status,
      statusText: res.statusText,
    })
  }
  return res.text()
}

// --- MCP over HTTP helper ---

interface McpCallResponse {
  result?: {
    content?: Array<{ type?: string; text?: string }>
    isError?: boolean
  }
  error?: { message?: string }
}

export interface KeeperToolReply {
  text: string
  details: KeeperConversationDetails | null
}

export interface KeeperChatStreamEvent {
  type: string
  threadId?: string
  runId?: string
  messageId?: string
  role?: string
  delta?: string
  name?: string
  value?: unknown
  timestamp?: number
}

function parseMcpHttpResponse(raw: string): McpCallResponse {
  // Streamable HTTP may return SSE-formatted payload; extract first "data:" line
  const line = raw.split('\n').find(l => l.startsWith('data: '))
  const payload = line ? line.slice(6).trim() : raw.trim()
  return JSON.parse(payload) as McpCallResponse
}

function extractMcpText(res: McpCallResponse): string {
  if (res.error?.message) throw new Error(res.error.message)
  if (res.result?.isError) {
    const err = res.result.content?.[0]?.text ?? 'MCP tool call failed'
    throw new Error(err)
  }
  return res.result?.content?.[0]?.text ?? ''
}

export async function callMcpTool(toolName: string, args: Record<string, unknown>): Promise<string> {
  const text = await postRaw('/mcp', {
    jsonrpc: '2.0',
    method: 'tools/call',
    params: {
      name: toolName,
      arguments: args,
    },
    id: Math.floor(Date.now() % 1000000),
  }, {
    Accept: 'application/json, text/event-stream',
  }, DEFAULT_MCP_TIMEOUT_MS)
  const parsed = parseMcpHttpResponse(text)
  return extractMcpText(parsed)
}

function parseMcpJsonText(text: string): Record<string, unknown> {
  const trimmed = text.trim()
  if (!trimmed) return {}
  return JSON.parse(trimmed) as Record<string, unknown>
}

export async function fetchAutoresearchStatus(loopId: string): Promise<Record<string, unknown>> {
  return parseMcpJsonText(await callMcpTool('masc_autoresearch_status', { loop_id: loopId }))
}

export async function injectAutoresearchHypothesis(
  loopId: string,
  hypothesis: string,
): Promise<Record<string, unknown>> {
  return parseMcpJsonText(
    await callMcpTool('masc_autoresearch_inject', {
      loop_id: loopId,
      hypothesis,
    }),
  )
}

export async function runAutoresearchCycle(loopId: string): Promise<Record<string, unknown>> {
  return parseMcpJsonText(await callMcpTool('masc_autoresearch_cycle', { loop_id: loopId }))
}

export async function stopAutoresearchLoop(
  loopId: string,
  reason?: string,
): Promise<Record<string, unknown>> {
  return parseMcpJsonText(
    await callMcpTool('masc_autoresearch_stop', {
      loop_id: loopId,
      ...(reason ? { reason } : {}),
    }),
  )
}

async function callKeeperMessageRaw(
  name: string,
  message: string,
  models?: string[],
): Promise<string> {
  const args: Record<string, unknown> = { name, message }
  if (models && models.length > 0) args.models = models
  return callMcpTool('masc_keeper_msg', args)
}

async function callKeeperMessageViaOperator(
  name: string,
  message: string,
  models?: string[],
): Promise<KeeperToolReply> {
  const payload: Record<string, unknown> = { message }
  if (models && models.length > 0) payload.models = models
  const response = await runOperatorAction({
    actor: currentDashboardActor(),
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: name,
    payload,
  })

  const resultPayload = isRecord(response.result) ? response.result : null
  const rawReply =
    resultPayload && typeof resultPayload.reply === 'string'
      ? resultPayload.reply
      : ''
  const detailsRaw =
    resultPayload && isRecord(resultPayload.result)
      ? resultPayload.result
      : resultPayload
  const details = normalizeKeeperConversationDetails(detailsRaw)
  const text = formatKeeperVisibleReply(rawReply || '(empty reply)')
  return { text, details }
}

export async function sendKeeperMessageDetailed(
  name: string,
  message: string,
  models?: string[],
): Promise<KeeperToolReply> {
  if (models && models.length > 0) {
    const raw = await callKeeperMessageRaw(name, message, models)
    return normalizeKeeperToolResponse(raw)
  }
  return callKeeperMessageViaOperator(name, message)
}

export function sendKeeperMessage(name: string, message: string, models?: string[]): Promise<string> {
  return sendKeeperMessageDetailed(name, message, models).then(reply => reply.text)
}

function parseSseFrames(chunk: string): { frames: string[]; rest: string } {
  const normalized = chunk.replace(/\r\n/g, '\n')
  const frames: string[] = []
  let start = 0
  for (;;) {
    const split = normalized.indexOf('\n\n', start)
    if (split < 0) {
      return {
        frames,
        rest: normalized.slice(start),
      }
    }
    frames.push(normalized.slice(start, split))
    start = split + 2
  }
}

function parseSseEvent(frame: string): KeeperChatStreamEvent | null {
  const dataLines = frame
    .split('\n')
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trimStart())
  if (dataLines.length === 0) return null
  try {
    return JSON.parse(dataLines.join('\n')) as KeeperChatStreamEvent
  } catch {
    return null
  }
}

export async function streamKeeperMessage(
  name: string,
  message: string,
  models: string[] | undefined,
  {
    signal,
    onEvent,
  }: {
    signal?: AbortSignal
    onEvent: (event: KeeperChatStreamEvent) => void
  },
): Promise<void> {
  const res = await fetch('/api/v1/keepers/chat/stream', {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      Accept: 'text/event-stream',
    },
    body: JSON.stringify({
      name,
      message,
      ...(models && models.length > 0 ? { models } : {}),
    }),
    signal,
  })

  if (!res.ok) {
    const raw = await res.text()
    let message = raw || `Streaming request failed (${res.status})`
    try {
      const parsed = JSON.parse(raw) as { error?: { message?: string }; message?: string }
      message = parsed.error?.message ?? parsed.message ?? message
    } catch {
      // Keep raw text fallback.
    }
    throw new Error(message)
  }

  if (!res.body) {
    throw new Error('Streaming response body is unavailable')
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    for (;;) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done })
      const { frames, rest } = parseSseFrames(buffer)
      buffer = rest
      for (const frame of frames) {
        const event = parseSseEvent(frame)
        if (event) onEvent(event)
      }
      if (done) break
    }
    const tail = buffer.trim()
    if (tail) {
      const event = parseSseEvent(tail)
      if (event) onEvent(event)
    }
  } finally {
    reader.releaseLock()
  }
}

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

export function runCommandPlaneAction(
  path: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return post(path, body)
}

function operatorActionTimeoutMs(body: OperatorActionRequest): number {
  switch (body.action_type) {
    case 'keeper_message':
    case 'keeper_recover':
      return 90_000
    case 'swarm_run_continue':
      return 60_000
    case 'swarm_run_rerun':
      return 120_000
    case 'swarm_run_abandon':
      return 30_000
    case 'social_sweep':
    case 'lodge_tick':
      return 45_000
    default:
      return DEFAULT_POST_TIMEOUT_MS
  }
}
export function runOperatorAction(body: OperatorActionRequest): Promise<OperatorActionResult> {
  return post('/api/v1/operator/action', body, undefined, operatorActionTimeoutMs(body))
}

export function confirmOperatorAction(
  actor: string,
  confirmToken: string,
  decision: 'confirm' | 'deny' = 'confirm',
): Promise<OperatorActionResult> {
  return post('/api/v1/operator/confirm', {
    actor,
    confirm_token: confirmToken,
    decision,
  })
}

// Re-exports from domain-specific API modules
export * from './api/board'
export * from './api/trpg'
export * from './api/actions'
