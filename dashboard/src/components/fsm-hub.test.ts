import type { KeeperCompositeSnapshot } from '../api/keeper'
import { describe, expect, it } from 'vitest'

import {
  appendCompositeObservation,
  deriveObservedLaneSummaries,
  deriveOperationalInsight,
  derivePhaseLog,
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
      value: 'executing',
    })
  })
})
