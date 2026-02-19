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

// --- Generic fetcher ---

async function get<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: authHeaders() })
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${res.statusText}`)
  return res.json() as Promise<T>
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(path, {
    method: 'POST',
    headers: jsonHeaders(),
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error(`POST ${path}: ${res.status} ${res.statusText}`)
  return res.json() as Promise<T>
}

async function postRaw(path: string, body: unknown, extraHeaders?: Record<string, string>): Promise<string> {
  const res = await fetch(path, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(body),
  })
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
  })
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

export function fetchDashboard(): Promise<DashboardData> {
  return get('/api/v1/dashboard')
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
  return post(`/api/v1/board/${postId}/vote`, { direction })
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

export function fetchTrpgState(room?: string): Promise<TrpgState> {
  const params = room ? `?room=${encodeURIComponent(room)}` : ''
  return get(`/api/v1/trpg/state${params}`)
}

export function fetchTrpgEvents(room?: string): Promise<{ events: TrpgEvent[] }> {
  const params = room ? `?room=${encodeURIComponent(room)}` : ''
  return get(`/api/v1/trpg/events${params}`)
}

export function runTrpgRound(room: string): Promise<unknown> {
  return post('/api/v1/trpg/rounds/run', { room })
}

export function rollTrpgDice(room: string, notation: string): Promise<unknown> {
  return post('/api/v1/trpg/dice/roll', { room, notation })
}

export function advanceTrpgTurn(room: string): Promise<unknown> {
  return post('/api/v1/trpg/turns/advance', { room })
}

export function spawnTrpgActor(room: string, actor: Partial<import('./types').TrpgActor>): Promise<unknown> {
  return post('/api/v1/trpg/actors/spawn', { room, ...actor })
}

export function claimTrpgActor(room: string, actorId: string, keeper: string): Promise<unknown> {
  return post('/api/v1/trpg/actors/claim', { room, actor_id: actorId, keeper })
}

export function releaseTrpgActor(room: string, actorId: string): Promise<unknown> {
  return post('/api/v1/trpg/actors/release', { room, actor_id: actorId })
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
