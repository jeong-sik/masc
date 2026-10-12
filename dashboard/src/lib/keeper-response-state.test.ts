import { describe, expect, it } from 'vitest'
import {
  acknowledgeKeeperResponseSequence,
  initialKeeperResponseState,
  keeperResponseStateFromUnknown,
  ownerFromUnknown,
  reduceKeeperResponse,
  sameKeeperResponseOwner,
  unavailableKeeperResponseState,
  type KeeperResponseDecision,
  type KeeperResponseEvent,
  type KeeperResponseState,
  type ObservedKeeperResponseState,
} from './keeper-response-state'

const owner = (generation: number, scope = 0) => ({ content_generation: generation, stream_scope: scope })

function observe(
  generation: number | null,
  scope: number | null = 0,
  source: 'header' | 'details' | 'body' | 'content' = 'body',
): KeeperResponseEvent {
  return {
    kind: 'observe', source, scope,
    owner: generation === null ? null : owner(generation, scope ?? 0),
  }
}

/** Applies events in order and returns the last decision plus every accepted flag. */
function run(events: readonly KeeperResponseEvent[], from: KeeperResponseState = initialKeeperResponseState) {
  let state = from
  const decisions: KeeperResponseDecision[] = []
  for (const event of events) {
    const decision = reduceKeeperResponse(state, event)
    decisions.push(decision)
    state = decision.state
  }
  return { state, decisions, last: decisions[decisions.length - 1]! }
}

function known(state: KeeperResponseState): ObservedKeeperResponseState {
  if (state.kind !== 'known') throw new Error('expected a known response state')
  return state
}

const ALL_EVENTS: readonly KeeperResponseEvent[] = [
  observe(1),
  { kind: 'stop', owner: owner(1) },
  { kind: 'attempt' },
  { kind: 'started' },
  { kind: 'checkpoint' },
  { kind: 'terminal' },
  { kind: 'failed' },
  { kind: 'text-boundary' },
]

describe('reduceKeeperResponse lifecycle phases', () => {
  it('starts running with no floor, current, closure or sequence', () => {
    expect(initialKeeperResponseState).toEqual({
      kind: 'known', lastSequence: null, floor: null, current: null, partialScope: null,
      closed: null, phase: 'running', closedGeneration: null,
    })
  })

  it('refuses every event for an unavailable state and keeps it unavailable', () => {
    for (const event of ALL_EVENTS) {
      const decision = reduceKeeperResponse(unavailableKeeperResponseState, event)
      expect(decision).toEqual({ state: unavailableKeeperResponseState, accepted: false, advanced: false, authoritative: false })
    }
  })

  it('refuses every event once the operation failed', () => {
    const failed = run([observe(2), { kind: 'failed' }]).state
    expect(known(failed).phase).toBe('failed')
    for (const event of ALL_EVENTS) {
      const decision = reduceKeeperResponse(failed, event)
      expect(decision.accepted).toBe(false)
      expect(decision.state).toBe(failed)
    }
  })

  it('fails a running or continuing operation but not a finished one', () => {
    expect(known(run([{ kind: 'failed' }]).state).phase).toBe('failed')
    expect(known(run([observe(1), { kind: 'checkpoint' }, { kind: 'failed' }]).state).phase).toBe('failed')
    const finished = run([observe(1), { kind: 'terminal' }, { kind: 'failed' }])
    expect(finished.last.accepted).toBe(false)
    expect(known(finished.state).phase).toBe('terminal')
  })

  it('keeps the floor and closure when an operation fails', () => {
    const failed = known(run([observe(3), { kind: 'stop', owner: owner(3) }, { kind: 'failed' }]).state)
    expect(failed).toMatchObject({ floor: owner(3), closed: owner(3), phase: 'failed' })
  })

  it('moves to terminal once and refuses a second terminal or checkpoint', () => {
    const done = run([observe(1), { kind: 'terminal' }])
    expect(known(done.state)).toMatchObject({ phase: 'terminal', floor: owner(1), current: owner(1), closedGeneration: 1 })
    for (const event of [{ kind: 'terminal' }, { kind: 'checkpoint' }, { kind: 'started' }, { kind: 'attempt' }, observe(9), { kind: 'text-boundary' }] as const) {
      expect(reduceKeeperResponse(done.state, event).accepted).toBe(false)
    }
  })

  it('terminal without any observed response records no closed generation', () => {
    expect(known(run([{ kind: 'terminal' }]).state)).toMatchObject({ phase: 'terminal', closedGeneration: null })
  })

  it('checkpoint waits for a continuation: no current, only a started run resumes', () => {
    const waiting = run([observe(2), { kind: 'checkpoint' }])
    expect(known(waiting.state)).toMatchObject({ phase: 'awaiting-continuation', current: null, partialScope: null, closedGeneration: 2 })
    for (const event of [observe(3), { kind: 'stop', owner: owner(2) }, { kind: 'attempt' }] as const) {
      expect(reduceKeeperResponse(waiting.state, event).accepted).toBe(false)
    }
    const resumed = reduceKeeperResponse(waiting.state, { kind: 'started' })
    expect(resumed.accepted).toBe(true)
    expect(known(resumed.state)).toMatchObject({ phase: 'running', current: null, floor: owner(2), closedGeneration: 2 })
  })

  it('refuses a started event while a response is already running', () => {
    expect(run([observe(1), { kind: 'started' }]).last.accepted).toBe(false)
    expect(run([{ kind: 'started' }]).last.accepted).toBe(true)
  })

  it('a continuation may not reuse a generation at or below the closed one', () => {
    const resumed = run([observe(2), { kind: 'checkpoint' }, { kind: 'started' }]).state
    expect(reduceKeeperResponse(resumed, observe(2, 5)).accepted).toBe(false)
    expect(reduceKeeperResponse(resumed, observe(1, 9)).accepted).toBe(false)
    const next = reduceKeeperResponse(resumed, observe(3))
    expect(next).toMatchObject({ accepted: true, advanced: true, authoritative: true })
  })

  it('text boundaries are admitted only before any response is observed', () => {
    expect(run([{ kind: 'text-boundary' }]).last).toMatchObject({ accepted: true, advanced: false, authoritative: false })
    expect(run([{ kind: 'text-boundary' }]).state).toBe(initialKeeperResponseState)
    expect(run([observe(1), { kind: 'text-boundary' }]).last.accepted).toBe(false)
    expect(run([{ kind: 'terminal' }, { kind: 'text-boundary' }]).last.accepted).toBe(false)
    expect(run([{ kind: 'checkpoint' }, { kind: 'text-boundary' }]).last.accepted).toBe(true)
  })

  it('an unowned partial scope alone does not close text boundaries', () => {
    expect(run([observe(null, 3), { kind: 'text-boundary' }]).last.accepted).toBe(true)
  })
})

describe('reduceKeeperResponse owner, floor and current', () => {
  it('admits the first owned response and records it as floor and current', () => {
    const decision = run([observe(4, 1)]).last
    expect(decision).toMatchObject({ accepted: true, advanced: true, authoritative: true })
    expect(known(decision.state)).toMatchObject({ floor: owner(4, 1), current: owner(4, 1), partialScope: null, closed: null })
  })

  it('treats the same owner as a continuation, not an advance', () => {
    const decision = run([observe(4, 1), observe(4, 1)]).last
    expect(decision).toMatchObject({ accepted: true, advanced: false, authoritative: true })
  })

  it('refuses an owner at or below the floor by generation then scope', () => {
    const state = run([observe(5, 2)]).state
    for (const refused of [owner(4, 99), owner(5, 1), owner(5, 0)]) {
      const decision = reduceKeeperResponse(state, { kind: 'observe', owner: refused, scope: refused.stream_scope, source: 'body' })
      expect(decision.accepted).toBe(false)
      expect(decision.state).toBe(state)
    }
  })

  it('advances to a newer scope or generation and moves the floor with it', () => {
    const scope = run([observe(5, 0), observe(5, 1)])
    expect(scope.last).toMatchObject({ accepted: true, advanced: true })
    expect(known(scope.state)).toMatchObject({ floor: owner(5, 1), current: owner(5, 1) })
    const generation = run([observe(5, 3), observe(6, 0)])
    expect(known(generation.state)).toMatchObject({ floor: owner(6, 0), current: owner(6, 0) })
  })

  it('an attempt retires the current response to the floor and keeps it stale', () => {
    const retired = run([observe(5, 0), { kind: 'attempt' }])
    expect(known(retired.state)).toMatchObject({ floor: owner(5, 0), current: null })
    expect(reduceKeeperResponse(retired.state, observe(5, 0)).accepted).toBe(false)
    expect(reduceKeeperResponse(retired.state, observe(4, 9)).accepted).toBe(false)
    expect(reduceKeeperResponse(retired.state, observe(5, 1)).accepted).toBe(true)
  })

  it('an unobserved scope demotes lower scopes of the same generation', () => {
    const partial = run([observe(5, 0), observe(null, 3)])
    expect(partial.last).toMatchObject({ accepted: true, advanced: true })
    expect(known(partial.state)).toMatchObject({ current: null, partialScope: 3, floor: owner(5, 0) })
    expect(reduceKeeperResponse(partial.state, observe(5, 2)).accepted).toBe(false)
    const admitted = reduceKeeperResponse(partial.state, observe(5, 3))
    expect(admitted.accepted).toBe(true)
    expect(known(admitted.state).partialScope).toBeNull()
  })

  it('repeating the same unobserved scope is not an advance', () => {
    const repeated = run([observe(null, 3), observe(null, 3)])
    expect(repeated.decisions[0]).toMatchObject({ accepted: true, advanced: true })
    expect(repeated.last).toMatchObject({ accepted: true, advanced: false })
  })

  it('unowned body bytes are kept but are not authoritative once a floor exists', () => {
    expect(run([observe(null, null)]).last).toMatchObject({ accepted: true, advanced: false, authoritative: true })
    expect(run([observe(5, 0), observe(null, null)]).last).toMatchObject({ accepted: true, advanced: false, authoritative: false })
  })

  it('refuses unowned header, details and content once a floor exists', () => {
    for (const source of ['header', 'details', 'content'] as const) {
      expect(run([observe(5, 0), observe(null, null, source)]).last.accepted).toBe(false)
    }
    for (const source of ['header', 'details', 'content'] as const) {
      expect(run([observe(null, null, source)]).last.accepted).toBe(true)
    }
  })

  it('refuses malformed owners and scopes without changing state', () => {
    const state = run([observe(5, 0)]).state
    // Each malformed owner would be admitted if only its numbers were compared:
    // the observed ones are newer than the floor, the stop ones equal the current response.
    const badObservedOwners: unknown[] = [
      { content_generation: 9.5, stream_scope: 0 },
      { content_generation: 9, stream_scope: Number.MAX_SAFE_INTEGER + 1 },
      { content_generation: 9, stream_scope: 0, extra: true },
      { content_generation: '9', stream_scope: 0 },
    ]
    const badStopOwners: unknown[] = [
      { content_generation: 5, stream_scope: 0, extra: true },
      { content_generation: 5, stream_scope: '0' },
      { content_generation: '5', stream_scope: 0 },
    ]
    for (const bad of badObservedOwners) {
      const decision = reduceKeeperResponse(state, { kind: 'observe', owner: bad as never, scope: 0, source: 'body' })
      expect(decision.accepted).toBe(false)
      expect(decision.state).toBe(state)
    }
    for (const bad of badStopOwners) {
      const decision = reduceKeeperResponse(state, { kind: 'stop', owner: bad as never })
      expect(decision.accepted).toBe(false)
      expect(decision.state).toBe(state)
    }
    for (const scope of [-1, 0.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1]) {
      const decision = reduceKeeperResponse(state, { kind: 'observe', owner: null, scope, source: 'body' })
      expect(decision.accepted).toBe(false)
      expect(decision.state).toBe(state)
    }
  })

  it('content activity raises the floor and refuses the older delayed text', () => {
    const state = run([observe(3, 0), observe(4, 0, 'content')]).state
    expect(known(state)).toMatchObject({ floor: owner(4, 0) })
    expect(reduceKeeperResponse(state, observe(3, 0)).accepted).toBe(false)
  })

  it('never mutates the state it was given and returns frozen states', () => {
    const before = run([observe(5, 0)]).state
    const snapshot = JSON.stringify(before)
    const decision = reduceKeeperResponse(before, observe(6, 0))
    expect(JSON.stringify(before)).toBe(snapshot)
    expect(Object.isFrozen(decision.state)).toBe(true)
    expect(Object.isFrozen(known(decision.state).floor)).toBe(true)
  })
})

describe('reduceKeeperResponse stop and closure', () => {
  it('accepts an ownerless stop only before any response was observed', () => {
    expect(run([{ kind: 'stop', owner: null }]).last).toMatchObject({ accepted: true, authoritative: true })
    expect(run([observe(1), { kind: 'stop', owner: null }]).last.accepted).toBe(false)
  })

  it('accepts a stop equal to the current response and closes it', () => {
    const stopped = run([observe(6, 0), { kind: 'stop', owner: owner(6, 0) }])
    expect(stopped.last).toMatchObject({ accepted: true, authoritative: true, advanced: false })
    expect(known(stopped.state)).toMatchObject({ closed: owner(6, 0), current: owner(6, 0), floor: owner(6, 0) })
  })

  it('refuses a stop for an older, newer or unobserved response', () => {
    const state = run([observe(6, 0)]).state
    for (const other of [owner(5, 0), owner(6, 1), owner(7, 0)]) {
      const decision = reduceKeeperResponse(state, { kind: 'stop', owner: other })
      expect(decision.accepted).toBe(false)
      expect(decision.state).toBe(state)
    }
    expect(run([{ kind: 'stop', owner: owner(1) }]).last.accepted).toBe(false)
  })

  it('refuses a stop after an attempt retired the current response', () => {
    expect(run([observe(6, 0), { kind: 'attempt' }, { kind: 'stop', owner: owner(6, 0) }]).last.accepted).toBe(false)
  })

  it('refuses a second stop for a closed response', () => {
    expect(run([observe(6, 0), { kind: 'stop', owner: owner(6, 0) }, { kind: 'stop', owner: owner(6, 0) }]).last.accepted).toBe(false)
  })

  it('refuses body, header and content for a closed response but lets details annotate it', () => {
    const closed = run([observe(6, 0), { kind: 'stop', owner: owner(6, 0) }]).state
    for (const source of ['body', 'header', 'content'] as const) {
      expect(reduceKeeperResponse(closed, observe(6, 0, source)).accepted).toBe(false)
    }
    expect(reduceKeeperResponse(closed, observe(6, 0, 'details'))).toMatchObject({ accepted: true, advanced: false, authoritative: true })
  })

  it('a newer response reopens after a stop and the stale closed one stays refused', () => {
    const next = run([observe(6, 0), { kind: 'stop', owner: owner(6, 0) }, observe(7, 0)])
    expect(next.last).toMatchObject({ accepted: true, advanced: true })
    expect(known(next.state)).toMatchObject({ floor: owner(7, 0), current: owner(7, 0), closed: owner(6, 0) })
    expect(reduceKeeperResponse(next.state, observe(6, 0)).accepted).toBe(false)
    expect(reduceKeeperResponse(next.state, { kind: 'stop', owner: owner(6, 0) }).accepted).toBe(false)
  })
})

describe('acknowledgeKeeperResponseSequence', () => {
  it('has no answer for an unavailable state', () => {
    expect(acknowledgeKeeperResponseSequence(unavailableKeeperResponseState, 1)).toBeNull()
    expect(acknowledgeKeeperResponseSequence(unavailableKeeperResponseState, undefined)).toBeNull()
  })

  it('keeps the state for a frame without a sequence', () => {
    expect(acknowledgeKeeperResponseSequence(initialKeeperResponseState, undefined)).toBe(initialKeeperResponseState)
  })

  it('advances only to a strictly greater safe integer', () => {
    const first = acknowledgeKeeperResponseSequence(initialKeeperResponseState, 3)
    expect(first).toMatchObject({ lastSequence: 3 })
    expect(acknowledgeKeeperResponseSequence(first!, 3)).toBeNull()
    expect(acknowledgeKeeperResponseSequence(first!, 2)).toBeNull()
    expect(acknowledgeKeeperResponseSequence(first!, 4)).toMatchObject({ lastSequence: 4 })
  })

  it('refuses negative, fractional and unsafe sequences', () => {
    for (const sequence of [-1, 0.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1, Infinity]) {
      expect(acknowledgeKeeperResponseSequence(initialKeeperResponseState, sequence)).toBeNull()
    }
    expect(acknowledgeKeeperResponseSequence(initialKeeperResponseState, 0)).toMatchObject({ lastSequence: 0 })
  })
})

describe('ownerFromUnknown and sameKeeperResponseOwner', () => {
  it('parses exactly the two owner fields', () => {
    expect(ownerFromUnknown({ content_generation: 1, stream_scope: 2 })).toEqual(owner(1, 2))
    for (const raw of [null, undefined, 3, 'x', [], { content_generation: 1 }, { content_generation: 1, stream_scope: 2, x: 1 },
      { content_generation: -1, stream_scope: 0 }, { content_generation: 0, stream_scope: 0.5 }]) {
      expect(ownerFromUnknown(raw)).toBeNull()
    }
  })

  it('compares owners by both fields and treats two absent owners as equal', () => {
    expect(sameKeeperResponseOwner(undefined, undefined)).toBe(true)
    expect(sameKeeperResponseOwner(owner(1, 2), undefined)).toBe(false)
    expect(sameKeeperResponseOwner(undefined, owner(1, 2))).toBe(false)
    expect(sameKeeperResponseOwner(owner(1, 2), owner(1, 2))).toBe(true)
    expect(sameKeeperResponseOwner(owner(1, 2), owner(1, 3))).toBe(false)
    expect(sameKeeperResponseOwner(owner(1, 2), owner(2, 2))).toBe(false)
  })
})

describe('keeperResponseStateFromUnknown', () => {
  const stored = (patch: Record<string, unknown>) => ({ ...initialKeeperResponseState, ...patch })

  it('reads back every state the reducer produces', () => {
    const states: KeeperResponseState[] = [
      initialKeeperResponseState,
      unavailableKeeperResponseState,
      run([observe(3, 1)]).state,
      run([observe(3, 1), { kind: 'stop', owner: owner(3, 1) }]).state,
      run([observe(3, 1), { kind: 'attempt' }]).state,
      run([observe(3, 1), observe(null, 4)]).state,
      run([observe(3, 1), { kind: 'checkpoint' }]).state,
      run([observe(3, 1), { kind: 'checkpoint' }, { kind: 'started' }]).state,
      run([observe(3, 1), { kind: 'terminal' }]).state,
      run([observe(3, 1), { kind: 'failed' }]).state,
      run([observe(3, 1)], acknowledgeKeeperResponseSequence(initialKeeperResponseState, 7)!).state,
    ]
    for (const state of states) {
      expect(keeperResponseStateFromUnknown(JSON.parse(JSON.stringify(state)))).toEqual(state)
    }
  })

  it('returns frozen state', () => {
    expect(Object.isFrozen(keeperResponseStateFromUnknown(JSON.parse(JSON.stringify(run([observe(1)]).state))))).toBe(true)
  })

  it('rejects anything that is not an object with a known kind', () => {
    for (const raw of [null, undefined, 1, 'known', [], {}, { kind: 'other' }, { kind: 'unavailable', phase: 'running' }]) {
      expect(keeperResponseStateFromUnknown(raw)).toBeNull()
    }
  })

  it('rejects missing, extra and renamed fields', () => {
    const { phase: _phase, ...withoutPhase } = initialKeeperResponseState
    expect(keeperResponseStateFromUnknown(withoutPhase)).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ extra: 1 }))).toBeNull()
  })

  it('rejects an unknown phase and accepts each real one', () => {
    expect(keeperResponseStateFromUnknown(stored({ phase: 'paused' }))).toBeNull()
    for (const phase of ['running', 'awaiting-continuation', 'terminal', 'failed']) {
      expect(keeperResponseStateFromUnknown(stored({ phase }))).toMatchObject({ phase })
    }
  })

  it('rejects malformed owners, sequences, scopes and generations', () => {
    const floor = owner(3, 0)
    expect(keeperResponseStateFromUnknown(stored({ floor: { content_generation: 'x', stream_scope: 0 } }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closed: { nope: 1 } }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ lastSequence: -1 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ lastSequence: 1.5 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ lastSequence: '1' }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ partialScope: -1 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closedGeneration: 1.5 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closedGeneration: -1 }))).toBeNull()
  })

  it('rejects relations between floor, current, closed and closedGeneration that the reducer cannot produce', () => {
    const floor = owner(3, 2)
    expect(keeperResponseStateFromUnknown(stored({ current: floor }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, current: owner(3, 1) }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, current: floor, partialScope: 4 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, current: floor }))).toMatchObject({ current: floor })
    expect(keeperResponseStateFromUnknown(stored({ closed: floor }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closed: owner(3, 3) }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closed: owner(2, 9) }))).toMatchObject({ closed: owner(2, 9) })
    expect(keeperResponseStateFromUnknown(stored({ closedGeneration: 1 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closedGeneration: 4 }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closedGeneration: 3 }))).toMatchObject({ closedGeneration: 3 })
  })

  it('rejects a continuation that still holds a response and a running response below its closure', () => {
    const floor = owner(3, 0)
    expect(keeperResponseStateFromUnknown(stored({ floor, current: floor, phase: 'awaiting-continuation' }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, partialScope: 2, phase: 'awaiting-continuation' }))).toBeNull()
    expect(keeperResponseStateFromUnknown(stored({ floor, closedGeneration: 3, phase: 'awaiting-continuation' }))).toMatchObject({ phase: 'awaiting-continuation' })
    expect(keeperResponseStateFromUnknown(stored({ floor, current: floor, closedGeneration: 3, phase: 'running' }))).toBeNull()
  })

  it('keeps a stored state refusing what the live state refused', () => {
    const live = run([observe(5, 0), { kind: 'stop', owner: owner(5, 0) }, observe(6, 0), { kind: 'attempt' }]).state
    const restored = keeperResponseStateFromUnknown(JSON.parse(JSON.stringify(live)))!
    for (const event of [observe(6, 0), observe(5, 0), { kind: 'stop', owner: owner(6, 0) }] as const) {
      expect(reduceKeeperResponse(restored, event).accepted).toBe(reduceKeeperResponse(live, event).accepted)
    }
    expect(reduceKeeperResponse(restored, observe(7, 0)).accepted).toBe(true)
  })
})
