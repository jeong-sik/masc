import type { KeeperCompositeSnapshot } from '../api/keeper'
import { describe, expect, it } from 'vitest'

import {
  appendCompositeObservation,
  deriveObservedLaneSummaries,
  deriveOperationalInsight,
  derivePhaseLog,
  deriveStateEntries,
  deriveSwimlaneSegments,
  deriveTransitionHistory,
  type CompositeObservation,
} from './fsm-hub'

function observation(
  overrides: Partial<CompositeObservation> = {},
): CompositeObservation {
  return {
    ts: 1,
    phase: 'Running',
    turn: 'idle',
    decision: 'undecided',
    cascade: 'idle',
    compaction: 'idle',
    ...overrides,
  }
}

function snapshot(
  overrides: Partial<KeeperCompositeSnapshot> = {},
): KeeperCompositeSnapshot {
  const base: KeeperCompositeSnapshot = {
    correlation_id: 'corr',
    run_id: 'run',
    ts: 100,
    phase: 'Running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    cascade: { state: 'idle' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: false },
    recovery: { data_record: false, fsm_condition: false },
    invariants: {
      phase_turn_alignment: true,
      no_cascade_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      recovery_two_store_sync: true,
    },
    is_live: false,
    last_outcome: null,
  }

  return {
    ...base,
    ...overrides,
    decision: {
      ...base.decision,
      ...(overrides.decision ?? {}),
    },
    cascade: {
      ...base.cascade,
      ...(overrides.cascade ?? {}),
    },
    compaction: {
      ...base.compaction,
      ...(overrides.compaction ?? {}),
    },
    measurement: {
      ...base.measurement,
      ...(overrides.measurement ?? {}),
    },
    recovery: {
      ...base.recovery,
      ...(overrides.recovery ?? {}),
    },
    invariants: {
      ...base.invariants,
      ...(overrides.invariants ?? {}),
    },
  }
}

describe('fsm-hub derived state', () => {
  it('skips duplicate observations when tracked fields are unchanged', () => {
    const first = observation()

    expect(
      appendCompositeObservation([first], observation({ ts: 2 })),
    ).toEqual([first])
  })

  it('derives newest-first transition entries from observation changes', () => {
    const observations = [
      observation({ ts: 1 }),
      observation({ ts: 2, phase: 'Compacting', turn: 'running' }),
      observation({ ts: 3, phase: 'Compacting', turn: 'running', cascade: 'retrying' }),
    ]

    expect(deriveTransitionHistory(observations)).toEqual([
      { ts: 3, from: 'idle', to: 'retrying', field: 'KCL' },
      { ts: 2, from: 'idle', to: 'running', field: 'KTC' },
      { ts: 2, from: 'Running', to: 'Compacting', field: 'KSM' },
    ])
  })

  it('keeps only distinct consecutive phases in the phase log', () => {
    const observations = [
      observation({ ts: 1, phase: 'Running' }),
      observation({ ts: 2, phase: 'Running', turn: 'running' }),
      observation({ ts: 3, phase: 'Failing' }),
      observation({ ts: 4, phase: 'Failing', cascade: 'retrying' }),
    ]

    expect(derivePhaseLog(observations)).toEqual([
      'Running',
      'Failing',
    ])
  })

  it('derives spec-drift insight from broken invariants', () => {
    const result = deriveOperationalInsight(
      snapshot({
        phase: 'Compacting',
        turn_phase: 'executing',
        compaction: { stage: 'accumulating' },
        invariants: {
          phase_turn_alignment: false,
          no_cascade_before_measurement: true,
          compaction_atomicity: true,
          event_priority_monotone: true,
          recovery_two_store_sync: true,
        },
      }),
      [observation({ ts: 10, phase: 'Compacting', turn: 'executing' })],
      20,
    )

    expect(result.tone).toBe('error')
    expect(result.headline).toContain('Spec drift')
    expect(result.detail).toContain('KSM=Compacting')
  })

  it('interprets idle snapshots as stable placeholders, not live work', () => {
    const result = deriveOperationalInsight(
      snapshot({
        is_live: false,
        last_outcome: {
          turn_id: 42,
          ended_at: 75,
        },
      }),
      [observation({ ts: 75 })],
      100,
    )

    expect(result.tone).toBe('ok')
    expect(result.headline).toContain('Idle snapshot')
    expect(result.detail).toContain('25s ago')
  })

  it('marks long-running observed execution as stalled on screen', () => {
    const lanes = deriveObservedLaneSummaries(
      snapshot({
        is_live: true,
        turn_phase: 'executing',
      }),
      [observation({ ts: 10, turn: 'executing' })],
      80,
    )

    expect(lanes.find(lane => lane.field === 'KTC')).toMatchObject({
      tone: 'warn',
      stalled: true,
      value: 'executing',
    })
  })

  it('keeps active compaction as compaction work before the stall threshold', () => {
    const result = deriveOperationalInsight(
      snapshot({
        is_live: true,
        phase: 'Compacting',
        turn_phase: 'compacting',
        compaction: { stage: 'compacting' },
      }),
      [observation({ ts: 10, phase: 'Compacting', turn: 'compacting', compaction: 'compacting' })],
      20,
    )

    expect(result.tone).toBe('info')
    expect(result.headline).toContain('Compaction currently owns the turn')
  })
})

describe('deriveStateEntries', () => {
  it('returns null for empty observations', () => {
    expect(deriveStateEntries([])).toBeNull()
  })

  it('falls back to first observation ts when no transitions', () => {
    const observations = [
      observation({ ts: 100, phase: 'Running', turn: 'idle', decision: 'undecided', cascade: 'idle', compaction: 'accumulating' }),
      observation({ ts: 105, phase: 'Running', turn: 'idle', decision: 'undecided', cascade: 'idle', compaction: 'accumulating' }),
      observation({ ts: 110, phase: 'Running', turn: 'idle', decision: 'undecided', cascade: 'idle', compaction: 'accumulating' }),
    ]
    const entries = deriveStateEntries(observations)
    expect(entries).toEqual({ phase: 100, turn: 100, decision: 100, cascade: 100, compaction: 100 })
  })

  it('returns the ts of the latest transition per lane', () => {
    const observations = [
      observation({ ts: 100, phase: 'Running', turn: 'idle', decision: 'undecided', cascade: 'idle', compaction: 'accumulating' }),
      observation({ ts: 110, phase: 'Running', turn: 'prompting', decision: 'undecided', cascade: 'idle', compaction: 'accumulating' }),
      observation({ ts: 120, phase: 'Running', turn: 'executing', decision: 'guard_ok', cascade: 'selecting', compaction: 'accumulating' }),
      observation({ ts: 130, phase: 'Compacting', turn: 'executing', decision: 'guard_ok', cascade: 'done', compaction: 'accumulating' }),
    ]
    const entries = deriveStateEntries(observations)
    expect(entries).toEqual({
      phase: 130,
      turn: 120,
      decision: 120,
      cascade: 130,
      compaction: 100,
    })
  })

  it('uses the most recent transition when a lane flips repeatedly', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 110, turn: 'prompting' }),
      observation({ ts: 120, turn: 'idle' }),
      observation({ ts: 130, turn: 'prompting' }),
    ]
    const entries = deriveStateEntries(observations)
    expect(entries?.turn).toBe(130)
  })
})

describe('deriveSwimlaneSegments', () => {
  it('returns an empty list when no observations exist', () => {
    expect(deriveSwimlaneSegments([], 'turn', 100)).toEqual([])
  })

  it('collapses same consecutive values into a single segment', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 105, turn: 'idle' }),
      observation({ ts: 110, turn: 'idle' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'turn', 120)
    expect(segments).toEqual([{ from: 100, to: 120, value: 'idle' }])
  })

  it('closes a segment when the value changes and extends the tail to boundsEnd', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 110, turn: 'prompting' }),
      observation({ ts: 120, turn: 'executing' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'turn', 200)
    expect(segments).toEqual([
      { from: 100, to: 110, value: 'idle' },
      { from: 110, to: 120, value: 'prompting' },
      { from: 120, to: 200, value: 'executing' },
    ])
  })

  it('leaves the tail at the last observation ts when boundsEnd is earlier', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 150, turn: 'prompting' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'turn', 120)
    expect(segments[segments.length - 1]).toEqual({ from: 150, to: 150, value: 'prompting' })
  })

  it('emits back-to-back segments when a value repeats after a different one', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 110, turn: 'prompting' }),
      observation({ ts: 120, turn: 'idle' }),
      observation({ ts: 130, turn: 'prompting' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'turn', 140)
    expect(segments.map(s => s.value)).toEqual(['idle', 'prompting', 'idle', 'prompting'])
    expect(segments[3]).toEqual({ from: 130, to: 140, value: 'prompting' })
  })
})
