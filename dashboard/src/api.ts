// MASC Dashboard — Typed API client
// All fetch calls go through this module for consistent auth and typing

import type {
  DashboardData,
  DashboardExecutionResponse,
  DashboardGovernanceResponse,
  DashboardMemoryResponse,
  DashboardMissionResponse,
  DashboardMissionBriefingResponse,
  DashboardPlanningResponse,
  DashboardShellResponse,
  BoardPost,
  BoardComment,
  BoardHearth,
  BoardFlair,
  TrpgState,
  TrpgEvent,
  Agent,
  MdalIterationRecord,
  MdalLoop,
  CouncilDebate,
  CouncilDebateSummary,
  CouncilSession,
  BoardSortMode,
  OperatorActionRequest,
  OperatorActionResult,
  OperatorDigest,
  OperatorSnapshot,
  DashboardSemanticsResponse,
  CommandPlaneHelpResponse,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneSnapshot,
  CommandPlaneSwarmResponse,
  CommandPlaneSummarySnapshot,
} from './types'

// --- Auth ---

function getQueryParams(): URLSearchParams {
  return new URLSearchParams(window.location.search)
}

function authHeaders(): Record<string, string> {
  const params = getQueryParams()
  const headers: Record<string, string> = {}
  const token = params.get('token')
  const agent = params.get('agent') ?? params.get('agent_name')
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

async function fetchWithTimeout(path: string, init: RequestInit, timeoutMs: number): Promise<Response> {
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

function defaultBoardVoter(): string {
  const params = getQueryParams()
  return (
    params.get('agent')?.trim() ||
    params.get('agent_name')?.trim() ||
    'dashboard-user'
  )
}

// --- Generic fetcher ---

async function get<T>(path: string): Promise<T> {
  const res = await fetchWithTimeout(path, { headers: authHeaders() }, DEFAULT_GET_TIMEOUT_MS)
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

function sleep(ms: number): Promise<void> {
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

async function withRetries<T>(
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

async function post<T>(
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

async function postRaw(
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

// --- Dashboard (batch) ---

export type DashboardMode = 'compact' | 'full'

export function fetchDashboard(mode: DashboardMode = 'compact'): Promise<DashboardData> {
  return get(`/api/v1/dashboard?mode=${mode}`)
}

export function fetchDashboardShell(): Promise<DashboardShellResponse> {
  return get('/api/v1/dashboard/shell')
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
  return get('/api/v1/dashboard/governance')
}

export function fetchDashboardSemantics(): Promise<DashboardSemanticsResponse> {
  return get('/api/v1/dashboard/semantics')
}

export function fetchDashboardMission(): Promise<DashboardMissionResponse> {
  return get('/api/v1/dashboard/mission')
}

export function fetchDashboardMissionBriefing(force = false): Promise<DashboardMissionBriefingResponse> {
  const query = force ? '?force=1' : ''
  return get(`/api/v1/dashboard/mission/briefing${query}`)
}

export function fetchDashboardPlanning(): Promise<DashboardPlanningResponse> {
  return get('/api/v1/dashboard/planning')
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
    case 'lodge_tick':
      return 45_000
    default:
      return DEFAULT_POST_TIMEOUT_MS
  }
}
export function runOperatorAction(body: OperatorActionRequest): Promise<OperatorActionResult> {
  return post('/api/v1/operator/action', body, undefined, operatorActionTimeoutMs(body))
}

export function confirmOperatorAction(actor: string, confirmToken: string): Promise<OperatorActionResult> {
  return post('/api/v1/operator/confirm', {
    actor,
    confirm_token: confirmToken,
  })
}
// --- Board ---

const SYSTEM_BOARD_AUTHORS = new Set(['lodge-system', 'team-session'])

function toIsoTimestamp(value: unknown): string {
  if (typeof value === 'string' && value.trim()) return value
  if (typeof value !== 'number' || Number.isNaN(value)) return new Date().toISOString()
  const ms = value < 1_000_000_000_000 ? value * 1000 : value
  return new Date(ms).toISOString()
}

function isSystemBoardAuthor(author: string): boolean {
  return SYSTEM_BOARD_AUTHORS.has(author.trim().toLowerCase())
}

function filterSystemBoardPosts(posts: BoardPost[]): BoardPost[] {
  return posts.filter(post => !isSystemBoardAuthor(post.author))
}

function derivePostTitle(content: string): string {
  const trimmed = content.trim()
  const withoutFlair = trimmed.startsWith('[flair:') ? trimmed.replace(/^\[flair:[^\]]+\]\s*/i, '') : trimmed
  const firstLine = withoutFlair.split('\n')[0]?.trim() || 'Untitled post'
  if (firstLine.length <= 96) return firstLine
  return `${firstLine.slice(0, 93)}...`
}

function normalizeBoardPost(raw: unknown): BoardPost | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const author = asString(raw.author, '').trim()
  const content = asString(raw.content, '').trim()
  if (!id || !author) return null

  const score = asNumber(raw.score, 0)
  const votesUp = asNumber(raw.votes_up, 0)
  const votesDown = asNumber(raw.votes_down, 0)
  const votes = asNumber(raw.votes, score || (votesUp - votesDown))
  const commentCount = asNumber(raw.comment_count, asNumber(raw.reply_count, 0))
  const flairValue = (() => {
    const flair = raw.flair
    if (typeof flair === 'string' && flair.trim()) return flair.trim()
    if (isRecord(flair)) {
      const name = asString(flair.name, '').trim()
      if (name) return name
    }
    const fallback = asString(raw.flair_name, '').trim()
    return fallback || undefined
  })()
  const createdAt =
    asString(raw.created_at_iso, '').trim() || toIsoTimestamp(raw.created_at)
  const updatedAt =
    asString(raw.updated_at_iso, '').trim()
    || (raw.updated_at !== undefined ? toIsoTimestamp(raw.updated_at) : createdAt)
  const titleRaw = asString(raw.title, '').trim()
  const title = titleRaw || derivePostTitle(content)

  return {
    id,
    author,
    title,
    content,
    tags: [],
    votes,
    vote_balance: score,
    comment_count: commentCount,
    created_at: createdAt,
    updated_at: updatedAt,
    flair: flairValue,
    hearth_count: asNumber(raw.hearth_count, 0),
  }
}

function normalizeBoardComment(raw: unknown): BoardComment | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id, '').trim()
  const postId = asString(raw.post_id, '').trim()
  const author = asString(raw.author, '').trim()
  if (!id || !author) return null
  return {
    id,
    post_id: postId,
    author,
    content: asString(raw.content, ''),
    created_at: toIsoTimestamp(raw.created_at),
  }
}

export async function fetchBoard(
  sortBy?: BoardSortMode,
  options?: { excludeSystem?: boolean },
): Promise<{ posts: BoardPost[] }> {
  return withRetries('fetchBoard', async () => {
    const params = new URLSearchParams()
    if (sortBy) params.set('sort_by', sortBy)
    if (options?.excludeSystem) params.set('exclude_system', 'true')
    params.set('limit', options?.excludeSystem ? '150' : '100')
    const qs = params.toString()
    const raw = await get<{ posts?: unknown[] }>(`/api/v1/board${qs ? `?${qs}` : ''}`)
    const normalizedPosts = Array.isArray(raw.posts)
      ? raw.posts.map(normalizeBoardPost).filter((row): row is BoardPost => row !== null)
      : []
    const posts = options?.excludeSystem ? filterSystemBoardPosts(normalizedPosts) : normalizedPosts
    return { posts }
  })
}

export async function fetchBoardPost(postId: string): Promise<BoardPost & { comments: BoardComment[] }> {
  return withRetries('fetchBoardPost', async () => {
    const raw = await get<Record<string, unknown>>(`/api/v1/board/${postId}?format=flat`)
    const postRaw = isRecord(raw.post) ? raw.post : raw
    const post = normalizeBoardPost(postRaw) ?? {
      id: postId,
      author: 'unknown',
      title: 'Post',
      content: '',
      tags: [],
      votes: 0,
      comment_count: 0,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }
    const commentsRaw = Array.isArray(raw.comments) ? raw.comments : []
    const comments = commentsRaw
      .map(normalizeBoardComment)
      .filter((row): row is BoardComment => row !== null)
    return { ...post, comments }
  })
}

export function fetchBoardHearths(): Promise<{ hearths: BoardHearth[] }> {
  return get('/api/v1/board/hearths')
}

export function fetchBoardFlairs(): Promise<{ flairs: BoardFlair[] }> {
  return get('/api/v1/board/flairs')
}

export function votePost(postId: string, direction: 'up' | 'down'): Promise<unknown> {
  return post('/api/v1/tools/masc_board_vote', {
    post_id: postId,
    direction,
    vote: direction,
    voter: defaultBoardVoter(),
  })
}

export function voteBoardTool(postId: string, vote: 'up' | 'down', voter: string): Promise<unknown> {
  return post('/api/v1/tools/masc_board_vote', {
    post_id: postId,
    direction: vote,
    vote,
    voter,
  })
}

export function commentPost(postId: string, author: string, content: string): Promise<unknown> {
  return post(`/api/v1/tools/masc_board_comment`, {
    post_id: postId,
    author,
    content,
  })
}

// --- TRPG ---

interface TrpgRawStateResponse {
  room_id?: string
  event_count?: number
  state?: unknown
}

interface TrpgRawEventsResponse {
  events?: unknown
}

interface TrpgRawEvent {
  seq?: number
  room_id?: string
  type?: string
  actor_id?: string | null
  actor_name?: string | null
  ts?: string
  timestamp?: string
  phase?: string
  category?: string
  visibility?: string
  event_id?: string
  payload?: unknown
}

function parseOutcomeResult(value: unknown): 'victory' | 'defeat' | 'draw' | undefined {
  const normalized = asString(value, '').trim().toLowerCase()
  if (normalized === 'win' || normalized === 'won' || normalized === 'victory') return 'victory'
  if (normalized === 'lose' || normalized === 'lost' || normalized === 'defeat') return 'defeat'
  if (normalized === 'draw' || normalized === 'stalemate' || normalized === 'tie') return 'draw'
  return undefined
}

function firstString(...values: unknown[]): string {
  for (const value of values) {
    const text = asString(value, '')
    if (text.trim()) return text.trim()
  }
  return ''
}

function parseSessionOutcomePayload(payload: Record<string, unknown>): {
  result: 'victory' | 'defeat' | 'draw'
  reason?: string
  summary?: string
  details?: string
  winner?: string
  winner_actor_id?: string
  evidence?: string[]
  raw_reason?: string
  turn?: number
  phase?: string
} | undefined {
  const result = parseOutcomeResult(firstString(payload.outcome, payload.result, payload.result_code))
  if (!result) return undefined
  const reason = firstString(
    payload.reason,
    payload.reason_code,
    payload.description,
    payload.detail,
  )
  const summary = firstString(payload.summary, payload.summary_ko, payload.summary_en, payload.note)
  const details = firstString(
    payload.details,
    payload.details_text,
    payload.text,
    payload.note,
  )
  const winner = firstString(
    payload.winner,
    payload.winner_name,
    payload.actor_winner,
    payload.winner_actor,
  )
  const winnerActorId = firstString(
    payload.winner_actor_id,
    payload.winner_actor,
    payload.actor_winner_id,
  )
  const rawReason = firstString(payload.raw_reason, payload.raw_reason_code, payload.error_message)
  const evidence = (() => {
    const rawEvidence =
      payload.evidence ??
      payload.evidence_ids ??
      payload.supporting_events ??
      payload.event_ids ??
      []
    if (typeof rawEvidence === 'string') return [rawEvidence]
    if (!Array.isArray(rawEvidence)) return []
    return rawEvidence
      .map(item => {
        if (typeof item === 'string') return item.trim()
        if (isRecord(item)) {
          const fromSummary = asString(item.summary, '').trim()
          if (fromSummary) return fromSummary
          const fromText = asString(item.text, '').trim()
          if (fromText) return fromText
          const fromType = asString(item.type, '').trim()
          if (fromType) return fromType
          return asString(item.event_id, '').trim()
        }
        return ''
      })
      .filter((item): item is string => item.length > 0)
  })()
  const turn = (() => {
    const fromTurn = asNumber(payload.turn, Number.NaN)
    if (Number.isFinite(fromTurn)) return fromTurn
    const fromTurnNumber = asNumber(payload.turn_number, Number.NaN)
    if (Number.isFinite(fromTurnNumber)) return fromTurnNumber
    const fromCurrentTurn = asNumber(payload.current_turn, Number.NaN)
    if (Number.isFinite(fromCurrentTurn)) return fromCurrentTurn
    const fromRound = asNumber(payload.round, Number.NaN)
    return Number.isFinite(fromRound) ? fromRound : undefined
  })()
  const phase = firstString(payload.phase, payload.phase_name, payload.current_phase, payload.phase_id)
  return {
    result,
    reason: reason || undefined,
    summary: summary || undefined,
    details: details || undefined,
    winner: winner || undefined,
    winner_actor_id: winnerActorId || undefined,
    evidence: evidence.length > 0 ? evidence : undefined,
    raw_reason: rawReason || undefined,
    turn,
    phase: phase || undefined,
  }
}

function parseSessionOutcomeFromEvents(
  rawStateResponse: TrpgRawStateResponse,
  rawEvents: unknown[],
): {
  result: 'victory' | 'defeat' | 'draw'
  reason?: string
  summary?: string
  details?: string
  winner?: string
  winner_actor_id?: string
  evidence?: string[]
  raw_reason?: string
  turn?: number
  phase?: string
} | undefined {
  const stateRaw = isRecord(rawStateResponse.state) ? rawStateResponse.state : {}
  const statusRaw = asString(stateRaw.status, 'active').toLowerCase()
  if (statusRaw !== 'ended') return undefined

  const latest = [...rawEvents].reverse().find(raw => {
    if (!isRecord(raw)) return false
    return asString(raw.type, '') === 'session.outcome'
  })
  const stateOutcome = isRecord(stateRaw.session_outcome) ? stateRaw.session_outcome : {}
  if (isRecord(stateOutcome) && Object.keys(stateOutcome).length > 0) {
    const fromState = parseSessionOutcomePayload(stateOutcome)
    if (fromState) return fromState
  }

  if (!isRecord(latest)) return undefined
  return parseSessionOutcomePayload(isRecord(latest.payload) ? latest.payload : {})
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function asInt(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value === 'string') {
    const parsed = Number.parseInt(value.trim(), 10)
    if (Number.isFinite(parsed)) return parsed
  }
  return undefined
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => {
      if (typeof item === 'string') return item.trim()
      if (isRecord(item)) {
        const fromName = asString(item.name, '').trim()
        const fromId = asString(item.id, '').trim()
        const fromSkill = asString(item.skill, '').trim()
        return fromName || fromId || fromSkill
      }
      return ''
    })
    .filter((item): item is string => item.length > 0)
}

function asStringMap(value: unknown): Record<string, string> {
  const result: Record<string, string> = {}

  if (!isRecord(value) && !Array.isArray(value)) return result
  if (isRecord(value)) {
    Object.entries(value).forEach(([key, rawValue]) => {
      const normalizedKey = key.trim()
      const text = asString(rawValue, '').trim()
      if (!normalizedKey || !text) return
      result[normalizedKey] = text
    })
    return result
  }

  for (const item of value) {
    if (!isRecord(item)) continue
    const target = firstString(
      item.to,
      item.target,
      item.actor_id,
      item.name,
      item.id,
    )
    const relation = firstString(
      item.relationship,
      item.relation,
      item.type,
      item.kind,
    )
    if (!target || !relation) continue
    result[target] = relation
  }

  return result
}

function normalizeRole(
  value: unknown,
  actorId: string,
  keeper?: string,
): 'dm' | 'player' | 'npc' {
  if (value === 'dm' || value === 'player' || value === 'npc') return value
  const actorKey = actorId.trim().toLowerCase()
  if (actorKey === 'dm' || actorKey.startsWith('dm-')) return 'dm'
  if (
    actorKey.startsWith('npc-') ||
    actorKey.startsWith('enemy-') ||
    actorKey.startsWith('mob-')
  ) {
    return 'npc'
  }
  if (/^p\d+$/i.test(actorKey) || actorKey.startsWith('player-')) return 'player'
  if (typeof keeper === 'string' && keeper.trim() !== '') {
    const keeperKey = keeper.trim().toLowerCase()
    if (keeperKey.includes('dm')) return 'dm'
    return 'player'
  }
  return 'npc'
}

function statFromActor(actor: Record<string, unknown>, primary: string, fallbackKey?: string, fallback = 0): number {
  const primaryValue = actor[primary]
  if (typeof primaryValue === 'number' && Number.isFinite(primaryValue)) return primaryValue
  if (fallbackKey) {
    const secondary = actor[fallbackKey]
    if (typeof secondary === 'number' && Number.isFinite(secondary)) return secondary
  }
  return fallback
}

const KNOWN_ACTOR_STATS_KEYS = new Set([
  'str',
  'dex',
  'con',
  'int',
  'wis',
  'cha',
  'strength',
  'dexterity',
  'constitution',
  'intelligence',
  'wisdom',
  'charisma',
  'hp',
  'max_hp',
  'mp',
  'max_mp',
  'level',
  'xp',
])

function collectCustomStats(actor: Record<string, unknown>): Record<string, number> {
  const stats = isRecord(actor.stats) ? actor.stats : {}
  const custom: Record<string, number> = {}
  Object.entries(stats).forEach(([key, value]) => {
    const statKey = key.trim()
    if (!statKey) return
    if (KNOWN_ACTOR_STATS_KEYS.has(statKey.toLowerCase())) return
    if (typeof value === 'number' && Number.isFinite(value)) {
      custom[statKey] = value
    }
  })
  return custom
}

function normalizeDiceRoll(type: string, payload: Record<string, unknown>): TrpgEvent['dice_roll'] | undefined {
  if (type !== 'dice.rolled') return undefined
  const rawD20 = asNumber(payload.raw_d20, 0)
  const total = asNumber(payload.total, 0)
  const bonus = asNumber(payload.bonus, 0)
  const action = asString(payload.action, 'roll')
  const dc = asNumber(payload.dc, 0)
  const notation = dc > 0 ? `${action} (DC ${dc})` : action
  return {
    notation,
    rolls: rawD20 > 0 ? [rawD20] : [],
    total,
    modifier: bonus,
  }
}

function stringifyPayload(payload: Record<string, unknown>): string {
  const compact = JSON.stringify(payload)
  if (!compact) return ''
  return compact.length > 160 ? `${compact.slice(0, 157)}...` : compact
}

function eventCategoryFromType(type: string): string {
  const lower = type.trim().toLowerCase()
  if (!lower) return 'meta'
  if (lower.startsWith('dice.')) return 'dice'
  if (lower.startsWith('combat.') || lower.includes('.attack') || lower.includes('.damage')) return 'combat'
  if (lower.includes('actor.')) return 'actor'
  if (lower.includes('turn.') || lower === 'turn.started' || lower === 'phase.changed') return 'turn'
  if (lower.includes('join.')) return 'join'
  if (lower.includes('memory')) return 'memory'
  if (lower.includes('world.')) return 'world'
  if (lower.includes('narration')) return 'story'
  return 'meta'
}

function eventContent(
  type: string,
  actorId: string,
  actorName: string,
  payload: Record<string, unknown>,
): string {
  const actorLabel = actorName || actorId || asString(payload.actor_id, '') || asString(payload.actor_name, '')
  switch (type) {
    case 'turn.action.proposed': {
      const reply = asString(payload.proposed_action, asString(payload.reply, ''))
      return reply ? `${actorLabel || 'actor'}: ${reply}` : 'Action proposed'
    }
    case 'turn.action.resolved': {
      const reply = asString(payload.reply, asString(payload.result, ''))
      return reply ? `Resolved: ${reply}` : 'Action resolved'
    }
    case 'narration.posted':
      return asString(payload.reply, asString(payload.content, asString(payload.text, 'Narration')))
    case 'dice.rolled': {
      const action = asString(payload.action, 'roll')
      const total = asNumber(payload.total, 0)
      const dc = asNumber(payload.dc, 0)
      const label = asString(payload.label, '')
      const subject = actorLabel || 'actor'
      const dcPart = dc > 0 ? ` vs DC ${dc}` : ''
      const labelPart = label ? ` (${label})` : ''
      return `${subject} ${action}: ${total}${dcPart}${labelPart}`
    }
    case 'turn.started':
      return `Turn ${asNumber(payload.turn, 1)} started`
    case 'phase.changed':
      return `Phase: ${asString(payload.phase, 'round')}`
    case 'actor.spawned':
      return `Actor spawned: ${asString(
        payload.name,
        isRecord(payload.actor)
          ? asString(payload.actor.name, actorLabel || 'unknown')
          : (actorLabel || 'unknown'),
      )}`
    case 'actor.claimed':
      return `${asString(payload.keeper_name, asString(payload.keeper, 'keeper'))} claimed ${actorLabel || 'actor'}`
    case 'actor.released':
      return `${asString(payload.keeper_name, asString(payload.keeper, 'keeper'))} released ${actorLabel || 'actor'}`
    case 'join.window.opened':
      return `Join window opened (turn ${asNumber(payload.turn, 0)})`
    case 'join.window.closed':
      return `Join window closed (turn ${asNumber(payload.turn, 0)})`
    case 'mid.join.requested':
      return `Mid-join requested: ${actorLabel || asString(payload.actor_id, 'actor')}`
    case 'mid.join.granted':
      return `Mid-join granted: ${actorLabel || asString(payload.actor_id, 'actor')}`
    case 'mid.join.rejected':
      return `Mid-join rejected: ${asString(payload.reason_code, 'unknown')}`
    case 'memory.signal': {
      const refs = isRecord(payload.entity_refs) ? payload.entity_refs : {}
      const requested = asString(refs.requested_tier, '')
      const effective = asString(refs.effective_tier, '')
      const guardrail = asBoolean(refs.guardrail_applied, false)
      const summary = asString(payload.summary_en, asString(payload.summary_ko, 'Memory signal'))
      if (!requested && !effective) return summary
      const tierLabel = requested && effective
        ? `${requested}->${effective}`
        : (effective || requested)
      const guardrailLabel = guardrail ? ' (guardrail)' : ''
      return `${summary} [${tierLabel}${guardrailLabel}]`
    }
    case 'world.event': {
      const evtType = asString(payload.event_type, '')
      if (evtType === 'canon.check') {
        const status = asString(payload.status, 'unknown')
        const contract = asString(payload.contract_id, 'n/a')
        return `Canon ${status}: ${contract}`
      }
      return asString(payload.description, asString(payload.summary, 'World event'))
    }
    case 'combat.attack':
      return asString(payload.summary, asString(payload.result, 'Attack resolved'))
    case 'combat.defense':
      return asString(payload.summary, asString(payload.result, 'Defense resolved'))
    case 'session.outcome':
      return asString(payload.summary, asString(payload.outcome, 'Session ended'))
    default: {
      const details = stringifyPayload(payload)
      return details ? `${type}: ${details}` : type
    }
  }
}

function normalizeRawEvent(
  value: unknown,
  actorNameById: Record<string, string>,
): TrpgEvent {
  const raw = isRecord(value) ? (value as TrpgRawEvent) : {}
  const type = asString(raw.type, 'event')
  const actorId = typeof raw.actor_id === 'string' && raw.actor_id.trim() ? raw.actor_id.trim() : ''
  const actorName =
    asString(raw.actor_name, '').trim() ||
    actorNameById[actorId] ||
    asString((isRecord(raw.payload) ? raw.payload.actor_name : ''), '')
  const payload = isRecord(raw.payload) ? raw.payload : {}
  const timestamp = asString(raw.ts, asString(raw.timestamp, new Date().toISOString()))
  const phase = asString(raw.phase, asString(payload.phase, ''))
  const category = asString(raw.category, '')

  return {
    type,
    actor: actorName || actorId || asString(payload.actor_name, ''),
    actor_id: actorId || asString(payload.actor_id, ''),
    actor_name: actorName,
    seq: raw.seq,
    room_id: asString(raw.room_id, ''),
    phase: phase || undefined,
    category: category || eventCategoryFromType(type),
    visibility: asString(raw.visibility, asString(payload.visibility, 'public')),
    event_id: asString(raw.event_id, ''),
    content: eventContent(type, actorId, actorName, payload),
    dice_roll: normalizeDiceRoll(type, payload),
    timestamp,
  }
}

function normalizeTrpgState(
  rawStateResponse: TrpgRawStateResponse,
  rawEvents: unknown[],
  requestedRoom?: string,
): TrpgState {
  const roomId =
    asString(rawStateResponse.room_id, '') ||
    requestedRoom ||
    'default'
  const state = isRecord(rawStateResponse.state) ? rawStateResponse.state : {}
  const partyJson = isRecord(state.party) ? state.party : {}
  const actorControl = isRecord(state.actor_control) ? state.actor_control : {}
  const joinGateRaw = isRecord(state.join_gate) ? state.join_gate : {}
  const contributionRaw = isRecord(state.contribution_ledger) ? state.contribution_ledger : {}

  const allActors = Object.entries(partyJson).map(([actorId, actorValue]) => {
    const actor = isRecord(actorValue) ? actorValue : {}
    const maxHp = statFromActor(actor, 'max_hp', undefined, 10)
    const hp = statFromActor(actor, 'hp', undefined, maxHp)
    const maxMp = statFromActor(actor, 'max_mp', undefined, 0)
    const mp = statFromActor(actor, 'mp', undefined, 0)
    const level = statFromActor(actor, 'level', undefined, 1)
    const xp = statFromActor(actor, 'xp', undefined, 0)
    const alive = asBoolean(actor.alive, hp > 0)
    const keeperValue = actorControl[actorId]
    const keeper = typeof keeperValue === 'string' ? keeperValue : undefined
    const role = normalizeRole(actor.role, actorId, keeper)
    const generation = asInt(actor.generation)
    const joinedAt = firstString(
      actor.joined_at,
      actor.joinedAt,
      actor.started_at,
      actor.startedAt,
    )
    const claimedAt = firstString(
      actor.claimed_at,
      actor.claimedAt,
      actor.assigned_at,
      actor.assignedAt,
      actor.assigned_time,
    )
    const lastSeen = firstString(
      actor.last_seen,
      actor.lastSeen,
      actor.last_seen_at,
      actor.lastSeenAt,
      actor.last_active,
      actor.lastActive,
    )
    const actorScene = firstString(
      actor.scene,
      actor.current_scene,
      actor.currentScene,
      actor.world_scene,
      actor.scene_name,
      actor.sceneName,
    )
    const actorLocation = firstString(
      actor.location,
      actor.current_location,
      actor.currentLocation,
      actor.position,
      actor.zone,
      actor.area,
    )

    return {
      id: actorId,
      name: asString(actor.name, actorId),
      role,
      keeper,
      archetype: asString(actor.archetype, ''),
      persona: asString(actor.persona, ''),
      portrait: asString(actor.portrait, '') || undefined,
      background: asString(actor.background, '') || undefined,
      traits: asStringList(actor.traits),
      skills: asStringList(actor.skills),
      stats_raw: collectCustomStats(actor),
      status: alive ? 'active' : 'dead',
      generation,
      joined_at: joinedAt || undefined,
      claimed_at: claimedAt || undefined,
      last_seen: lastSeen || undefined,
      scene: actorScene || undefined,
      location: actorLocation || undefined,
      inventory: asStringList(actor.inventory),
      notes: asStringList(actor.notes),
      relationships: asStringMap(actor.relationships),
      stats: {
        hp,
        max_hp: maxHp,
        mp,
        max_mp: maxMp,
        level,
        xp,
        strength: statFromActor(actor, 'strength', 'str', 10),
        dexterity: statFromActor(actor, 'dexterity', 'dex', 10),
        constitution: statFromActor(actor, 'constitution', 'con', 10),
        intelligence: statFromActor(actor, 'intelligence', 'int', 10),
        wisdom: statFromActor(actor, 'wisdom', 'wis', 10),
        charisma: statFromActor(actor, 'charisma', 'cha', 10),
      },
    }
  })
  const party = allActors.filter(actor => actor.status !== 'dead')
  const outcome = parseSessionOutcomeFromEvents(rawStateResponse, rawEvents)

  const joinGate = {
    phase_open: asBoolean(joinGateRaw.phase_open, true),
    min_points: asNumber(joinGateRaw.min_points, 3),
    window: asString(joinGateRaw.window, 'round_boundary_only'),
    last_opened_turn:
      typeof joinGateRaw.last_opened_turn === 'number' ? joinGateRaw.last_opened_turn : null,
    last_closed_turn:
      typeof joinGateRaw.last_closed_turn === 'number' ? joinGateRaw.last_closed_turn : null,
  }

  const contributionLedger = Object.entries(contributionRaw).map(([actorId, entry]) => {
    const row = isRecord(entry) ? entry : {}
    return {
      actor_id: actorId,
      score: asNumber(row.score, 0),
      last_reason: asString(row.last_reason, '') || null,
      reasons: asStringList(row.reasons),
    }
  })

  const actorNameById = allActors.reduce<Record<string, string>>((acc, actor) => {
    acc[actor.id] = actor.name
    return acc
  }, {})
  const storyLog = rawEvents.map(event => normalizeRawEvent(event, actorNameById))
  const roundNumber = asNumber(state.turn, 1)
  const phase = asString(state.phase, 'round')
  const mapValue = asString(state.map, '')
  const world = isRecord(state.world) ? state.world : {}
  const map = mapValue || asString(world.ascii_map, asString(world.map, ''))
  const sameTurnEvents = storyLog.filter((_, idx) => {
    const raw = rawEvents[idx]
    if (!isRecord(raw)) return false
    const payload = isRecord(raw.payload) ? raw.payload : {}
    return asNumber(payload.turn, -1) === roundNumber
  })
  const roundEvents = (sameTurnEvents.length > 0 ? sameTurnEvents : storyLog).slice(-12)
  const statusRaw = asString(state.status, 'active')
  const sessionStatus: 'active' | 'paused' | 'ended' =
    statusRaw === 'ended' ? 'ended' : statusRaw === 'paused' ? 'paused' : 'active'

  return {
    session: {
      id: roomId,
      room: roomId,
      status: sessionStatus,
      round: roundNumber,
      actors: party,
      created_at: storyLog[0]?.timestamp ?? new Date().toISOString(),
    },
    current_round: {
      round_number: roundNumber,
      phase,
      events: roundEvents,
      timestamp: storyLog[storyLog.length - 1]?.timestamp ?? new Date().toISOString(),
    },
    map: map || undefined,
    join_gate: joinGate,
    contribution_ledger: contributionLedger,
    outcome,
    party,
    story_log: storyLog,
    history: [],
  }
}

async function fetchTrpgEventsRaw(room?: string): Promise<unknown[]> {
  const params = room ? `?room_id=${encodeURIComponent(room)}` : ''
  const data = await get<TrpgRawEventsResponse>(`/api/v1/trpg/events${params}`)
  return Array.isArray(data.events) ? data.events : []
}

export async function fetchTrpgState(room?: string): Promise<TrpgState> {
  const params = room ? `?room_id=${encodeURIComponent(room)}` : ''
  const [rawState, rawEvents] = await Promise.all([
    get<TrpgRawStateResponse>(`/api/v1/trpg/state${params}`),
    fetchTrpgEventsRaw(room),
  ])
  return normalizeTrpgState(rawState, rawEvents, room)
}

export async function fetchTrpgEvents(room?: string): Promise<{ events: TrpgEvent[] }> {
  const events = await fetchTrpgEventsRaw(room)
  const actorNameById: Record<string, string> = {}
  events.forEach(rawEvent => {
    if (!isRecord(rawEvent)) return
    const id = asString(rawEvent.actor_id, '').trim()
    const name = asString(rawEvent.actor_name, '').trim()
    if (id && name && actorNameById[id] !== name) {
      actorNameById[id] = name
    }
    if (isRecord(rawEvent.payload)) {
      const payload = rawEvent.payload
      const payloadId = asString(payload.actor_id, '').trim()
      const payloadName = asString(payload.actor_name, '').trim()
      if (payloadId && payloadName && actorNameById[payloadId] !== payloadName) {
        actorNameById[payloadId] = payloadName
      }
    }
  })
  return {
    events: events.map(event => normalizeRawEvent(event, actorNameById)),
  }
}

export interface TrpgRoundRunStatus {
  actor_id?: string
  role?: string
  keeper?: string
  status?: string
  reason?: string
  stage?: string
  action_type?: string
  reply?: string
  timeout_sec?: number
}

export interface TrpgRoundRunSummary {
  participants?: number
  successes?: number
  player_successes?: number
  player_required_successes?: number
  player_quorum_met?: boolean
  dm_success?: boolean
  advanced?: boolean
  progress_reason?: string
  progress_detail?: string | null
  recovery_applied?: boolean
  recovery_mode?: string
  effective_timeout_sec?: number
  keeper_timeout_sec?: number
  timeouts?: number
  unavailable?: number
  schema_failures?: number
  rule_validation_failures?: number
  reprompts?: number
  npc_spawned?: number
  npc_attacks?: number
  canon_status?: string
  canon_violation_count?: number
  canon_warning_count?: number
  memory_signals?: number
  memory_guardrail_escalations?: number
  roll_audit_count?: number
}

export interface TrpgRoundRunResult {
  ok?: boolean
  room_id?: string
  phase?: string
  turn_before?: number
  turn_after?: number
  timeout_sec?: number
  statuses?: TrpgRoundRunStatus[]
  summary?: TrpgRoundRunSummary
  canon_check?: {
    status?: string
    warnings?: string[]
    violations?: string[]
  }
}

export function runTrpgRound(room: string): Promise<TrpgRoundRunResult> {
  return post<TrpgRoundRunResult>('/api/v1/trpg/rounds/run', { room_id: room })
}

function normalizeTrpgPhase(phase?: string): string | undefined {
  const normalized = (phase ?? '').trim().toLowerCase()
  if (!normalized) return undefined

  switch (normalized) {
    case 'discussion':
    case 'discuss':
    case 'party_discussion':
    case 'player_discussion':
    case 'action':
    case 'dice':
      return 'round'
    case 'ended':
      return 'end'
    default:
      return normalized
  }
}

export interface TrpgDiceRollRequest {
  roomId: string
  actorId: string
  action: string
  statValue: number
  dc: number
  rawD20?: number
  ruleModule?: string
}

export function rollTrpgDice(req: TrpgDiceRollRequest): Promise<unknown> {
  const body: Record<string, unknown> = {
    room_id: req.roomId,
    actor_id: req.actorId,
    action: req.action,
    stat_value: req.statValue,
    dc: req.dc,
  }
  if (req.rawD20 != null) body.raw_d20 = req.rawD20
  if (req.ruleModule) body.rule_module = req.ruleModule
  return post('/api/v1/trpg/dice/roll', body)
}

export function advanceTrpgTurn(room: string, phase?: string): Promise<unknown> {
  const normalizedPhase = normalizeTrpgPhase(phase)
  return post('/api/v1/trpg/turns/advance', {
    room_id: room,
    ...(normalizedPhase ? { phase: normalizedPhase } : {}),
  })
}

export interface TrpgSpawnActorRequest {
  actor_id?: string
  name?: string
  role?: 'dm' | 'player' | 'npc'
  idempotencyKey?: string
  keeper_name?: string
  archetype?: string
  persona?: string
  portrait?: string
  background?: string
  hp?: number
  max_hp?: number
  alive?: boolean
  traits?: string[]
  skills?: string[]
  inventory?: string[]
  stats?: Record<string, number>
}

export interface TrpgSpawnActorResponse {
  ok: boolean
  actor_id: string
  state?: unknown
  [key: string]: unknown
}

export function spawnTrpgActor(
  room: string,
  actor: TrpgSpawnActorRequest,
): Promise<TrpgSpawnActorResponse> {
  const idempotencyKey = actor.idempotencyKey?.trim()
  const body: Record<string, unknown> = {
    room_id: room,
  }
  if (actor.actor_id && actor.actor_id.trim()) body.actor_id = actor.actor_id.trim()
  if (actor.name && actor.name.trim()) body.name = actor.name.trim()
  if (actor.role) body.role = actor.role
  if (actor.archetype && actor.archetype.trim()) body.archetype = actor.archetype.trim()
  if (actor.persona && actor.persona.trim()) body.persona = actor.persona.trim()
  if (actor.portrait && actor.portrait.trim()) body.portrait = actor.portrait.trim()
  if (actor.background && actor.background.trim()) body.background = actor.background.trim()
  if (actor.hp != null) body.hp = actor.hp
  if (actor.max_hp != null) body.max_hp = actor.max_hp
  if (actor.alive != null) body.alive = actor.alive
  if (Array.isArray(actor.traits) && actor.traits.length > 0) body.traits = actor.traits
  if (Array.isArray(actor.skills) && actor.skills.length > 0) body.skills = actor.skills
  if (Array.isArray(actor.inventory) && actor.inventory.length > 0) body.inventory = actor.inventory
  if (actor.stats && Object.keys(actor.stats).length > 0) body.stats = actor.stats
  if (idempotencyKey) body.idempotency_key = idempotencyKey
  return post('/api/v1/trpg/actors/spawn', body, idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : undefined)
}

export function claimTrpgActor(room: string, actorId: string, keeper: string): Promise<unknown> {
  return post('/api/v1/trpg/actors/claim', {
    room_id: room,
    actor_id: actorId,
    keeper,
  })
}

export function releaseTrpgActor(room: string, actorId: string, keeper: string): Promise<unknown> {
  return post('/api/v1/trpg/actors/release', {
    room_id: room,
    actor_id: actorId,
    keeper,
  })
}

export interface TrpgJoinEligibilityResponse {
  ok: boolean
  actor_id: string
  actor_role: string
  actor_exists: boolean
  phase_open: boolean
  window: string
  required_points: number
  server_score: number
  keeper_bonus: number
  effective_score: number
  eligible: boolean
  reason_code?: string | null
  reason?: string | null
  score_reasons?: string[]
  judge_source?: string
  judge_warning?: string | null
}

export async function fetchTrpgJoinEligibility(
  roomId: string,
  actorId: string,
  keeperName?: string,
): Promise<TrpgJoinEligibilityResponse> {
  const text = await callMcpTool('trpg.join.eligibility', {
    room_id: roomId,
    actor_id: actorId,
    ...(keeperName ? { keeper_name: keeperName } : {}),
  })
  return JSON.parse(text) as TrpgJoinEligibilityResponse
}

export interface TrpgMidJoinRequest {
  room_id: string
  actor_id: string
  keeper_name: string
  role?: 'player' | 'npc' | 'dm'
  name?: string
  archetype?: string
  persona?: string
}

export async function requestTrpgMidJoin(
  req: TrpgMidJoinRequest,
): Promise<Record<string, unknown>> {
  const text = await callMcpTool('trpg.mid_join.request', req as unknown as Record<string, unknown>)
  return JSON.parse(text) as Record<string, unknown>
}

// --- Lodge ---

export function fetchLodgeAgents(): Promise<{ agents: Agent[] }> {
  return get('/api/v1/lodge/agents')
}

export function createLodgeAgent(data: Partial<Agent>): Promise<Agent> {
  return post('/api/v1/lodge/agents', data)
}

// --- Karma ---

export function fetchKarma(): Promise<unknown> {
  return get('/api/v1/karma')
}

// --- Control Dock + Council (MCP tools) ---

export async function sendBroadcast(agentName: string, message: string): Promise<void> {
  await callMcpTool('masc_broadcast', {
    agent_name: agentName,
    message,
  })
}

export async function addTaskFromDashboard(
  title: string,
  description: string,
  priority = 1,
): Promise<void> {
  await callMcpTool('masc_add_task', {
    title,
    description,
    priority,
  })
}

export async function joinDashboardAgent(agentName: string): Promise<string> {
  return callMcpTool('masc_join', {
    agent_name: agentName,
  })
}

export async function leaveDashboardAgent(agentName: string): Promise<void> {
  await callMcpTool('masc_leave', {
    agent_name: agentName,
  })
}

export async function sendAgentHeartbeat(agentName: string): Promise<void> {
  await callMcpTool('masc_heartbeat', {
    agent_name: agentName,
  })
}

export async function fetchRoomMessages(limit = 40): Promise<string[]> {
  const text = await callMcpTool('masc_messages', { limit })
  return text
    .split('\n')
    .map(line => line.trim())
    .filter(line => line !== '')
}

export async function fetchTaskHistory(taskId: string, limit = 20): Promise<string> {
  return callMcpTool('masc_task_history', {
    task_id: taskId,
    limit,
  })
}

export async function fetchDebates(): Promise<CouncilDebate[]> {
  return withRetries('fetchDebates', async () => {
    const raw = await get<{ debates?: unknown[] }>('/api/v1/council/debates?limit=100')
    if (!Array.isArray(raw.debates)) return []
    return raw.debates
      .map((item): CouncilDebate | null => {
        if (!isRecord(item)) return null
        const id = asString(item.id, '').trim()
        const topic = asString(item.topic, '').trim()
        if (!id || !topic) return null
        return {
          id,
          topic,
          status: asString(item.status, 'open'),
          argument_count: asNumber(item.argument_count, 0),
          created_at: toIsoTimestamp(item.created_at_iso ?? item.created_at),
        }
      })
      .filter((row): row is CouncilDebate => row !== null)
  })
}

export async function fetchCouncilSessions(): Promise<CouncilSession[]> {
  return withRetries('fetchCouncilSessions', async () => {
    const raw = await get<{ sessions?: unknown[] }>('/api/v1/council/sessions?limit=100')
    if (!Array.isArray(raw.sessions)) return []
    return raw.sessions
      .map((item): CouncilSession | null => {
        if (!isRecord(item)) return null
        const id = asString(item.id, '').trim()
        const topic = asString(item.topic, '').trim()
        if (!id || !topic) return null
        return {
          id,
          topic,
          initiator: asString(item.initiator, 'system'),
          votes: asNumber(item.votes, 0),
          quorum: asNumber(item.quorum, 0),
          state: asString(item.state, 'open'),
          created_at: toIsoTimestamp(item.created_at_iso ?? item.created_at),
        }
      })
      .filter((row): row is CouncilSession => row !== null)
  })
}

export async function startDebate(topic: string): Promise<CouncilDebate | null> {
  const text = await callMcpTool('masc_debate_start', { topic })
  try {
    return JSON.parse(text) as CouncilDebate
  } catch {
    return null
  }
}

export async function fetchDebateStatus(debateId: string): Promise<CouncilDebateSummary | null> {
  return withRetries('fetchDebateStatus', async () => {
    const safeId = encodeURIComponent(debateId)
    const raw = await get<Record<string, unknown>>(`/api/v1/council/debates/${safeId}/summary`)
    if (!isRecord(raw)) return null
    const id = asString(raw.id, '').trim()
    if (!id) return null
    return {
      id,
      topic: asString(raw.topic, ''),
      status: asString(raw.status, 'open'),
      support_count: asNumber(raw.support_count, 0),
      oppose_count: asNumber(raw.oppose_count, 0),
      neutral_count: asNumber(raw.neutral_count, 0),
      total_arguments: asNumber(raw.total_arguments, 0),
      created_at: toIsoTimestamp(raw.created_at_iso ?? raw.created_at),
      summary_text: asString(raw.summary_text, ''),
    }
  })
}

export function sendKeeperMessage(name: string, message: string, models?: string[]): Promise<string> {
  const args: Record<string, unknown> = { name, message }
  if (models && models.length > 0) args.models = models
  return callMcpTool("masc_keeper_msg", args)
}

function normalizeMdalStatus(raw: unknown): MdalLoop['status'] {
  const text = asString(raw, '').trim().toLowerCase()
  if (text.startsWith('error')) return 'error'
  if (text === 'running' || text === 'interrupted' || text === 'completed' || text === 'stopped') return text
  return 'running'
}

function normalizeMdalIteration(raw: unknown): MdalIterationRecord | null {
  if (!isRecord(raw)) return null
  const evidenceRaw = isRecord(raw.evidence) ? raw.evidence : null
  return {
    iteration: asInt(raw.iteration) ?? 0,
    metric_before: asNumber(raw.metric_before, 0),
    metric_after: asNumber(raw.metric_after, 0),
    delta: asNumber(raw.delta, 0),
    changes: asString(raw.changes, ''),
    failed_attempts: asString(raw.failed_attempts, ''),
    next_suggestion: asString(raw.next_suggestion, ''),
    elapsed_ms: asInt(raw.elapsed_ms) ?? 0,
    cost_usd: typeof raw.cost_usd === 'number' && Number.isFinite(raw.cost_usd) ? raw.cost_usd : null,
    evidence: evidenceRaw
      ? {
          worker_engine: evidenceRaw.worker_engine === 'api_tool_loop' ? 'api_tool_loop' : 'api_tool_loop',
          worker_model: asString(evidenceRaw.worker_model, ''),
          tool_call_count: asInt(evidenceRaw.tool_call_count) ?? 0,
          tool_names: Array.isArray(evidenceRaw.tool_names)
            ? evidenceRaw.tool_names.filter((item): item is string => typeof item === 'string')
            : [],
          session_id: asString(evidenceRaw.session_id, ''),
          evidence_status:
            evidenceRaw.evidence_status === 'legacy_unverified'
              ? 'legacy_unverified'
              : 'verified',
        }
      : null,
  }
}

function normalizeMdalLoop(raw: unknown): MdalLoop | null {
  if (!isRecord(raw)) return null
  const loopId = asString(raw.loop_id, '').trim()
  if (!loopId) return null
  const history = Array.isArray(raw.history)
    ? raw.history
      .map(normalizeMdalIteration)
      .filter((row): row is MdalIterationRecord => row !== null)
    : []

  return {
    loop_id: loopId,
    profile: asString(raw.profile, 'custom'),
    status: normalizeMdalStatus(raw.status),
    strict_mode: typeof raw.strict_mode === 'boolean' ? raw.strict_mode : undefined,
    error_message: asString(raw.error_message) ?? asString(raw.error_reason) ?? null,
    stop_reason: asString(raw.stop_reason) ?? asString(raw.reason) ?? null,
    current_iteration: asInt(raw.iteration) ?? asInt(raw.current_iteration) ?? 0,
    max_iterations: asInt(raw.max_iterations) ?? 0,
    baseline_metric: asNumber(raw.baseline_metric, 0),
    current_metric: asNumber(raw.current_metric, asNumber(raw.baseline_metric, 0)),
    target: asString(raw.target, ''),
    stagnation_streak: asInt(raw.stagnation_streak) ?? 0,
    stagnation_limit: asInt(raw.stagnation_limit) ?? 0,
    elapsed_seconds: asNumber(raw.elapsed_seconds, 0),
    updated_at: raw.updated_at !== undefined ? toIsoTimestamp(raw.updated_at) : null,
    stopped_at: raw.stopped_at == null ? null : toIsoTimestamp(raw.stopped_at),
    execution_mode: raw.execution_mode === 'worker_spawn' ? 'worker_spawn' : undefined,
    worker_engine: raw.worker_engine === 'api_tool_loop' ? 'api_tool_loop' : null,
    worker_model: asString(raw.worker_model) ?? null,
    evidence_policy:
      raw.evidence_policy === 'legacy' || raw.evidence_policy === 'hard'
        ? raw.evidence_policy
        : undefined,
    latest_tool_call_count: asInt(raw.latest_tool_call_count) ?? 0,
    latest_tool_names: Array.isArray(raw.latest_tool_names)
      ? raw.latest_tool_names.filter((item): item is string => typeof item === 'string')
      : [],
    session_id: asString(raw.session_id) ?? null,
    evidence_status:
      raw.evidence_status === 'legacy_unverified'
        ? 'legacy_unverified'
        : raw.evidence_status === 'verified'
          ? 'verified'
          : null,
    durability:
      raw.durability === 'persistent_backend' || raw.durability === 'memory_only'
        ? raw.durability
        : undefined,
    persistence_backend:
      raw.persistence_backend === 'filesystem'
      || raw.persistence_backend === 'postgres'
      || raw.persistence_backend === 'memory'
        ? raw.persistence_backend
        : undefined,
    recoverable: typeof raw.recoverable === 'boolean' ? raw.recoverable : undefined,
    history,
  }
}

export type LatestMdalLoopResult =
  | { state: 'ready'; loop: MdalLoop }
  | { state: 'idle' }
  | { state: 'error'; message: string }

function isMdalIdleMessage(message: string): boolean {
  return message.trim().toLowerCase().includes('no mdal loop running')
}

export async function fetchLatestMdalLoop(): Promise<LatestMdalLoopResult> {
  try {
    const rawText = await callMcpTool('masc_mdal_status', {})
    const parsed = JSON.parse(rawText) as unknown
    const errorMessage = isRecord(parsed) ? asString(parsed.error, '').trim() : ''
    if (isMdalIdleMessage(errorMessage)) return { state: 'idle' }
    if (errorMessage) return { state: 'error', message: errorMessage }
    const loop = normalizeMdalLoop(parsed)
    return loop ? { state: 'ready', loop } : { state: 'error', message: 'Unexpected MDAL payload' }
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown MDAL fetch error'
    if (isMdalIdleMessage(message)) return { state: 'idle' }
    return { state: 'error', message }
  }
}

// --- Goal Store ---

export async function fetchGoals(): Promise<import('./types').Goal[]> {
  try {
    const res = await callMcpTool('masc_goal_list', {})
    if (typeof res === 'string') {
      const parsed = JSON.parse(res)
      return Array.isArray(parsed) ? parsed : parsed.goals ?? []
    }
    if (Array.isArray(res)) return res
    return (res as Record<string, unknown>).goals as import('./types').Goal[] ?? []
  } catch {
    return []
  }
}

export async function fetchKeeperAutonomy(name: string): Promise<import('./types').KeeperAutonomyInfo | null> {
  try {
    const res = await callMcpTool('masc_keeper_status', { name })
    if (typeof res === 'string') {
      const parsed = JSON.parse(res)
      return parsed.autonomy ?? null
    }
    return (res as Record<string, unknown>).autonomy as import('./types').KeeperAutonomyInfo ?? null
  } catch {
    return null
  }
}
