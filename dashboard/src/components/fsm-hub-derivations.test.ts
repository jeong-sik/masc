import { describe, it, expect } from 'vitest'
import type { CompositeObservation } from './fsm-hub-types'

import {
  appendCompositeObservation,
  deriveTransitionHistory,
  deriveTopTransitions,
  inferTransitionReason,
  derivePhaseLog,
  laneChangedAt,
  laneTransitionCount,
  deriveStateEntries,
  deriveTimeAxisTicks,
  deriveSwimlaneSegments,
  deriveLaneDwellHistograms,
} from './fsm-hub-derivations'

// --- Helpers ---

function obs(overrides: Partial<CompositeObservation> & { ts: number }): CompositeObservation {
  return {
    phase: 'Stable',
    turn: 'idle',
    decision: 'undecided',
    cascade: 'idle',
    compaction: 'accumulating',
    ...overrides,
  }
}

// --- Tests ---

describe('appendCompositeObservation', () => {
  it('appends to empty observations', () => {
    const next = obs({ ts: 100 })
    const result = appendCompositeObservation([], next)
    expect(result).toEqual([next])
  })

  it('appends when last observation differs', () => {
    const a = obs({ ts: 100, phase: 'Stable' })
    const b = obs({ ts: 200, phase: 'Running' })
    const result = appendCompositeObservation([a], b)
    expect(result).toEqual([a, b])
  })

  it('deduplicates identical consecutive observations', () => {
    const a = obs({ ts: 100 })
    const b = obs({ ts: 200 }) // same values, different ts
    const result = appendCompositeObservation([a], b)
    expect(result).toEqual([a]) // b is dropped
  })

  it('trims to maxEntries', () => {
    const phases = ['Stable', 'Running', 'Compacting', 'HandingOff', 'Failing', 'Draining', 'Overflowed'] as const
    const observations = Array.from({ length: 30 }, (_, i) => obs({ ts: i, phase: phases[i % phases.length]! }))
    const extra = obs({ ts: 100, phase: 'Failing' })
    const result = appendCompositeObservation(observations, extra, 10)
    expect(result).toHaveLength(10)
    expect(result[result.length - 1]!.phase).toBe('Failing')
  })
})

describe('deriveTransitionHistory', () => {
  it('returns empty for single observation', () => {
    expect(deriveTransitionHistory([obs({ ts: 100 })])).toEqual([])
  })

  it('detects phase transition', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
    ]
    const result = deriveTransitionHistory(observations)
    expect(result).toHaveLength(1)
    expect(result[0]!.field).toBe('KSM')
    expect(result[0]!.from).toBe('Stable')
    expect(result[0]!.to).toBe('Running')
    expect(result[0]!.ts).toBe(200)
  })

  it('detects multiple field transitions in one step', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable', turn: 'idle' }),
      obs({ ts: 200, phase: 'Running', turn: 'executing' }),
    ]
    const result = deriveTransitionHistory(observations)
    expect(result).toHaveLength(2)
  })

  it('skips unchanged fields', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable', turn: 'idle' }),
      obs({ ts: 200, phase: 'Running', turn: 'idle' }),
    ]
    const result = deriveTransitionHistory(observations)
    expect(result).toHaveLength(1)
    expect(result[0]!.field).toBe('KSM')
  })

  it('returns most recent first (reversed)', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
      obs({ ts: 300, phase: 'Failing' }),
    ]
    const result = deriveTransitionHistory(observations)
    expect(result).toHaveLength(2)
    expect(result[0]!.to).toBe('Failing')
    expect(result[1]!.to).toBe('Running')
  })

  it('trims to maxEntries', () => {
    const phases = ['Stable', 'Running', 'Compacting', 'HandingOff', 'Failing'] as const
    const observations: CompositeObservation[] = []
    for (let i = 0; i < 50; i++) {
      observations.push(obs({ ts: i * 10, phase: phases[i % phases.length]! }))
    }
    const result = deriveTransitionHistory(observations, 5)
    expect(result).toHaveLength(5)
  })
})

describe('deriveTopTransitions', () => {
  it('returns empty for insufficient observations', () => {
    expect(deriveTopTransitions([obs({ ts: 100 })])).toEqual([])
    expect(deriveTopTransitions([])).toEqual([])
  })

  it('counts repeated transitions', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
      obs({ ts: 300, phase: 'Stable' }),
      obs({ ts: 400, phase: 'Running' }),
      obs({ ts: 500, phase: 'Stable' }),
    ]
    const result = deriveTopTransitions(observations, 10)
    const stableToRunning = result.find(t => t.from === 'Stable' && t.to === 'Running')
    expect(stableToRunning!.count).toBe(2)
  })

  it('sorts by count descending', () => {
    const observations = [
      obs({ ts: 100, turn: 'idle' }),
      obs({ ts: 200, turn: 'executing' }),
      obs({ ts: 300, turn: 'idle' }),
      obs({ ts: 400, phase: 'Running' }),
    ]
    const result = deriveTopTransitions(observations, 10)
    expect(result.length).toBeGreaterThanOrEqual(1)
    if (result.length > 1) {
      expect(result[0]!.count).toBeGreaterThanOrEqual(result[1]!.count)
    }
  })

  it('respects limit', () => {
    const phases = ['Stable', 'Running', 'Compacting'] as const
    const observations: CompositeObservation[] = []
    for (let i = 0; i < 20; i++) {
      observations.push(obs({ ts: i * 10, phase: phases[i % 3]! }))
    }
    const result = deriveTopTransitions(observations, 3)
    expect(result.length).toBeLessThanOrEqual(3)
  })
})

describe('inferTransitionReason', () => {
  it('returns Korean reason for KTC idle→executing', () => {
    const result = inferTransitionReason('KTC', 'idle', 'executing')
    expect(result).toBeTruthy()
    expect(result).toContain('턴')
  })

  it('returns Korean reason for KTC executing→idle', () => {
    const result = inferTransitionReason('KTC', 'executing', 'idle')
    expect(result).toContain('정상 종료')
  })

  it('returns Korean reason for KSM to Crashed', () => {
    const result = inferTransitionReason('KSM', 'Failing', 'Crashed')
    expect(result).toContain('비정상 종료')
  })

  it('returns Korean reason for KDP to gate_rejected', () => {
    const result = inferTransitionReason('KDP', 'undecided', 'gate_rejected')
    expect(result).toContain('게이트 차단')
  })

  it('returns Korean reason for KCL to exhausted', () => {
    const result = inferTransitionReason('KCL', 'trying', 'exhausted')
    expect(result).toContain('소진')
  })

  it('returns Korean reason for KMC compacting→accumulating', () => {
    const result = inferTransitionReason('KMC', 'compacting', 'accumulating')
    expect(result).toContain('압축 완료')
  })

  it('returns null for unknown field', () => {
    expect(inferTransitionReason('UNKNOWN', 'a', 'b')).toBeNull()
  })

  it('returns null for unhandled transition within known field', () => {
    expect(inferTransitionReason('KTC', 'compacting', 'idle')).toBeNull()
  })

  it('returns reason for KTC to compacting', () => {
    const result = inferTransitionReason('KTC', 'executing', 'compacting')
    expect(result).toContain('compaction')
  })

  it('returns reason for KSM to HandingOff', () => {
    const result = inferTransitionReason('KSM', 'Running', 'HandingOff')
    expect(result).toContain('인계')
  })
})

describe('derivePhaseLog', () => {
  it('returns empty for no observations', () => {
    expect(derivePhaseLog([])).toEqual([])
  })

  it('returns single phase for identical observations', () => {
    const observations = [obs({ ts: 100 }), obs({ ts: 200 })]
    expect(derivePhaseLog(observations)).toEqual(['Stable'])
  })

  it('deduplicates consecutive identical phases', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Stable' }),
      obs({ ts: 300, phase: 'Running' }),
      obs({ ts: 400, phase: 'Running' }),
      obs({ ts: 500, phase: 'Failing' }),
    ]
    expect(derivePhaseLog(observations)).toEqual(['Stable', 'Running', 'Failing'])
  })

  it('trims to maxEntries', () => {
    const phases = ['Stable', 'Running', 'Compacting', 'HandingOff', 'Failing'] as const
    const observations: CompositeObservation[] = []
    for (let i = 0; i < 50; i++) {
      observations.push(obs({ ts: i * 10, phase: phases[i % phases.length]! }))
    }
    const result = derivePhaseLog(observations, 10)
    expect(result).toHaveLength(10)
  })
})

describe('laneChangedAt', () => {
  it('returns 0 for empty observations', () => {
    expect(laneChangedAt([], 'phase')).toBe(0)
  })

  it('returns first ts when lane never changed', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Stable' }),
    ]
    expect(laneChangedAt(observations, 'phase')).toBe(100)
  })

  it('returns timestamp of last change', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
      obs({ ts: 300, phase: 'Running' }),
    ]
    expect(laneChangedAt(observations, 'phase')).toBe(200)
  })

  it('tracks turn lane independently', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable', turn: 'idle' }),
      obs({ ts: 200, phase: 'Running', turn: 'idle' }),
      obs({ ts: 300, phase: 'Running', turn: 'executing' }),
    ]
    expect(laneChangedAt(observations, 'phase')).toBe(200)
    expect(laneChangedAt(observations, 'turn')).toBe(300)
  })
})

describe('laneTransitionCount', () => {
  it('returns 0 for empty observations', () => {
    expect(laneTransitionCount([], 'phase')).toBe(0)
  })

  it('returns 0 for single observation', () => {
    expect(laneTransitionCount([obs({ ts: 100 })], 'phase')).toBe(0)
  })

  it('counts transitions correctly', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
      obs({ ts: 300, phase: 'Stable' }),
      obs({ ts: 400, phase: 'Running' }),
    ]
    expect(laneTransitionCount(observations, 'phase')).toBe(3)
  })

  it('ignores unchanged fields', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable', turn: 'idle' }),
      obs({ ts: 200, phase: 'Running', turn: 'idle' }),
    ]
    expect(laneTransitionCount(observations, 'phase')).toBe(1)
    expect(laneTransitionCount(observations, 'turn')).toBe(0)
  })
})

describe('deriveStateEntries', () => {
  it('returns null for empty observations', () => {
    expect(deriveStateEntries([])).toBeNull()
  })

  it('returns first ts for all lanes when no changes', () => {
    const observations = [
      obs({ ts: 100 }),
      obs({ ts: 200 }),
    ]
    const result = deriveStateEntries(observations)
    expect(result!.phase).toBe(100)
    expect(result!.turn).toBe(100)
  })

  it('detects last transition timestamp per lane', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable', turn: 'idle' }),
      obs({ ts: 200, phase: 'Running', turn: 'idle' }),
      obs({ ts: 300, phase: 'Running', turn: 'executing' }),
    ]
    const result = deriveStateEntries(observations)
    expect(result!.phase).toBe(200)
    expect(result!.turn).toBe(300)
  })

  it('handles all 5 lanes', () => {
    const observations = [
      obs({ ts: 100 }),
      obs({ ts: 200, phase: 'Running', turn: 'executing', decision: 'guard_ok', cascade: 'trying', compaction: 'compacting' }),
    ]
    const result = deriveStateEntries(observations)
    expect(result!.phase).toBe(200)
    expect(result!.turn).toBe(200)
    expect(result!.decision).toBe(200)
    expect(result!.cascade).toBe(200)
    expect(result!.compaction).toBe(200)
  })
})

describe('deriveTimeAxisTicks', () => {
  it('returns empty for zero span', () => {
    expect(deriveTimeAxisTicks(100, 100)).toEqual([])
  })

  it('returns empty for negative span', () => {
    expect(deriveTimeAxisTicks(200, 100)).toEqual([])
  })

  it('returns empty for maxTicks < 2', () => {
    expect(deriveTimeAxisTicks(100, 200, 1)).toEqual([])
  })

  it('generates ticks within span', () => {
    const ticks = deriveTimeAxisTicks(0, 3600, 6) // 1 hour span
    expect(ticks.length).toBeGreaterThanOrEqual(1)
    expect(ticks.length).toBeLessThanOrEqual(6)
    for (const tick of ticks) {
      expect(tick.ts).toBeGreaterThan(0)
      expect(tick.ts).toBeLessThanOrEqual(3600)
      expect(tick.label).toBeTruthy()
    }
  })

  it('formats seconds for sub-minute steps', () => {
    const ticks = deriveTimeAxisTicks(0, 30, 4) // 30 second span
    expect(ticks.length).toBeGreaterThanOrEqual(1)
    // With step < 60, labels should include seconds
    expect(ticks[0]!.label).toContain(':')
  })

  it('formats HH:MM for larger steps', () => {
    const ticks = deriveTimeAxisTicks(0, 86400, 6) // 1 day span
    expect(ticks.length).toBeGreaterThanOrEqual(1)
    expect(ticks[0]!.label).toBeTruthy()
  })
})

describe('deriveSwimlaneSegments', () => {
  it('returns empty for no observations', () => {
    expect(deriveSwimlaneSegments([], 'phase', 100)).toEqual([])
  })

  it('creates single segment for constant lane', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Stable' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'phase', 300)
    expect(segments).toHaveLength(1)
    expect(segments[0]!.value).toBe('Stable')
    expect(segments[0]!.from).toBe(100)
    expect(segments[0]!.to).toBe(300) // extended to boundsEnd
  })

  it('splits on lane change', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
      obs({ ts: 300, phase: 'Running' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'phase', 400)
    expect(segments).toHaveLength(2)
    expect(segments[0]!.value).toBe('Stable')
    expect(segments[0]!.from).toBe(100)
    expect(segments[0]!.to).toBe(200)
    expect(segments[1]!.value).toBe('Running')
    expect(segments[1]!.to).toBe(400) // extended to boundsEnd
  })

  it('extends last segment to boundsEnd', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'phase', 500)
    const last = segments[segments.length - 1]!
    expect(last.to).toBe(500)
  })

  it('does not extend beyond boundsEnd', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
    ]
    const segments = deriveSwimlaneSegments(observations, 'phase', 150)
    // boundsEnd < last segment's to, so no extension
    expect(segments).toHaveLength(2)
  })
})

describe('deriveLaneDwellHistograms', () => {
  it('returns empty for no observations', () => {
    expect(deriveLaneDwellHistograms([], 100)).toEqual([])
  })

  it('computes dwell time for constant lane', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Stable' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 300)
    const phaseLane = histograms.find(h => h.field === 'KSM')
    expect(phaseLane).toBeTruthy()
    expect(phaseLane!.entries).toHaveLength(1)
    expect(phaseLane!.entries[0]!.value).toBe('Stable')
    expect(phaseLane!.entries[0]!.seconds).toBe(200) // 300-100
    expect(phaseLane!.entries[0]!.pct).toBe(100)
  })

  it('splits dwell across changed values', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 200, phase: 'Running' }),
      obs({ ts: 300, phase: 'Stable' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 400)
    const phaseLane = histograms.find(h => h.field === 'KSM')
    expect(phaseLane).toBeTruthy()
    // Stable: 100-200 + 300-400 = 200s, Running: 200-300 = 100s
    const stableEntry = phaseLane!.entries.find(e => e.value === 'Stable')
    const runningEntry = phaseLane!.entries.find(e => e.value === 'Running')
    expect(stableEntry!.seconds).toBe(200)
    expect(runningEntry!.seconds).toBe(100)
  })

  it('sorts entries by seconds descending', () => {
    const observations = [
      obs({ ts: 100, phase: 'Stable' }),
      obs({ ts: 150, phase: 'Running' }),
      obs({ ts: 400, phase: 'Stable' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 500)
    const phaseLane = histograms.find(h => h.field === 'KSM')
    expect(phaseLane!.entries[0]!.seconds).toBeGreaterThanOrEqual(
      phaseLane!.entries[1]!.seconds,
    )
  })

  it('returns lanes in TRANSITION_FIELDS order', () => {
    const observations = [
      obs({ ts: 100 }),
      obs({ ts: 200, phase: 'Running', turn: 'executing', decision: 'guard_ok' }),
    ]
    const histograms = deriveLaneDwellHistograms(observations, 300)
    const fields = histograms.map(h => h.field)
    expect(fields).toContain('KSM')
    expect(fields).toContain('KTC')
    expect(fields).toContain('KDP')
  })
})
