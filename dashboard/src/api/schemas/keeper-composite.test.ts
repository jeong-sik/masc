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
    phase_derivation_agreement: true,
  },
  is_live: true,
  last_outcome: null,
}

describe('parseKeeperCompositeSnapshot', () => {
  it('parses a valid snapshot', () => {
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.phase).toBe('Stable')
    expect(result.collapsed_from).toBeUndefined()
    expect(result.turn_phase).toBe('idle')
    expect(result.is_live).toBe(true)
    expect(result.last_outcome).toBeNull()
    expect(result.recommended_actions).toEqual([])
  })

  it('parses explicit keeper identity when emitted by the backend', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      keeper: 'analyst',
    })
    expect(result.keeper).toBe('analyst')
  })

  it('parses all valid phase values', () => {
    for (const phase of ['Running', 'Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Stable']) {
      const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, phase })
      expect(result.phase).toBe(phase)
    }
  })

  it('preserves unknown phase values for operator visibility', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, phase: 'UnknownPhase' })
    expect(result.phase).toBe('UnknownPhase')
  })

  it('preserves unknown turn_phase values for operator visibility', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, turn_phase: 'unknown' })
    expect(result.turn_phase).toBe('unknown')
  })

  it('preserves unknown decision stage values for operator visibility', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, decision: { stage: 'mystery' } })
    expect(result.decision.stage).toBe('mystery')
  })

  it('preserves unknown cascade state values for operator visibility', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, cascade: { state: 'wat' } })
    expect(result.cascade.state).toBe('wat')
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

  it('parses optional execution receipt summary', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      execution: {
        latest_receipt_present: true,
        recorded_at: '2026-04-25T05:07:00Z',
        outcome: 'error',
        terminal_reason_code: 'config_error',
        operator_disposition: 'pause_human',
        operator_disposition_reason: 'tool_required_unsatisfied',
        model_used: 'claude_code:auto',
        stop_reason: 'max_turns',
        tool_contract_result: 'violated',
        duration_ms: 87736,
        error: {
          kind: 'config',
          message_preview: 'unknown field fallback_cascade',
          message_truncated: false,
        },
        cascade: {
          name: 'big_three',
          selected_model: 'claude_code:auto',
          attempt_count: 2,
          fallback_applied: true,
          outcome: 'exhausted',
          degraded_retry_applied: false,
          degraded_retry_cascade: null,
          fallback_reason: 'turn_timeout',
        },
        tool_surface: {
          tool_requirement: 'required',
          tool_gate_enabled: true,
          missing_required_tools: ['keeper_task_claim'],
          required_tools: ['keeper_task_claim'],
        },
      },
    })

    expect(result.execution?.latest_receipt_present).toBe(true)
    expect(result.execution?.terminal_reason_code).toBe('config_error')
    expect(result.execution?.cascade?.fallback_reason).toBe('turn_timeout')
    expect(result.execution?.error?.message_preview).toContain('fallback_cascade')
  })

  it('parses backend-recommended runtime actions', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      recommended_actions: [
        {
          action_type: 'keeper_recover',
          target_type: 'keeper',
          target_id: 'analyst',
          severity: 'bad',
          reason: 'Controlled keeper recovery for runtime stall: api_error',
          confirm_required: true,
          suggested_payload: {
            source: 'fleet_fsm',
            keeper: 'analyst',
          },
          preview: {
            actor: 'fleet_fsm',
            action_type: 'keeper_recover',
          },
        },
      ],
    })

    expect(result.recommended_actions).toHaveLength(1)
    expect(result.recommended_actions[0]!.action_type).toBe('keeper_recover')
    expect(result.recommended_actions[0]!.confirm_required).toBe(true)
  })

  it('parses backend runtime_attention', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      runtime_attention: {
        state: 'blocked',
        needs_attention: true,
        blocked: true,
        fiber_stop_requested: false,
        reason: 'passive_only',
        raw_phase: 'Running',
        is_live: false,
        source: 'execution_receipt',
      },
    })

    expect(result.runtime_attention?.state).toBe('blocked')
    expect(result.runtime_attention?.reason).toBe('passive_only')
    expect(result.runtime_attention?.fiber_stop_requested).toBe(false)
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

  it('parses collapsed_from when Stable hides a raw keeper phase', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      collapsed_from: 'paused',
    })
    expect(result.phase).toBe('Stable')
    expect(result.collapsed_from).toBe('paused')
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

  // LT-16-KCB Phase 3 — 6th axis parsing
  it('accepts snapshot with circuit_breaker.state = warning', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      circuit_breaker: { state: 'warning' },
    })
    expect(result.circuit_breaker).toBeDefined()
    expect(result.circuit_breaker!.state).toBe('warning')
  })

  it('preserves unknown circuit_breaker.state for operator visibility', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      circuit_breaker: { state: 'completely-new-future-variant' },
    })
    expect(result.circuit_breaker!.state).toBe('completely-new-future-variant')
  })

  it('tolerates missing circuit_breaker during Phase 2 → 3 rollout', () => {
    // Pinned backends that have not yet picked up LT-16-KCB Phase 2
    // emit snapshots without the key. The dashboard must keep
    // rendering instead of hard-failing the parse.
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.circuit_breaker).toBeUndefined()
  })
})
