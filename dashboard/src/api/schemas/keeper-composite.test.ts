import { describe, it, expect } from 'vitest'
import {
  parseKeeperCompositeSnapshot,
  CompositeSchemaDriftError,
} from './keeper-composite'

const VALID_SNAPSHOT = {
  correlation_id: 'corr-1',
  run_id: 'run-1',
  ts: 1713398400,
  phase: 'Stable',
  turn_phase: 'idle',
  decision: { stage: 'undecided' },
  cascade: { state: 'idle' },
  compaction: { stage: 'accumulating' },
  measurement: { captured: true },
  invariants: {
    phase_turn_alignment: true,
    no_cascade_before_measurement: true,
    compaction_atomicity: true,
    event_priority_monotone: true,
  },
  is_live: true,
  last_outcome: null,
}

describe('parseKeeperCompositeSnapshot', () => {
  it('parses a valid snapshot', () => {
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.phase).toBe('Stable')
    expect(result.turn_phase).toBe('idle')
    expect(result.is_live).toBe(true)
    expect(result.last_outcome).toBeNull()
  })

  it('parses all valid phase values', () => {
    for (const phase of ['Running', 'Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Stable']) {
      const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, phase })
      expect(result.phase).toBe(phase)
    }
  })

  it('falls back unknown phase to Stable', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, phase: 'UnknownPhase' })
    expect(result.phase).toBe('Stable')
  })

  it('falls back unknown turn_phase to idle', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, turn_phase: 'unknown' })
    expect(result.turn_phase).toBe('idle')
  })

  it('falls back unknown decision stage to undecided', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, decision: { stage: 'mystery' } })
    expect(result.decision.stage).toBe('undecided')
  })

  it('falls back unknown cascade state to idle', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, cascade: { state: 'wat' } })
    expect(result.cascade.state).toBe('idle')
  })

  it('parses snapshot with last_outcome present', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      last_outcome: {
        turn_id: 5,
        ended_at: 1713398500,
        decision_stage: 'guard_ok',
        cascade_state: 'done',
        selected_model: 'claude-sonnet',
      },
    })
    expect(result.last_outcome).not.toBeNull()
    expect(result.last_outcome!.turn_id).toBe(5)
    expect(result.last_outcome!.selected_model).toBe('claude-sonnet')
  })

  it('parses snapshot with measurement auto_rules', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      measurement: {
        captured: true,
        auto_rules: {
          reflect: true,
          plan: false,
          compact: true,
          handoff: false,
          guardrail_stop: false,
          guardrail_reason: null,
          goal_drift: 0.1,
        },
      },
    })
    expect(result.measurement.auto_rules).toBeDefined()
    expect(result.measurement.auto_rules!.reflect).toBe(true)
    expect(result.measurement.auto_rules!.goal_drift).toBe(0.1)
  })

  it('throws CompositeSchemaDriftError for missing required field', () => {
    const { correlation_id: _, ...noCorr } = VALID_SNAPSHOT
    expect(() => parseKeeperCompositeSnapshot(noCorr)).toThrow(CompositeSchemaDriftError)
  })

  it('throws CompositeSchemaDriftError for non-object input', () => {
    expect(() => parseKeeperCompositeSnapshot('string')).toThrow(CompositeSchemaDriftError)
    expect(() => parseKeeperCompositeSnapshot(null)).toThrow(CompositeSchemaDriftError)
  })

  it('CompositeSchemaDriftError has issues array', () => {
    try {
      parseKeeperCompositeSnapshot({})
    } catch (e) {
      expect(e).toBeInstanceOf(CompositeSchemaDriftError)
      expect((e as CompositeSchemaDriftError).issues.length).toBeGreaterThan(0)
      expect((e as CompositeSchemaDriftError).message).toContain('schema drift')
    }
  })
})
