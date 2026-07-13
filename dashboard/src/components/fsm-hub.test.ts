import type { KeeperCompositeSnapshot } from '../api/keeper'
import { describe, expect, it } from 'vitest'

import {
  appendCompositeObservation,
  deriveLaneDwellHistograms,
  derivePhaseLog,
  deriveStateEntries,
  deriveSwimlaneSegments,
  deriveTimeAxisTicks,
  deriveTopTransitions,
  deriveTransitionHistory,
  inferTransitionReason,
  laneTransitionCount,
} from './fsm-hub-derivations'
import {
  type CompositeObservation,
  type HoveredSegment,
} from './fsm-hub-types'
import { deriveObservedLaneSummaries } from './fsm-hub-lane-analysis'
import { deriveOperationalInsight } from './fsm-hub-invariant-analysis'
import { flagTooltip, invariantDescription } from './fsm-hub-health-panels'
import { isTransitionInSegment } from './fsm-hub-timeline-panels'
import { filterKeeperNames } from './fsm-hub'

function observation(
  overrides: Partial<CompositeObservation> = {},
): CompositeObservation {
  return {
    ts: 1,
    phase: 'Running',
    turn: 'idle',
    decision: 'undecided',
    runtime: 'idle',
    compaction: 'accumulating',
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
    runtime: { state: 'idle' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: false },
    invariants: {
      phase_turn_alignment: true,
      no_runtime_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
    is_live: false,
    last_outcome: null,
    recommended_actions: [],
  }

  return {
    ...base,
    ...overrides,
    decision: {
      ...base.decision,
      ...(overrides.decision ?? {}),
    },
    runtime: {
      ...base.runtime,
      ...(overrides.runtime ?? {}),
    },
    compaction: {
      ...base.compaction,
      ...(overrides.compaction ?? {}),
    },
    measurement: {
      ...base.measurement,
      ...(overrides.measurement ?? {}),
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
      observation({ ts: 2, phase: 'Compacting', turn: 'executing' }),
      observation({ ts: 3, phase: 'Compacting', turn: 'executing', runtime: 'trying' }),
    ]

    expect(deriveTransitionHistory(observations)).toEqual([
      { ts: 3, from: 'idle', to: 'trying', field: 'KCL' },
      { ts: 2, from: 'idle', to: 'executing', field: 'KTC' },
      { ts: 2, from: 'Running', to: 'Compacting', field: 'KSM' },
    ])
  })

  it('counts the most frequent (from → to) transitions per lane', () => {
    const observations = [
      observation({ ts: 1, turn: 'idle' }),
      observation({ ts: 2, turn: 'prompting' }),
      observation({ ts: 3, turn: 'idle' }),
      observation({ ts: 4, turn: 'prompting' }),
      observation({ ts: 5, turn: 'executing' }),
      observation({ ts: 6, phase: 'Compacting', turn: 'compacting' }),
    ]

    const top = deriveTopTransitions(observations, 5)

    expect(top[0]).toEqual({
      field: 'KTC',
      from: 'idle',
      to: 'prompting',
      count: 2,
    })
    expect(top.find((t) => t.from === 'Running' && t.to === 'Compacting'))
      .toEqual({ field: 'KSM', from: 'Running', to: 'Compacting', count: 1 })
    expect(top.length).toBeLessThanOrEqual(5)
  })

  it('returns an empty list when no transitions occurred', () => {
    expect(deriveTopTransitions([observation()])).toEqual([])
    expect(deriveTopTransitions([])).toEqual([])
  })

  it('respects the limit parameter and breaks ties by lane order then alpha', () => {
    const observations = [
      observation({ ts: 1, phase: 'Running', turn: 'idle', decision: 'undecided' }),
      observation({ ts: 2, phase: 'Compacting', turn: 'prompting', decision: 'guard_ok' }),
    ]

    const limited = deriveTopTransitions(observations, 2)
    expect(limited).toHaveLength(2)
    expect(limited.map((t) => t.field)).toEqual(['KSM', 'KTC'])
  })

  it('keeps only distinct consecutive phases in the phase log', () => {
    const observations = [
      observation({ ts: 1, phase: 'Running' }),
      observation({ ts: 2, phase: 'Running', turn: 'executing' }),
      observation({ ts: 3, phase: 'Failing' }),
      observation({ ts: 4, phase: 'Failing', runtime: 'trying' }),
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
          no_runtime_before_measurement: true,
          compaction_atomicity: true,
          event_priority_monotone: true,
          phase_derivation_agreement: true,
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
          decision_stage: 'guard_ok',
          runtime_state: 'done',
          selected_model: null,
        },
      }),
      [observation({ ts: 75 })],
      100,
    )

    expect(result.tone).toBe('ok')
    expect(result.headline).toContain('대기 상태 정상')
    expect(result.detail).toContain('25s')
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
    expect(result.headline).toContain('Compaction 가 현재 턴 소유')
  })
})

describe('inferTransitionReason', () => {
  it('attributes KTC idle→executing to runtime call start', () => {
    expect(inferTransitionReason('KTC', 'idle', 'executing'))
      .toBe('턴이 시작되었습니다 — runtime 호출 진행')
  })

  it('attributes KCL idle→trying to runtime call', () => {
    expect(inferTransitionReason('KCL', 'idle', 'trying'))
      .toMatch(/runtime/)
  })

  it('returns null for unattributable transitions', () => {
    expect(inferTransitionReason('KTC', 'unknown_a', 'unknown_b')).toBeNull()
    expect(inferTransitionReason('UNKNOWN', 'a', 'b')).toBeNull()
  })
})

describe('deriveLaneDwellHistograms', () => {
  it('aggregates dwell time per state per lane', () => {
    const observations = [
      observation({ ts: 100, phase: 'Running', turn: 'idle' }),
      observation({ ts: 110, phase: 'Running', turn: 'executing' }),
      observation({ ts: 130, phase: 'Compacting', turn: 'compacting' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 150)

    const ksm = histograms.find((h) => h.field === 'KSM')
    expect(ksm).toBeDefined()
    expect(ksm!.entries).toHaveLength(2)
    expect(ksm!.entries[0]).toEqual({ value: 'Running', seconds: 30, pct: 60 })
    expect(ksm!.entries[1]).toEqual({ value: 'Compacting', seconds: 20, pct: 40 })

    const ktc = histograms.find((h) => h.field === 'KTC')
    expect(ktc).toBeDefined()
    const idleDwell = ktc!.entries.find((e) => e.value === 'idle')
    expect(idleDwell?.seconds).toBe(10)
    const execDwell = ktc!.entries.find((e) => e.value === 'executing')
    expect(execDwell?.seconds).toBe(20)
  })

  it('returns empty array for no observations', () => {
    expect(deriveLaneDwellHistograms([], 100)).toEqual([])
  })

  it('extends trailing segment to boundsEnd (current state gets live dwell)', () => {
    const observations = [
      observation({ ts: 100, phase: 'Running' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 200)
    const ksm = histograms.find((h) => h.field === 'KSM')
    expect(ksm!.entries[0]).toEqual({
      value: 'Running',
      seconds: 100,
      pct: 100,
    })
  })

  it('pct sums to 100 for each lane', () => {
    const observations = [
      observation({ ts: 10, runtime: 'idle' }),
      observation({ ts: 30, runtime: 'trying' }),
      observation({ ts: 50, runtime: 'idle' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 60)
    const kcl = histograms.find((h) => h.field === 'KCL')
    const totalPct = kcl!.entries.reduce((sum, e) => sum + e.pct, 0)
    expect(totalPct).toBeCloseTo(100, 5)
  })
})

describe('deriveStateEntries', () => {
  it('returns null for empty observations', () => {
    expect(deriveStateEntries([])).toBeNull()
  })

  it('falls back to first observation ts when no transitions', () => {
    const observations = [
      observation({ ts: 100, phase: 'Running', turn: 'idle', decision: 'undecided', runtime: 'idle', compaction: 'accumulating' }),
      observation({ ts: 105, phase: 'Running', turn: 'idle', decision: 'undecided', runtime: 'idle', compaction: 'accumulating' }),
      observation({ ts: 110, phase: 'Running', turn: 'idle', decision: 'undecided', runtime: 'idle', compaction: 'accumulating' }),
    ]
    const entries = deriveStateEntries(observations)
    expect(entries).toEqual({ phase: 100, turn: 100, decision: 100, runtime: 100, compaction: 100 })
  })

  it('returns the ts of the latest transition per lane', () => {
    const observations = [
      observation({ ts: 100, phase: 'Running', turn: 'idle', decision: 'undecided', runtime: 'idle', compaction: 'accumulating' }),
      observation({ ts: 110, phase: 'Running', turn: 'prompting', decision: 'undecided', runtime: 'idle', compaction: 'accumulating' }),
      observation({ ts: 120, phase: 'Running', turn: 'executing', decision: 'guard_ok', runtime: 'selecting', compaction: 'accumulating' }),
      observation({ ts: 130, phase: 'Compacting', turn: 'executing', decision: 'guard_ok', runtime: 'done', compaction: 'accumulating' }),
    ]
    const entries = deriveStateEntries(observations)
    expect(entries).toEqual({
      phase: 130,
      turn: 120,
      decision: 120,
      runtime: 130,
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

describe('deriveTimeAxisTicks', () => {
  it('returns no ticks for a zero-width span', () => {
    expect(deriveTimeAxisTicks(100, 100)).toEqual([])
  })

  it('returns ticks aligned to round clock moments', () => {
    // 30s window, step should round up to 10s, firstTick = 110
    const ticks = deriveTimeAxisTicks(103, 133)
    expect(ticks.map(t => t.ts)).toEqual([110, 120, 130])
    for (const tick of ticks) {
      expect(tick.label).toMatch(/\d{2}:\d{2}:\d{2}/)
    }
  })

  it('chooses a minute-scale step for long windows', () => {
    // 15 min window, step should be 300s (5 min)
    const ticks = deriveTimeAxisTicks(1_700_000_000, 1_700_000_900)
    expect(ticks.length).toBeGreaterThanOrEqual(2)
    expect(ticks.length).toBeLessThanOrEqual(6)
    const gaps = ticks.slice(1).map((t, i) => t.ts - (ticks[i]?.ts ?? 0))
    for (const gap of gaps) {
      expect(gap).toBeGreaterThanOrEqual(60)
    }
  })

  it('respects the maxTicks cap', () => {
    const ticks = deriveTimeAxisTicks(0, 3600, 3)
    expect(ticks.length).toBeLessThanOrEqual(3)
  })

  it('emits no ticks strictly-less-than spanStart', () => {
    const ticks = deriveTimeAxisTicks(100, 200)
    for (const tick of ticks) {
      expect(tick.ts).toBeGreaterThan(100)
      expect(tick.ts).toBeLessThanOrEqual(200)
    }
  })
})

describe('isTransitionInSegment', () => {
  const segKSM: HoveredSegment = { field: 'KSM', laneKey: 'phase', from: 100, to: 200, value: 'Running' }

  it('returns false when no segment is hovered', () => {
    expect(isTransitionInSegment({ ts: 150, field: 'KSM' }, null)).toBe(false)
  })

  it('returns false when fields disagree', () => {
    expect(isTransitionInSegment({ ts: 150, field: 'KTC' }, segKSM)).toBe(false)
  })

  it('includes the segment start and end inclusively', () => {
    expect(isTransitionInSegment({ ts: 100, field: 'KSM' }, segKSM)).toBe(true)
    expect(isTransitionInSegment({ ts: 200, field: 'KSM' }, segKSM)).toBe(true)
  })

  it('excludes ts outside the segment window', () => {
    expect(isTransitionInSegment({ ts: 99, field: 'KSM' }, segKSM)).toBe(false)
    expect(isTransitionInSegment({ ts: 201, field: 'KSM' }, segKSM)).toBe(false)
  })

  it('returns true for a field+ts that overlap the hovered segment', () => {
    expect(isTransitionInSegment({ ts: 150, field: 'KSM' }, segKSM)).toBe(true)
  })

  it('enables findIndex-based first-match lookup used by TransitionTrail auto-scroll', () => {
    const history = [
      { ts: 180, from: 'a', to: 'b', field: 'KSM' },
      { ts: 150, from: 'a', to: 'b', field: 'KSM' },
      { ts: 120, from: 'a', to: 'b', field: 'KTC' },
    ]
    const index = history.findIndex(e => isTransitionInSegment(e, segKSM))
    expect(index).toBe(0)
  })

  it('returns -1 via findIndex when the hovered segment field has no matches', () => {
    const history = [
      { ts: 180, from: 'a', to: 'b', field: 'KCL' },
      { ts: 150, from: 'a', to: 'b', field: 'KDP' },
    ]
    const index = history.findIndex(e => isTransitionInSegment(e, segKSM))
    expect(index).toBe(-1)
  })
})

describe('laneTransitionCount', () => {
  it('returns zero when the lane never changed', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 110, turn: 'idle' }),
      observation({ ts: 120, turn: 'idle' }),
    ]
    expect(laneTransitionCount(observations, 'turn')).toBe(0)
  })

  it('counts each value change between adjacent observations', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle' }),
      observation({ ts: 110, turn: 'prompting' }),
      observation({ ts: 120, turn: 'executing' }),
      observation({ ts: 130, turn: 'executing' }),
      observation({ ts: 140, turn: 'idle' }),
    ]
    expect(laneTransitionCount(observations, 'turn')).toBe(3)
  })

  it('is lane-independent — different lanes count independently', () => {
    const observations = [
      observation({ ts: 100, turn: 'idle', phase: 'Running' }),
      observation({ ts: 110, turn: 'prompting', phase: 'Running' }),
      observation({ ts: 120, turn: 'prompting', phase: 'Compacting' }),
    ]
    expect(laneTransitionCount(observations, 'turn')).toBe(1)
    expect(laneTransitionCount(observations, 'phase')).toBe(1)
    expect(laneTransitionCount(observations, 'decision')).toBe(0)
  })
})

describe('flagTooltip', () => {
  it('returns the on-description when the flag is active', () => {
    const tip = flagTooltip('compact', true)
    expect(tip).toContain('compact (active)')
    expect(tip).toContain('압축')
  })

  it('returns the off-description when the flag is inactive', () => {
    const tip = flagTooltip('compact', false)
    expect(tip).toContain('compact (inactive)')
    expect(tip).toContain('예약된 압축 없음')
  })

  it('falls back to a generic tooltip for unknown labels', () => {
    expect(flagTooltip('mystery-flag', true)).toBe('mystery-flag: active')
    expect(flagTooltip('mystery-flag', false)).toBe('mystery-flag: inactive')
  })
})

describe('invariantDescription', () => {
  it('returns domain-specific prose for each known invariant key', () => {
    const keys = [
      'phase_turn_alignment',
      'no_runtime_before_measurement',
      'compaction_atomicity',
      'event_priority_monotone',
    ]
    for (const key of keys) {
      const desc = invariantDescription(key)
      expect(desc.length).toBeGreaterThan(40)
      expect(desc).not.toMatch(/composite contract/)
    }
  })

  it('mentions the specific contract each invariant guards', () => {
    expect(invariantDescription('phase_turn_alignment')).toMatch(/KSM|KTC|drift/i)
    expect(invariantDescription('no_runtime_before_measurement')).toMatch(/runtime|measurement/i)
    expect(invariantDescription('compaction_atomicity')).toMatch(/atomic|half-compacted/i)
    expect(invariantDescription('event_priority_monotone')).toMatch(/priority|priorit/i)
  })

  it('falls back to generic text for unknown keys', () => {
    expect(invariantDescription('mystery_invariant')).toMatch(/composite contract/)
  })
})

describe('filterKeeperNames', () => {
  const fleet: readonly string[] = [
    'keeper-planner-agent',
    'keeper-critic-agent',
    'keeper-router-agent',
    'keeper-research-agent',
    'gate-keeper',
  ]

  it('returns the same reference when query is empty', () => {
    expect(filterKeeperNames(fleet, '')).toBe(fleet)
  })

  it('returns the same reference when query is whitespace only', () => {
    expect(filterKeeperNames(fleet, '   ')).toBe(fleet)
  })

  it('performs case-insensitive substring match', () => {
    expect(filterKeeperNames(fleet, 'PLAN')).toEqual(['keeper-planner-agent'])
    expect(filterKeeperNames(fleet, 'Critic')).toEqual(['keeper-critic-agent'])
  })

  it('matches multiple rows on a shared substring', () => {
    const out = filterKeeperNames(fleet, 'keeper-')
    expect(out).toHaveLength(4)
    expect(out).toContain('keeper-planner-agent')
    expect(out).not.toContain('gate-keeper')
  })

  it('matches substring that does not anchor on prefix', () => {
    expect(filterKeeperNames(fleet, 'research')).toEqual(['keeper-research-agent'])
    expect(filterKeeperNames(fleet, 'gate')).toEqual(['gate-keeper'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterKeeperNames(fleet, 'xyz-no-such-keeper')).toEqual([])
  })

  it('trims surrounding whitespace from the query', () => {
    expect(filterKeeperNames(fleet, '  router  ')).toEqual(['keeper-router-agent'])
  })

  it('preserves input order of surviving rows', () => {
    const out = filterKeeperNames(fleet, 'agent')
    expect(out).toEqual([
      'keeper-planner-agent',
      'keeper-critic-agent',
      'keeper-router-agent',
      'keeper-research-agent',
    ])
  })

  it('does not mutate the input array', () => {
    const input = [...fleet]
    const snapshot = [...input]
    filterKeeperNames(input, 'critic')
    expect(input).toEqual(snapshot)
  })

  it('returns input reference unchanged for empty query even when input is empty', () => {
    const empty: readonly string[] = []
    expect(filterKeeperNames(empty, '')).toBe(empty)
    expect(filterKeeperNames(empty, 'anything')).toEqual([])
  })
})
