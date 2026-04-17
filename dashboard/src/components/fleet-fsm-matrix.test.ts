import { describe, it, expect } from 'vitest'

import {
  chipClassFor,
  FLEET_HISTORY_LEN,
  inferKeeperNameFrom,
  pushObservation,
  sparkClassFor,
  tallyInvariantViolations,
  type KeeperFleetHistory,
} from './fleet-fsm-matrix'
import type { KeeperCompositeSnapshot } from '../api/keeper'

function snapshot(
  overrides: Partial<KeeperCompositeSnapshot> & {
    name?: string
    allHold?: boolean
    violate?: Partial<KeeperCompositeSnapshot['invariants']>
  } = {},
): KeeperCompositeSnapshot {
  const name = overrides.name ?? 'alpha'
  const allHold = overrides.allHold ?? true
  const base: KeeperCompositeSnapshot = {
    correlation_id: `keeper:${name}:42`,
    run_id: `r-0-${name}`,
    ts: 1_713_000_000,
    phase: 'Running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    cascade: { state: 'idle' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: true },
    invariants: {
      phase_turn_alignment: allHold,
      no_cascade_before_measurement: allHold,
      compaction_atomicity: allHold,
      event_priority_monotone: allHold,
      ...overrides.violate,
    },
    is_live: false,
    last_outcome: null,
  }
  return { ...base, ...overrides }
}

describe('chipClassFor', () => {
  it('maps known states to a distinct tailwind class', () => {
    expect(chipClassFor('Running')).toMatch(/emerald/)
    expect(chipClassFor('Failing')).toMatch(/red/)
    expect(chipClassFor('Compacting')).toMatch(/amber/)
    expect(chipClassFor('exhausted')).toMatch(/red/)
    // KCB (LT-16-KCB Phase 3)
    expect(chipClassFor('warning')).toMatch(/amber/)
    expect(chipClassFor('cooling')).toMatch(/sky/)
  })

  it('falls back to the default chip for unknown states', () => {
    const cls = chipClassFor('unknown_state_variant')
    expect(cls).toContain('bg-zinc-800')
  })
})

describe('inferKeeperNameFrom', () => {
  it('extracts the keeper name from a canonical correlation_id', () => {
    const snap = snapshot({ name: 'gen12-payroll' })
    expect(inferKeeperNameFrom(snap)).toBe('gen12-payroll')
  })

  it('falls back to the correlation_id verbatim on non-canonical ids', () => {
    const snap = snapshot({ correlation_id: 'not-a-keeper-id' })
    expect(inferKeeperNameFrom(snap)).toBe('not-a-keeper-id')
  })
})

describe('tallyInvariantViolations', () => {
  it('returns all zeros when every keeper satisfies every invariant', () => {
    const s = [snapshot({ name: 'a' }), snapshot({ name: 'b' })]
    expect(tallyInvariantViolations(s)).toEqual({
      phase_turn_alignment: 0,
      no_cascade_before_measurement: 0,
      compaction_atomicity: 0,
      event_priority_monotone: 0,
    })
  })

  it('counts one per keeper per violated invariant', () => {
    const s = [
      snapshot({ name: 'a', violate: { phase_turn_alignment: false } }),
      snapshot({ name: 'b', violate: { phase_turn_alignment: false, compaction_atomicity: false } }),
      snapshot({ name: 'c' }),
    ]
    const t = tallyInvariantViolations(s)
    expect(t.phase_turn_alignment).toBe(2)
    expect(t.compaction_atomicity).toBe(1)
    expect(t.no_cascade_before_measurement).toBe(0)
    expect(t.event_priority_monotone).toBe(0)
  })

  it('treats an empty fleet as clean', () => {
    expect(tallyInvariantViolations([])).toEqual({
      phase_turn_alignment: 0,
      no_cascade_before_measurement: 0,
      compaction_atomicity: 0,
      event_priority_monotone: 0,
    })
  })
})

describe('sparkClassFor', () => {
  it('extracts a single bg-* utility from the full chip class', () => {
    expect(sparkClassFor('Running')).toMatch(/^bg-emerald-900/)
    expect(sparkClassFor('Failing')).toMatch(/^bg-red-900/)
  })

  it('falls back to a grey shade on unknown states', () => {
    // DEFAULT_CHIP carries `bg-zinc-800`; sparkClassFor preserves it.
    expect(sparkClassFor('__not_a_state__')).toMatch(/^bg-zinc-(700|800)/)
  })
})

describe('pushObservation', () => {
  it('seeds a new keeper with one observation per axis', () => {
    const next = pushObservation({}, [snapshot({ name: 'alpha' })])
    const alpha = next.alpha!
    expect(alpha.phase).toEqual(['Running'])
    expect(alpha.turn).toEqual(['idle'])
    expect(alpha.decision).toEqual(['undecided'])
    expect(alpha.cascade).toEqual(['idle'])
    expect(alpha.compaction).toEqual(['accumulating'])
  })

  it('appends new observations while preserving prior ones', () => {
    const t1 = pushObservation({}, [snapshot({ name: 'alpha', phase: 'Running' })])
    const t2 = pushObservation(t1, [snapshot({ name: 'alpha', phase: 'Failing' })])
    expect(t2.alpha!.phase).toEqual(['Running', 'Failing'])
  })

  it('caps each axis series at the history window', () => {
    let h: KeeperFleetHistory = {}
    for (let i = 0; i < FLEET_HISTORY_LEN + 7; i++) {
      h = pushObservation(h, [snapshot({ name: 'a' })], FLEET_HISTORY_LEN)
    }
    expect(h.a!.phase.length).toBe(FLEET_HISTORY_LEN)
  })

  it('drops keepers that disappear from the latest snapshot', () => {
    const t1 = pushObservation({}, [
      snapshot({ name: 'alpha' }),
      snapshot({ name: 'beta' }),
    ])
    expect(Object.keys(t1).sort()).toEqual(['alpha', 'beta'])
    const t2 = pushObservation(t1, [snapshot({ name: 'alpha' })])
    expect(Object.keys(t2)).toEqual(['alpha'])
  })

  it('returns a fresh top-level object for identity-based re-renders', () => {
    const prior = {}
    const next = pushObservation(prior, [snapshot({ name: 'alpha' })])
    expect(next).not.toBe(prior)
  })

  it('includes the KCB breaker axis in a fresh seed (default=clean)', () => {
    const next = pushObservation({}, [snapshot({ name: 'alpha' })])
    // The snapshot helper omits `circuit_breaker`, mirroring a pinned
    // backend that has not yet shipped LT-16-KCB Phase 2. The matrix
    // must still seed a value instead of leaving the axis undefined.
    expect(next.alpha!.breaker).toEqual(['clean'])
  })

  it('tracks KCB warning→cooling over successive polls', () => {
    const warn = snapshot({ name: 'beta', circuit_breaker: { state: 'warning' } })
    const cool = snapshot({ name: 'beta', circuit_breaker: { state: 'cooling' } })
    const t1 = pushObservation({}, [warn])
    const t2 = pushObservation(t1, [cool])
    expect(t2.beta!.breaker).toEqual(['warning', 'cooling'])
  })
})
