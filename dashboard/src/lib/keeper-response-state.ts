import type { KeeperChatStreamEvent } from './keeper-chat-stream-contract'

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
  readonly phase: 'running' | 'awaiting-continuation' | 'terminal' | 'failed'
  readonly closedGeneration: number | null
}

export type KeeperResponseState = ObservedKeeperResponseState | { readonly kind: 'unavailable' }
export const unavailableKeeperResponseState: KeeperResponseState = Object.freeze({ kind: 'unavailable' })

export type KeeperResponseEvent =
  | { readonly kind: 'observe'; readonly owner: KeeperResponseOwner | null; readonly scope: number | null; readonly source: 'header' | 'details' | 'body' | 'content' }
  | { readonly kind: 'stop'; readonly owner: KeeperResponseOwner | null }
  | { readonly kind: 'attempt' | 'started' | 'checkpoint' | 'terminal' | 'failed' | 'text-boundary' }

export interface KeeperResponseDecision {
  readonly state: KeeperResponseState
  readonly accepted: boolean
  readonly advanced: boolean
  readonly authoritative: boolean
  /** The event began a newer response with authored content, so the previous
   * response's details no longer describe the entry. */
  readonly reopens: boolean
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
  const refuse = (): KeeperResponseDecision => ({ state, accepted: false, advanced: false, authoritative: false, reopens: false })
  if (state.kind === 'unavailable') return refuse()
  // A failed operation takes no further response events: its stream has a hole.
  if (state.phase === 'failed') return refuse()
  const settle = (next: ObservedKeeperResponseState): KeeperResponseDecision => (
    { state: Object.freeze(next), accepted: true, advanced: false, authoritative: false, reopens: false }
  )
  switch (event.kind) {
    case 'started':
      if (state.phase === 'terminal' || (state.phase === 'running' && state.floor !== null)) return refuse()
      return settle({ ...state, phase: 'running' })
    case 'failed':
      return state.phase === 'terminal' ? refuse() : settle({ ...state, phase: 'failed' })
    case 'terminal':
    case 'checkpoint':
      if (state.phase === 'terminal') return refuse()
      return settle({ ...state, phase: event.kind === 'terminal' ? 'terminal' : 'awaiting-continuation',
        current: event.kind === 'checkpoint' ? null : state.current,
        partialScope: null, closedGeneration: state.floor?.content_generation ?? state.closedGeneration })
    case 'text-boundary':
      // START and END of a text message mark message boundaries for replay
      // guards and display only; they do not name a response, so any live
      // phase admits them.
      return state.phase === 'terminal' ? refuse() : { state, accepted: true, advanced: false, authoritative: false, reopens: false }
    case 'attempt':
      if (state.phase !== 'running') return refuse()
      return settle({ ...state, current: null, partialScope: null })
    case 'stop':
      if (event.owner && !ownerFromUnknown(event.owner)) return refuse()
      if (state.phase !== 'running') return refuse()
      if (!event.owner) {
        return state.floor ? refuse() : { state, accepted: true, advanced: false, authoritative: true, reopens: false }
      }
      // No established current owner (header-only observation so far, or an
      // attempt/checkpoint boundary cleared it): only the floor's own stop
      // still finalizes; anything else is stale.
      if (!state.current) {
        if (!state.floor || compareOwner(event.owner, state.floor) !== 0) return refuse()
        return { state, accepted: true, advanced: false, authoritative: true, reopens: false }
      }
      if (compareOwner(event.owner, state.current) !== 0
        || (state.closed && compareOwner(event.owner, state.closed) <= 0)) return refuse()
      return { state: Object.freeze({ ...state, closed: state.current }), accepted: true, advanced: false, authoritative: true, reopens: false }
    case 'observe':
      return observeResponse(state, event)
  }
}

function observeResponse(
  state: ObservedKeeperResponseState,
  event: Extract<KeeperResponseEvent, { kind: 'observe' }>,
): KeeperResponseDecision {
  const refuse = (): KeeperResponseDecision => ({ state, accepted: false, advanced: false, authoritative: false, reopens: false })
  if (event.owner && !ownerFromUnknown(event.owner)) return refuse()
  if (event.scope !== null && (!Number.isSafeInteger(event.scope) || event.scope < 0)) return refuse()
  if (state.phase !== 'running') return refuse()
  if (!event.owner) {
    if (state.floor && event.source !== 'body') return refuse()
    const partial = event.scope !== null
    return {
      state: partial ? Object.freeze({ ...state, current: null, partialScope: event.scope }) : state,
      accepted: true, advanced: partial && (state.current !== null || state.partialScope !== event.scope),
      authoritative: state.floor === null, reopens: false,
    }
  }
  const incoming = Object.freeze({ content_generation: event.owner.content_generation, stream_scope: event.owner.stream_scope })
  if (state.closedGeneration !== null && incoming.content_generation <= state.closedGeneration) return refuse()
  const sameCurrent = state.current !== null && compareOwner(incoming, state.current) === 0
  if (sameCurrent) {
    // A continuation or replay of the in-flight response stays admissible,
    // but never past its closure (details may still annotate the closed one).
    if (state.closed && compareOwner(incoming, state.closed) <= 0 && event.source !== 'details') return refuse()
    return { state, accepted: true, advanced: false, authoritative: true, reopens: false }
  }
  // An attempt retires the admitted owner to the floor without clearing it,
  // so an equal identity past the advance is stale, not a re-admission.
  if (state.floor && compareOwner(incoming, state.floor) <= 0) return refuse()
  if (state.floor && incoming.content_generation === state.floor.content_generation
    && state.partialScope !== null && incoming.stream_scope < state.partialScope) return refuse()
  return {
    state: Object.freeze({ ...state, floor: incoming, current: incoming, partialScope: null }),
    accepted: true, advanced: true, authoritative: true,
    // Content-activity metadata may raise the floor for a newer generation,
    // but it has no authored body and must not reopen a stopped response.
    reopens: event.source !== 'content',
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
  if (value.phase !== 'running' && value.phase !== 'awaiting-continuation' && value.phase !== 'terminal' && value.phase !== 'failed') return null
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

/** A response whose stream dropped a frame is incomplete. No later receipt or
 * terminal frame completes it; only the stored transcript can replace it. */
export function keeperResponseIsFailed(state: KeeperResponseState | undefined): boolean {
  return state?.kind === 'known' && state.phase === 'failed'
}

/** The one mapping from a stream frame to the reducer event that admits it, shared
 * by the thread stream and the Copilot dock. A frame that names no response
 * (tool calls, usage, diagnostics) maps to null and is not gated. A finished
 * run maps to terminal; a caller that knows the turn ended at a checkpoint
 * admits a checkpoint instead. */
export function keeperResponseEventOf(event: KeeperChatStreamEvent): KeeperResponseEvent | null {
  switch (event.type) {
    case 'RUN_STARTED':
      return { kind: 'started' }
    case 'RUN_FINISHED':
    case 'RUN_ERROR':
      return { kind: 'terminal' }
    case 'TEXT_MESSAGE_START':
    case 'TEXT_MESSAGE_END':
      return { kind: 'text-boundary' }
    case 'TEXT_MESSAGE_CONTENT':
      return { kind: 'observe', source: 'body', owner: event.textResponse ?? null, scope: event.textStreamScope ?? null }
    case 'CUSTOM':
      switch (event.name) {
        case 'KEEPER_RUNTIME_ATTEMPT_STARTED':
          return { kind: 'attempt' }
        case 'KEEPER_CONTINUATION_CHECKPOINT':
          return { kind: 'checkpoint' }
        case 'KEEPER_STREAM_MESSAGE_START':
        case 'KEEPER_STREAM_MESSAGE_DELTA':
          return {
            kind: 'observe', source: event.name === 'KEEPER_STREAM_MESSAGE_START' ? 'header' : 'details',
            scope: event.value.stream_scope,
            owner: event.value.content_generation === undefined ? null
              : { content_generation: event.value.content_generation, stream_scope: event.value.stream_scope },
          }
        case 'KEEPER_STREAM_MESSAGE_STOP':
          return { kind: 'stop', owner: event.value }
        case 'KEEPER_THINKING_SNAPSHOT':
        case 'KEEPER_THINKING_DELTA':
          return { kind: 'observe', source: 'body', scope: null, owner: event.value.response ?? null }
        case 'KEEPER_MODEL_CONTENT_ACTIVITY':
          return event.value.state === 'observed'
            ? { kind: 'observe', source: 'content', scope: event.value.stream_scope,
                owner: { content_generation: event.value.generation, stream_scope: event.value.stream_scope } }
            : null
        default:
          return null
      }
    default:
      return null
  }
}

/** Both transports use the operation journal cursor, so a snapshot that carries
 * a newer applied sequence is never replaced by an older observer's or a
 * receipt-only write. A snapshot with no applied sequence yet, or with an
 * unavailable state, can always be replaced. */
export function keeperResponseStateMayReplace(
  stored: KeeperResponseState | undefined,
  incoming: KeeperResponseState | undefined,
): boolean {
  if (stored?.kind !== 'known' || stored.lastSequence === null) return true
  return incoming?.kind === 'known' && incoming.lastSequence !== null && incoming.lastSequence >= stored.lastSequence
}

/** A terminal response already holds its receipt; a later lookup failure cannot revoke it. */
export function keeperResponseIsTerminal(state: KeeperResponseState | undefined): boolean {
  return state?.kind === 'known' && state.phase === 'terminal'
}

/** Tool execution facts can arrive after the response's activity has ended. */
export function keeperResponseIsRunning(state: KeeperResponseState = initialKeeperResponseState): boolean {
  return state.kind === 'known' && state.phase === 'running'
}

function sameResponseObservation(left: ObservedKeeperResponseState, right: ObservedKeeperResponseState): boolean {
  return sameKeeperResponseOwner(left.floor ?? undefined, right.floor ?? undefined)
    && sameKeeperResponseOwner(left.current ?? undefined, right.current ?? undefined)
    && sameKeeperResponseOwner(left.closed ?? undefined, right.closed ?? undefined)
    && left.partialScope === right.partialScope && left.phase === right.phase
    && left.closedGeneration === right.closedGeneration
}

/** Resolve observations only after the caller proves the same producer identity. */
export function reconcileKeeperResponseStates(states: readonly (KeeperResponseState | undefined)[]): KeeperResponseState | undefined {
  const known: ObservedKeeperResponseState[] = []
  let latestSequence: number | null = null
  for (const state of states) {
    if (!state) continue
    if (state.kind === 'unavailable') return unavailableKeeperResponseState
    known.push(state)
    if (state.lastSequence !== null && (latestSequence === null || state.lastSequence > latestSequence)) latestSequence = state.lastSequence
  }
  // Resolve the frontier first; older conflicting snapshots cannot override a
  // newer journal observation merely because they appear earlier in the array.
  let selected = known.find(state => state.lastSequence === latestSequence)
  for (const state of known) {
    if (state.lastSequence !== latestSequence && state.lastSequence !== null) continue
    if (state.lastSequence === null && sameResponseObservation(state, initialKeeperResponseState)) continue
    if (!selected || (selected.lastSequence === null && sameResponseObservation(selected, initialKeeperResponseState))) { selected = state; continue }
    if (!sameResponseObservation(state, selected)) return unavailableKeeperResponseState
  }
  return selected
}
