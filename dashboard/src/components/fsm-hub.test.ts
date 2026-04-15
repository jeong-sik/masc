import { describe, expect, it } from 'vitest'

import {
  appendCompositeObservation,
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
})
