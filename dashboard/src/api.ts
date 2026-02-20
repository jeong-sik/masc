// MASC Dashboard — Typed API client
// All fetch calls go through this module for consistent auth and typing

import type {
  DashboardData,
  BoardPost,
  BoardComment,
  BoardHearth,
  BoardFlair,
  TrpgState,
  TrpgEvent,
  Agent,
  CouncilDebate,
  CouncilSession,
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
      throw new Error(`${method} ${path}: timeout after ${timeoutMs}ms`)
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
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${res.statusText}`)
  return res.json() as Promise<T>
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetchWithTimeout(path, {
    method: 'POST',
    headers: jsonHeaders(),
    body: JSON.stringify(body),
  }, DEFAULT_POST_TIMEOUT_MS)
  if (!res.ok) throw new Error(`POST ${path}: ${res.status} ${res.statusText}`)
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
  if (!res.ok) throw new Error(`POST ${path}: ${res.status} ${res.statusText}`)
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

async function callMcpTool(toolName: string, args: Record<string, unknown>): Promise<string> {
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

function parseJsonList<T>(text: string): T[] {
  const trimmed = text.trim()
  if (!trimmed) return []
  const parsed = JSON.parse(trimmed) as unknown
  return Array.isArray(parsed) ? (parsed as T[]) : []
}

// --- Dashboard (batch) ---

export type DashboardMode = 'compact' | 'full'

export function fetchDashboard(mode: DashboardMode = 'compact'): Promise<DashboardData> {
  return get(`/api/v1/dashboard?mode=${mode}`)
}

// --- Board ---

export function fetchBoard(): Promise<{ posts: BoardPost[] }> {
  return get('/api/v1/board')
}

export function fetchBoardPost(postId: string): Promise<BoardPost & { comments: BoardComment[] }> {
  return get(`/api/v1/board/${postId}`)
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
    vote: direction,
    voter: defaultBoardVoter(),
  })
}

export function voteBoardTool(postId: string, vote: 'up' | 'down', voter: string): Promise<unknown> {
  return post('/api/v1/tools/masc_board_vote', {
    post_id: postId,
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
  ts?: string
  payload?: unknown
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

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function normalizeRole(value: unknown): 'dm' | 'player' | 'npc' {
  return value === 'dm' || value === 'player' || value === 'npc' ? value : 'npc'
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

function eventContent(type: string, actorId: string, payload: Record<string, unknown>): string {
  const actorLabel = actorId || asString(payload.actor_id, '')
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
      return `Actor spawned: ${asString(payload.name, actorLabel || 'unknown')}`
    case 'actor.claimed':
      return `${asString(payload.keeper, 'keeper')} claimed ${actorLabel || 'actor'}`
    case 'actor.released':
      return `${asString(payload.keeper, 'keeper')} released ${actorLabel || 'actor'}`
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

function normalizeRawEvent(value: unknown): TrpgEvent {
  const raw = isRecord(value) ? (value as TrpgRawEvent) : {}
  const type = asString(raw.type, 'event')
  const actorId = typeof raw.actor_id === 'string' ? raw.actor_id : ''
  const payload = isRecord(raw.payload) ? raw.payload : {}
  return {
    type,
    actor: actorId || asString(payload.actor_id, ''),
    content: eventContent(type, actorId, payload),
    dice_roll: normalizeDiceRoll(type, payload),
    timestamp: asString(raw.ts, new Date().toISOString()),
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

  const party = Object.entries(partyJson).map(([actorId, actorValue]) => {
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

    return {
      id: actorId,
      name: asString(actor.name, actorId),
      role: normalizeRole(actor.role),
      keeper,
      status: alive ? 'active' : 'dead',
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

  const storyLog = rawEvents.map(normalizeRawEvent)
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
  return { events: events.map(normalizeRawEvent) }
}

export function runTrpgRound(room: string): Promise<unknown> {
  return post('/api/v1/trpg/rounds/run', { room_id: room })
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

export function spawnTrpgActor(room: string, actor: Partial<import('./types').TrpgActor>): Promise<unknown> {
  return post('/api/v1/trpg/actors/spawn', {
    room_id: room,
    actor_id: actor.id,
    name: actor.name,
    role: actor.role,
    ...(actor.stats
      ? {
          hp: actor.stats.hp,
          max_hp: actor.stats.max_hp,
        }
      : {}),
  })
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
  const text = await callMcpTool('masc_debates', {})
  return parseJsonList<CouncilDebate>(text)
}

export async function fetchCouncilSessions(): Promise<CouncilSession[]> {
  const text = await callMcpTool('masc_sessions', {})
  return parseJsonList<CouncilSession>(text)
}

export async function startDebate(topic: string): Promise<CouncilDebate | null> {
  const text = await callMcpTool('masc_debate_start', { topic })
  try {
    return JSON.parse(text) as CouncilDebate
  } catch {
    return null
  }
}

export function fetchDebateStatus(debateId: string): Promise<string> {
  return callMcpTool('masc_debate_status', { debate_id: debateId })
}
