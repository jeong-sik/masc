import { get, post } from './core'
import { callMcpTool } from './mcp'
import { isRecord } from '../components/common/normalize'
import type { TrpgState, TrpgEvent } from '../types'

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

// Local helpers below return fallback values (not undefined) — intentionally
// separate from common/normalize.ts which returns T | undefined.
export function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

export function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

export function asInt(value: unknown): number | undefined {
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

export function asStringList(value: unknown): string[] {
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

export function asStringMap(value: unknown): Record<string, string> {
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

