import { describe, it, expect } from 'vitest'
import {
  extractLaneValue,
  displayState,
  fmtDuration,
  failureReasonLabel,
  STATE_DISPLAY_NAMES,
  LANE_LABELS,
  INVARIANT_LABELS,
  TRANSITION_FIELDS,
  MAX_OBSERVATIONS,
  MAX_TRANSITION_HISTORY,
  initialHubState,
} from './fsm-hub-types'
import type { KeeperCompositeSnapshot } from '../api/keeper'

// --- Helpers ---

function snapshot(overrides: Partial<KeeperCompositeSnapshot> = {}): KeeperCompositeSnapshot {
  return {
    correlation_id: 'test-corr',
    run_id: 'test-run',
    ts: 1000,
    phase: 'Stable',
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
    ...overrides,
  }
}

// --- Tests ---

describe('extractLaneValue', () => {
  it('extracts phase', () => {
    expect(extractLaneValue(snapshot({ phase: 'Running' }), 'phase')).toBe('Running')
  })

  it('extracts turn', () => {
    expect(extractLaneValue(snapshot({ turn_phase: 'executing' }), 'turn')).toBe('executing')
  })

  it('extracts decision', () => {
    expect(extractLaneValue(snapshot({ decision: { stage: 'guard_ok' } }), 'decision')).toBe('guard_ok')
  })

  it('extracts runtime', () => {
    expect(extractLaneValue(snapshot({ runtime: { state: 'trying' } }), 'runtime')).toBe('trying')
  })

  it('extracts compaction', () => {
    expect(extractLaneValue(snapshot({ compaction: { stage: 'compacting' } }), 'compaction')).toBe('compacting')
  })

  it('handles all valid phase values', () => {
    const phases: KeeperCompositeSnapshot['phase'][] = [
      'Running', 'Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Stable',
    ]
    for (const phase of phases) {
      expect(extractLaneValue(snapshot({ phase }), 'phase')).toBe(phase)
    }
  })

  it('handles all valid turn values', () => {
    const turns: KeeperCompositeSnapshot['turn_phase'][] = [
      'idle', 'prompting', 'routing', 'executing', 'compacting', 'finalizing', 'exhausted',
    ]
    for (const turn of turns) {
      expect(extractLaneValue(snapshot({ turn_phase: turn }), 'turn')).toBe(turn)
    }
  })
})

describe('displayState', () => {
  it('returns Korean label for known states', () => {
    expect(displayState('idle')).toBe('대기')
    expect(displayState('executing')).toBe('실행 중')
    expect(displayState('Crashed')).toBe('비정상 종료')
    expect(displayState('Paused')).toBe('일시정지')
    expect(displayState('paused')).toBe('일시정지')
    expect(displayState('crashed')).toBe('비정상 종료')
  })

  it('returns raw value for unknown states', () => {
    expect(displayState('unknown_state')).toBe('unknown_state')
  })

  it('covers all STATE_DISPLAY_NAMES keys', () => {
    for (const key of Object.keys(STATE_DISPLAY_NAMES)) {
      expect(displayState(key)).toBe(STATE_DISPLAY_NAMES[key])
    }
  })
})

describe('fmtDuration', () => {
  it('formats seconds under 60', () => {
    expect(fmtDuration(0)).toBe('0s')
    expect(fmtDuration(30)).toBe('30s')
    expect(fmtDuration(59)).toBe('59s')
  })

  it('formats minutes and seconds', () => {
    expect(fmtDuration(60)).toBe('1m 0s')
    expect(fmtDuration(90)).toBe('1m 30s')
    expect(fmtDuration(3599)).toBe('59m 59s')
  })

  it('formats hours and minutes', () => {
    expect(fmtDuration(3600)).toBe('1h 0m')
    expect(fmtDuration(3661)).toBe('1h 1m')
    expect(fmtDuration(86400)).toBe('24h 0m')
  })

  it('handles negative values', () => {
    expect(fmtDuration(-1)).toBe('0s')
    expect(fmtDuration(-100)).toBe('0s')
  })

  it('handles fractional seconds', () => {
    expect(fmtDuration(1.5)).toBe('1s')
    expect(fmtDuration(0.1)).toBe('0s')
  })
})

describe('constants', () => {
  it('TRANSITION_FIELDS has 5 entries', () => {
    expect(TRANSITION_FIELDS).toHaveLength(5)
    expect(TRANSITION_FIELDS.map(f => f.field)).toEqual(['KSM', 'KTC', 'KDP', 'KCL', 'KMC'])
  })

  it('LANE_LABELS has all 5 lanes', () => {
    const keys = Object.keys(LANE_LABELS)
    expect(keys).toEqual(['phase', 'turn', 'decision', 'runtime', 'compaction'])
  })

  it('INVARIANT_LABELS has all 5 invariants', () => {
    const keys = Object.keys(INVARIANT_LABELS)
    expect(keys).toHaveLength(5)
    expect(keys).toContain('phase_turn_alignment')
    expect(keys).toContain('compaction_atomicity')
    expect(keys).toContain('phase_derivation_agreement')
  })

  it('MAX_OBSERVATIONS and MAX_TRANSITION_HISTORY are positive', () => {
    expect(MAX_OBSERVATIONS).toBeGreaterThan(0)
    expect(MAX_TRANSITION_HISTORY).toBeGreaterThan(0)
  })
})

describe('failureReasonLabel', () => {
  it('maps known bases to Korean', () => {
    expect(failureReasonLabel('heartbeat_consecutive_failures')).toBe('하트비트 연속 실패')
    expect(failureReasonLabel('exception')).toBe('런타임 예외')
  })

  it('preserves parametric detail after the base', () => {
    expect(failureReasonLabel('heartbeat_consecutive_failures(3)')).toBe('하트비트 연속 실패(3)')
    expect(failureReasonLabel('provider_runtime_error(code:detail)')).toBe('런타임 호출 오류(code:detail)')
  })

  it('falls back to raw string for unknown bases', () => {
    expect(failureReasonLabel('mystery_failure')).toBe('mystery_failure')
    expect(failureReasonLabel('unknown(42)')).toBe('unknown(42)')
  })

  it('returns null for empty / null / undefined inputs', () => {
    expect(failureReasonLabel(null)).toBeNull()
    expect(failureReasonLabel(undefined)).toBeNull()
    expect(failureReasonLabel('')).toBeNull()
    expect(failureReasonLabel('   ')).toBeNull()
  })
})

describe('initialHubState', () => {
  it('has correct initial values', () => {
    expect(initialHubState.keeperName).toBeNull()
    expect(initialHubState.status.kind).toBe('idle')
    expect(initialHubState.observations).toEqual([])
    expect(initialHubState.invariantSampleCount).toBe(0)
  })

  it('has zero invariant violations', () => {
    const violations = initialHubState.invariantViolations
    for (const value of Object.values(violations)) {
      expect(value).toBe(0)
    }
  })
})
