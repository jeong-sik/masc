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
