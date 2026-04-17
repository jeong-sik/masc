import { describe, it, expect } from 'vitest'

import {
  chipClassFor,
  inferKeeperNameFrom,
  tallyInvariantViolations,
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
