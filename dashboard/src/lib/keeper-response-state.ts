export interface KeeperResponseOwner {
  readonly content_generation: number
  readonly stream_scope: number
}

export interface ObservedKeeperResponseState {
  readonly kind: 'known'
  readonly lastSequence: number | null
  readonly floor: KeeperResponseOwner | null
  readonly current: KeeperResponseOwner | null
  readonly partialScope: number | null
  readonly closed: KeeperResponseOwner | null
  readonly phase: 'running' | 'awaiting-continuation' | 'terminal'
  readonly closedGeneration: number | null
}

export type KeeperResponseState = ObservedKeeperResponseState | { readonly kind: 'unavailable' }
export const unavailableKeeperResponseState: KeeperResponseState = Object.freeze({ kind: 'unavailable' })

export type KeeperResponseEvent =
  | { readonly kind: 'observe'; readonly owner: KeeperResponseOwner | null; readonly scope: number | null; readonly source: 'header' | 'details' | 'body' | 'content' }
  | { readonly kind: 'stop'; readonly owner: KeeperResponseOwner | null }
  | { readonly kind: 'attempt' | 'started' | 'checkpoint' | 'terminal' }

export interface KeeperResponseDecision {
  readonly state: KeeperResponseState
  readonly accepted: boolean
  readonly advanced: boolean
  readonly authoritative: boolean
}

export const initialKeeperResponseState: ObservedKeeperResponseState = Object.freeze({
  kind: 'known', lastSequence: null, floor: null, current: null, partialScope: null, closed: null, phase: 'running', closedGeneration: null,
})

function compareOwner(left: KeeperResponseOwner, right: KeeperResponseOwner): number {
  return left.content_generation - right.content_generation || left.stream_scope - right.stream_scope
}

/** The operation journal sequence is shared by direct SSE and broadcast frames. */
export function acknowledgeKeeperResponseSequence(state: KeeperResponseState, sequence: number | undefined): KeeperResponseState | null {
  if (state.kind === 'unavailable') return null
  if (sequence === undefined) return state
  if (!Number.isSafeInteger(sequence) || sequence < 0 || (state.lastSequence !== null && sequence <= state.lastSequence)) return null
  return Object.freeze({ ...state, lastSequence: sequence })
}

export function reduceKeeperResponse(state: KeeperResponseState, event: KeeperResponseEvent): KeeperResponseDecision {
  const refuse = (): KeeperResponseDecision => ({ state, accepted: false, advanced: false, authoritative: false })
  if (state.kind === 'unavailable') return refuse()
  if ((event.kind === 'observe' || event.kind === 'stop') && event.owner && !ownerFromUnknown(event.owner)) return refuse()
  if (event.kind === 'observe' && event.scope !== null && (!Number.isSafeInteger(event.scope) || event.scope < 0)) return refuse()
  if (event.kind === 'started') {
    if (state.phase === 'terminal' || (state.phase === 'running' && state.floor !== null)) return refuse()
    return { state: Object.freeze({ ...state, phase: 'running', current: null, partialScope: null }), accepted: true, advanced: false, authoritative: false }
  }
  if (event.kind === 'terminal' || event.kind === 'checkpoint') {
    if (state.phase === 'terminal') return refuse()
    return { state: Object.freeze({ ...state, phase: event.kind === 'terminal' ? 'terminal' : 'awaiting-continuation',
      current: event.kind === 'checkpoint' ? null : state.current,
      partialScope: null, closedGeneration: state.floor?.content_generation ?? state.closedGeneration }), accepted: true, advanced: false, authoritative: false }
  }
  if (state.phase !== 'running') return refuse()
  if (event.kind === 'attempt') {
    return { state: Object.freeze({ ...state, current: null, partialScope: null }), accepted: true, advanced: false, authoritative: false }
  }
  if (event.kind === 'stop') {
    if (!event.owner) {
      return state.floor ? refuse() : { state, accepted: true, advanced: false, authoritative: true }
    }
    if (!state.current || compareOwner(event.owner, state.current) !== 0
      || (state.closed && compareOwner(event.owner, state.closed) <= 0)) return refuse()
    return { state: Object.freeze({ ...state, closed: state.current }), accepted: true, advanced: false, authoritative: true }
  }
  if (!event.owner) {
    if (state.floor && event.source !== 'body') return refuse()
    const partial = event.scope !== null
    return {
      state: partial ? Object.freeze({ ...state, current: null, partialScope: event.scope }) : state,
      accepted: true, advanced: partial && (state.current !== null || state.partialScope !== event.scope),
      authoritative: state.floor === null,
    }
  }
  const incoming = Object.freeze({ content_generation: event.owner.content_generation, stream_scope: event.owner.stream_scope })
  if (state.closedGeneration !== null && incoming.content_generation <= state.closedGeneration) return refuse()
  if (state.floor && compareOwner(incoming, state.floor) < 0) return refuse()
  if (state.floor && incoming.content_generation === state.floor.content_generation
    && state.partialScope !== null && incoming.stream_scope < state.partialScope) return refuse()
  const sameCurrent = state.current !== null && compareOwner(incoming, state.current) === 0
  if (state.closed && compareOwner(incoming, state.closed) <= 0
    && !(event.source === 'details' && sameCurrent)) return refuse()
  return {
    state: sameCurrent ? state : Object.freeze({ ...state, floor: incoming, current: incoming, partialScope: null }),
    accepted: true, advanced: !sameCurrent, authoritative: true,
  }
}

export function ownerFromUnknown(raw: unknown): KeeperResponseOwner | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const value = raw as Record<string, unknown>
  if (Object.keys(value).length !== 2 || Object.keys(value).some(key => !['content_generation', 'stream_scope'].includes(key))) return null
  if (typeof value.content_generation !== 'number' || !Number.isSafeInteger(value.content_generation) || value.content_generation < 0
    || typeof value.stream_scope !== 'number' || !Number.isSafeInteger(value.stream_scope) || value.stream_scope < 0) return null
  return Object.freeze({ content_generation: value.content_generation, stream_scope: value.stream_scope })
}

/** Stored authority rejects malformed state instead of weakening a supplied owner. */
export function keeperResponseStateFromUnknown(raw: unknown): KeeperResponseState | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const value = raw as Record<string, unknown>
  const keys = Object.keys(value)
  if (value.kind === 'unavailable' && keys.length === 1) return unavailableKeeperResponseState
  if (value.kind !== 'known') return null
  if (keys.length !== 8 || keys.some(key => !['kind', 'lastSequence', 'floor', 'current', 'partialScope', 'closed', 'phase', 'closedGeneration'].includes(key))) return null
  const floor = value.floor === null ? null : ownerFromUnknown(value.floor)
  const current = value.current === null ? null : ownerFromUnknown(value.current)
  const closed = value.closed === null ? null : ownerFromUnknown(value.closed)
  if ((value.floor !== null && !floor) || (value.current !== null && !current) || (value.closed !== null && !closed)) return null
  if (value.lastSequence !== null && (typeof value.lastSequence !== 'number' || !Number.isSafeInteger(value.lastSequence) || value.lastSequence < 0)) return null
  if (value.phase !== 'running' && value.phase !== 'awaiting-continuation' && value.phase !== 'terminal') return null
  if (value.closedGeneration !== null && (typeof value.closedGeneration !== 'number' || !Number.isSafeInteger(value.closedGeneration) || value.closedGeneration < 0)) return null
  if (value.closedGeneration !== null && (!floor || value.closedGeneration > floor.content_generation)) return null
  if (value.partialScope !== null && (typeof value.partialScope !== 'number' || !Number.isSafeInteger(value.partialScope) || value.partialScope < 0)) return null
  if (current && (!floor || compareOwner(current, floor) !== 0 || value.partialScope !== null)) return null
  if (closed && (!floor || compareOwner(closed, floor) > 0)) return null
  if (value.phase === 'awaiting-continuation' && (current !== null || value.partialScope !== null)) return null
  if (value.phase === 'running' && current && typeof value.closedGeneration === 'number'
    && current.content_generation <= value.closedGeneration) return null
  return Object.freeze({ kind: 'known', lastSequence: value.lastSequence as number | null, floor, current, closed, partialScope: value.partialScope as number | null, phase: value.phase, closedGeneration: value.closedGeneration as number | null })
}

export function sameKeeperResponseOwner(left: KeeperResponseOwner | undefined, right: KeeperResponseOwner | undefined): boolean {
  return left === undefined ? right === undefined : right !== undefined
    && left.content_generation === right.content_generation && left.stream_scope === right.stream_scope
}
