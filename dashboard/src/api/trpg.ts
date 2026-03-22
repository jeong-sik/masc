import { get } from './core'
import { isRecord } from '../components/common/normalize'
import type {
  TrpgActor,
  TrpgCharacterStats,
  TrpgContributionEntry,
  TrpgEvent,
  TrpgJoinGate,
  TrpgOutcome,
  TrpgRound,
  TrpgSession,
  TrpgState,
} from '../types'

interface TrpgRawStateResponse {
  room_id?: string
  state?: unknown
}

interface TrpgRawEventsResponse {
  events?: unknown
}

export function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

export function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

export function asInt(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value !== 'string') return undefined
  const parsed = Number.parseInt(value.trim(), 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

export function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => {
      if (typeof item === 'string') return item.trim()
      if (isRecord(item)) {
        return asString(item.name, '').trim()
          || asString(item.id, '').trim()
          || asString(item.skill, '').trim()
      }
      return ''
    })
    .filter((item): item is string => item.length > 0)
}

function normalizeRole(value: unknown, actorId: string): 'dm' | 'player' | 'npc' {
  if (value === 'dm' || value === 'player' || value === 'npc') return value
  const lowered = actorId.trim().toLowerCase()
  if (lowered === 'dm' || lowered.startsWith('dm-')) return 'dm'
  if (lowered.startsWith('p') || lowered.startsWith('player-')) return 'player'
  return 'npc'
}

function normalizeStats(raw: Record<string, unknown>): TrpgCharacterStats {
  return {
    hp: asNumber(raw.hp, 0),
    max_hp: asNumber(raw.max_hp, 0),
    mp: asNumber(raw.mp, 0),
    max_mp: asNumber(raw.max_mp, 0),
    level: asNumber(raw.level, 1),
    xp: asNumber(raw.xp, 0),
    strength: asNumber(raw.strength ?? raw.str, 0),
    dexterity: asNumber(raw.dexterity ?? raw.dex, 0),
    constitution: asNumber(raw.constitution ?? raw.con, 0),
    intelligence: asNumber(raw.intelligence ?? raw.int, 0),
    wisdom: asNumber(raw.wisdom ?? raw.wis, 0),
    charisma: asNumber(raw.charisma ?? raw.cha, 0),
  }
}

function normalizeActor(actorId: string, value: unknown, keeper: unknown): TrpgActor {
  const actor = isRecord(value) ? value : {}
  return {
    id: actorId,
    name: asString(actor.name, actorId),
    role: normalizeRole(actor.role, actorId),
    keeper: typeof keeper === 'string' && keeper.trim() ? keeper : undefined,
    archetype: asString(actor.archetype, '') || undefined,
    persona: asString(actor.persona, '') || undefined,
    portrait: asString(actor.portrait, '') || undefined,
    background: asString(actor.background, '') || undefined,
    traits: asStringList(actor.traits),
    skills: asStringList(actor.skills),
    stats: normalizeStats(actor),
    status: asBoolean(actor.alive, true) ? 'active' : 'down',
  }
}

function eventContent(type: string, payload: Record<string, unknown>): string {
  return (
    asString(payload.summary, '')
    || asString(payload.reply, '')
    || asString(payload.content, '')
    || asString(payload.text, '')
    || type
  )
}

function normalizeEvent(value: unknown, actorNames: Map<string, string>): TrpgEvent {
  const raw = isRecord(value) ? value : {}
  const payload = isRecord(raw.payload) ? raw.payload : {}
  const actorId = asString(raw.actor_id, '').trim() || asString(payload.actor_id, '').trim()
  const actorName =
    asString(raw.actor_name, '').trim()
    || asString(payload.actor_name, '').trim()
    || actorNames.get(actorId)
    || ''
  const type = asString(raw.type, 'event')
  return {
    type,
    actor: actorName || actorId || undefined,
    actor_id: actorId || undefined,
    actor_name: actorName || undefined,
    seq: asInt(raw.seq),
    room_id: asString(raw.room_id, '') || undefined,
    phase: asString(raw.phase, '') || asString(payload.phase, '') || undefined,
    category: asString(raw.category, '') || undefined,
    visibility: asString(raw.visibility, '') || asString(payload.visibility, '') || undefined,
    event_id: asString(raw.event_id, '') || undefined,
    content: eventContent(type, payload),
    timestamp: asString(raw.ts, '') || asString(raw.timestamp, '') || undefined,
  }
}

function normalizeOutcome(raw: unknown): TrpgOutcome | undefined {
  const outcome = isRecord(raw) ? raw : {}
  const result = asString(outcome.result ?? outcome.outcome, '').trim().toLowerCase()
  if (result !== 'victory' && result !== 'defeat' && result !== 'draw') return undefined
  return {
    result,
    reason: asString(outcome.reason, '') || undefined,
    summary: asString(outcome.summary, '') || undefined,
    turn: asInt(outcome.turn),
    phase: asString(outcome.phase, '') || undefined,
  }
}

function normalizeJoinGate(raw: unknown): TrpgJoinGate | undefined {
  const gate = isRecord(raw) ? raw : {}
  if (Object.keys(gate).length === 0) return undefined
  return {
    phase_open: asBoolean(gate.phase_open, false),
    min_points: asNumber(gate.min_points, 0),
    window: asString(gate.window, ''),
    last_opened_turn: asInt(gate.last_opened_turn) ?? null,
    last_closed_turn: asInt(gate.last_closed_turn) ?? null,
  }
}

function normalizeContributionLedger(raw: unknown): TrpgContributionEntry[] {
  if (!isRecord(raw)) return []
  return Object.entries(raw).map(([actorId, value]) => {
    const entry = isRecord(value) ? value : {}
    return {
      actor_id: actorId,
      score: asNumber(entry.score, 0),
      last_reason: asString(entry.last_reason, '') || null,
      reasons: asStringList(entry.reasons),
    }
  })
}

function normalizeTrpgState(
  rawStateResponse: TrpgRawStateResponse,
  rawEvents: unknown[],
  requestedRoom?: string,
): TrpgState {
  const roomId = asString(rawStateResponse.room_id, '') || requestedRoom || 'default'
  const state = isRecord(rawStateResponse.state) ? rawStateResponse.state : {}
  const partyJson = isRecord(state.party) ? state.party : {}
  const actorControl = isRecord(state.actor_control) ? state.actor_control : {}
  const party = Object.entries(partyJson).map(([actorId, actorValue]) =>
    normalizeActor(actorId, actorValue, actorControl[actorId]))
  const actorNames = new Map<string, string>(party.map(actor => [actor.id, actor.name]))
  const storyLog = rawEvents.map(event => normalizeEvent(event, actorNames))

  const currentRound: TrpgRound | undefined = (() => {
    const round = isRecord(state.current_round) ? state.current_round : {}
    if (Object.keys(round).length === 0 && storyLog.length === 0) return undefined
    return {
      round_number: asInt(round.round_number ?? round.round) ?? 0,
      phase: asString(round.phase, '') || asString(state.phase, '') || 'round',
      events: storyLog,
      timestamp:
        asString(round.timestamp, '')
        || storyLog[storyLog.length - 1]?.timestamp
        || new Date().toISOString(),
    }
  })()

  const session: TrpgSession | undefined = {
    id: asString(state.session_id, '') || roomId,
    room: roomId,
    status: ((): TrpgSession['status'] => {
      const status = asString(state.status, 'active')
      return status === 'paused' || status === 'ended' ? status : 'active'
    })(),
    round: currentRound?.round_number ?? 0,
    actors: party,
    created_at: asString(state.created_at, '') || new Date().toISOString(),
  }

  return {
    session,
    current_round: currentRound,
    map: asString(state.map, '') || undefined,
    join_gate: normalizeJoinGate(state.join_gate),
    contribution_ledger: normalizeContributionLedger(state.contribution_ledger),
    outcome: normalizeOutcome(state.session_outcome),
    party,
    story_log: storyLog,
    history: [],
  }
}

function is404(err: unknown): boolean {
  return err instanceof Error && 'status' in err && (err as { status: number }).status === 404
}

async function fetchTrpgEventsRaw(room?: string): Promise<unknown[]> {
  const params = room ? `?room_id=${encodeURIComponent(room)}` : ''
  try {
    const data = await get<TrpgRawEventsResponse>(`/api/v1/trpg/events${params}`)
    return Array.isArray(data.events) ? data.events : []
  } catch (err) {
    if (is404(err)) return []
    throw err
  }
}

export async function fetchTrpgState(room?: string): Promise<TrpgState> {
  const params = room ? `?room_id=${encodeURIComponent(room)}` : ''
  const [rawState, rawEvents] = await Promise.all([
    get<TrpgRawStateResponse>(`/api/v1/trpg/state${params}`).catch(err => {
      if (is404(err)) return { room_id: room } as TrpgRawStateResponse
      throw err
    }),
    fetchTrpgEventsRaw(room),
  ])
  return normalizeTrpgState(rawState, rawEvents, room)
}
