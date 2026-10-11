import { KeeperChatStreamEventSchema } from '../schemas/sse'
import type { KeeperChatStreamEvent } from '../lib/keeper-chat-stream-contract'
import { isRecord } from '../lib/type-guards'
import { apiRequestErrorFromResponse, fetchControlPlane } from './core'

export type KeeperTurnCursor = Readonly<{ sequence: number | null; offset: number }>
export type KeeperTurnEventPage = Readonly<{
  turnRef: string
  events: readonly Readonly<{ sequence: number; timestamp: number; event: KeeperChatStreamEvent | null }>[]
  hasMore: boolean
  cursor: KeeperTurnCursor
}>

const nonnegativeInteger = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0

export function parseKeeperTurnEventPage(raw: unknown, turnRef: string, cursor: KeeperTurnCursor): KeeperTurnEventPage {
  if (!isRecord(raw) || raw.schema !== 'masc.keeper_turn_events.v1' || raw.turn_ref !== turnRef
    || !Array.isArray(raw.ag_ui_events) || typeof raw.has_more !== 'boolean'
    || !nonnegativeInteger(raw.next_since_offset) || raw.next_since_offset < cursor.offset) {
    throw new Error('Invalid autonomous turn journal page')
  }
  let sequence = cursor.sequence
  const events = raw.ag_ui_events.map((row: unknown) => {
    if (!isRecord(row) || !nonnegativeInteger(row.seq) || (sequence !== null && row.seq <= sequence)
      || typeof row.ts !== 'number' || !Number.isFinite(row.ts) || row.ts < 0) {
      throw new Error('Invalid autonomous turn journal event cursor')
    }
    sequence = row.seq
    const parsed = row.event === null ? null : KeeperChatStreamEventSchema.safeParse(row.event)
    if (parsed && !parsed.success) throw new Error('Invalid autonomous turn journal event')
    if (isRecord(row.event) && row.event.runId !== undefined && row.event.runId !== turnRef) {
      throw new Error('Autonomous journal event belongs to a different run')
    }
    return Object.freeze({ sequence: row.seq, timestamp: row.ts, event: parsed?.success ? parsed.data : null })
  })
  if (raw.next_since_seq !== sequence || (raw.has_more && events.length === 0)
    || (events.length > 0 && raw.next_since_offset <= cursor.offset)
    || (events.length === 0 && raw.next_since_offset !== cursor.offset)) {
    throw new Error('Invalid autonomous turn journal continuation')
  }
  return Object.freeze({ turnRef, events: Object.freeze(events), hasMore: raw.has_more,
    cursor: Object.freeze({ sequence, offset: raw.next_since_offset }) })
}

export async function fetchKeeperTurnEvents(keeperName: string, turnRef: string,
  cursor: KeeperTurnCursor = { sequence: null, offset: 0 }, signal?: AbortSignal): Promise<KeeperTurnEventPage> {
  if (!keeperName.trim() || !turnRef.trim() || !nonnegativeInteger(cursor.offset)
    || cursor.sequence !== null && !nonnegativeInteger(cursor.sequence)
    || cursor.sequence === null && cursor.offset !== 0) throw new Error('Invalid autonomous turn journal request')
  const query = new URLSearchParams()
  if (cursor.sequence !== null) {
    query.set('since_seq', String(cursor.sequence))
    query.set('since_offset', String(cursor.offset))
  }
  const path = `/api/v1/keepers/${encodeURIComponent(keeperName)}/turns/${encodeURIComponent(turnRef)}/events${query.size ? `?${query}` : ''}`
  const response = await fetchControlPlane(path, { method: 'GET', signal })
  if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
  return parseKeeperTurnEventPage(await response.json(), turnRef, cursor)
}

export type KeeperCurrentTurn = Readonly<{ state: 'idle' } | { state: 'observed'; turnRef: string; sequence: number }>
export async function fetchKeeperCurrentTurn(keeperName: string, signal?: AbortSignal): Promise<KeeperCurrentTurn> {
  if (!keeperName.trim()) throw new Error('Invalid Keeper discovery request')
  const path = `/api/v1/keepers/${encodeURIComponent(keeperName)}/turns/current`
  const response = await fetchControlPlane(path, { method: 'GET', signal })
  if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
  const raw: unknown = await response.json()
  if (!isRecord(raw) || raw.schema !== 'masc.keeper_current_turn.v1') throw new Error('Invalid current turn discovery')
  if (raw.current === null) return Object.freeze({ state: 'idle' })
  if (!isRecord(raw.current) || typeof raw.current.turn_ref !== 'string' || !raw.current.turn_ref.trim()
    || !nonnegativeInteger(raw.current.seq)) throw new Error('Invalid current turn discovery cursor')
  return Object.freeze({ state: 'observed', turnRef: raw.current.turn_ref, sequence: raw.current.seq })
}
