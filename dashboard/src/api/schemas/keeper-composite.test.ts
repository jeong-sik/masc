import { describe, it, expect } from 'vitest'
import {
  parseKeeperCompositeSnapshot,
  CompositeSchemaDriftError,
} from './keeper-composite'

// Minimal snapshot carrying every required key of
// `KeeperCompositeSnapshotSchema`. Optional keys (keeper, collapsed_from,
// phase_diagnosis, execution, runtime_attention,
// recommended_actions) are added per-test. Value shapes here mirror what
// `keeper_composite_observer.ml` `snapshot_to_json` emits: lowercase
// snake_case phase / turn_phase / decision / runtime / compaction (via
// `Keeper_state_machine.phase_to_string` etc.). Capitalized variants
// like `"Stable"` are forward-looking — they appear only in schema-
// permissiveness tests below, never in real backend payloads today.
const VALID_SNAPSHOT = {
  correlation_id: 'corr-1',
  run_id: 'run-1',
  ts: 1713398400,
  phase: 'running',
  turn_phase: 'idle',
  decision: { stage: 'undecided' },
  runtime: { state: 'idle' },
  compaction: { stage: 'accumulating' },
  measurement: { captured: true },
  invariants: {
    phase_turn_alignment: true,
    no_runtime_before_measurement: true,
    compaction_atomicity: true,
    event_priority_monotone: true,
    phase_derivation_agreement: true,
  },
  fsm_guard_violations: 0,
  is_live: true,
  last_outcome: null,
}

describe('parseKeeperCompositeSnapshot', () => {
  it('parses a valid snapshot', () => {
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.phase).toBe('running')
    expect(result.collapsed_from).toBeUndefined()
    expect(result.turn_phase).toBe('idle')
    expect(result.is_live).toBe(true)
    expect(result.last_outcome).toBeNull()
    expect(result.recommended_actions).toEqual([])
    expect(result.fsm_guard_violations).toBe(0)
  })

  it('parses a non-zero fsm_guard_violations count', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, fsm_guard_violations: 3 })
    expect(result.fsm_guard_violations).toBe(3)
  })

  it('parses fsm guard violation breakdown buckets', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      fsm_guard_violations: 3,
      fsm_guard_violation_breakdown: [
        { action: 'turn_phase_transition', stage: 'guard', count: 2 },
        { action: 'completion_contract', stage: 'finalize', count: 1 },
      ],
    })
    expect(result.fsm_guard_violation_breakdown).toEqual([
      { action: 'turn_phase_transition', stage: 'guard', count: 2 },
      { action: 'completion_contract', stage: 'finalize', count: 1 },
    ])
  })

  it('defaults fsm guard violation breakdown to an empty list for old payloads', () => {
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.fsm_guard_violation_breakdown).toEqual([])
  })

  it('throws CompositeSchemaDriftError when fsm_guard_violations is absent', () => {
    const { fsm_guard_violations: _, ...noViolations } = VALID_SNAPSHOT
    expect(() => parseKeeperCompositeSnapshot(noViolations)).toThrow(CompositeSchemaDriftError)
  })

  it('parses explicit keeper identity when emitted by the backend', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      keeper: 'analyst',
    })
    expect(result.keeper).toBe('analyst')
  })

  // Every phase string the backend can emit, per
  // `Keeper_state_machine.phase_to_string` (13 ctors, lowercase
  // snake_case). The schema must round-trip each one verbatim.
  it('round-trips every phase the backend can emit', () => {
    for (const phase of [
      'offline', 'running', 'failing', 'overflowed', 'compacting',
      'handing_off', 'draining', 'paused', 'stopped', 'crashed',
      'restarting', 'dead',
    ]) {
      const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, phase })
      expect(result.phase).toBe(phase)
    }
  })

  // Forward-looking: the schema's `phase` is an open string and tolerates
  // values that the runtime doesn't emit today (capitalized TLA+ projection
  // names like "Stable"). Keeping this test pins that openness so a future
  // `z.enum`-tightening doesn't silently break a planned composite-projection
  // backend rollout.
  it('schema is open to non-runtime phase values (e.g. TLA projection "Stable")', () => {
    for (const phase of ['Stable', 'Running', 'Failing']) {
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

  it('preserves unknown runtime state values for operator visibility', () => {
    const result = parseKeeperCompositeSnapshot({ ...VALID_SNAPSHOT, runtime: { state: 'wat' } })
    expect(result.runtime.state).toBe('wat')
  })

  it('parses snapshot with last_outcome present', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      last_outcome: {
        turn_id: 5,
        ended_at: 1713398500,
        decision_stage: 'guard_ok',
        runtime_state: 'done',
        selected_model: 'claude-sonnet',
      },
    })
    expect(result.last_outcome).not.toBeNull()
    expect(result.last_outcome!.turn_id).toBe(5)
    expect(result.last_outcome!.selected_model).toBe('claude-sonnet')
  })

  it('parses live_turn model and active tool count (A-PR-2 G2)', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      live_turn: {
        turn_id: 7,
        started_at: 1713398400,
        last_progress_at: 1713398450,
        last_progress_kind: 'tool_result',
        selected_model: 'claude-sonnet',
        active_tool_count: 3,
      },
    })
    expect(result.live_turn).not.toBeNull()
    expect(result.live_turn!.selected_model).toBe('claude-sonnet')
    expect(result.live_turn!.active_tool_count).toBe(3)
  })

  it('tolerates a pinned backend live_turn without the new fields', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      live_turn: {
        turn_id: 7,
        started_at: 1713398400,
        last_progress_at: 1713398450,
        last_progress_kind: null,
      },
    })
    expect(result.live_turn).not.toBeNull()
    expect(result.live_turn!.selected_model).toBeUndefined()
    expect(result.live_turn!.active_tool_count).toBeUndefined()
  })

  it('parses run_state for an in-turn keeper (#16, 38-bug campaign PR-5)', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      run_state: {
        kind: 'in_turn',
        wake_kind: 'woken',
        stimulus_kinds: ['board_signal'],
        started_at: 1713398400,
        active_tool_count: 2,
      },
    })
    expect(result.run_state?.kind).toBe('in_turn')
    expect(result.run_state?.wake_kind).toBe('woken')
    expect(result.run_state?.stimulus_kinds).toEqual(['board_signal'])
  })

  it('parses run_state for a waiting keeper', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      run_state: { kind: 'waiting', queue_depth: 2, skip_reasons: ['cooldown_pending'] },
    })
    expect(result.run_state?.kind).toBe('waiting')
    expect(result.run_state?.queue_depth).toBe(2)
    expect(result.run_state?.skip_reasons).toEqual(['cooldown_pending'])
  })

  it('parses run_state for a suspended keeper', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      run_state: { kind: 'suspended', phase: 'paused' },
    })
    expect(result.run_state?.kind).toBe('suspended')
    expect(result.run_state?.phase).toBe('paused')
  })

  it('leaves run_state undefined for a pinned backend that predates it', () => {
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.run_state).toBeUndefined()
  })

  it('parses the last_skip verdict (A-PR-2 G5)', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      last_skip: { ts: 1713398400, reasons: ['cooldown_pending', 'no_signal'] },
    })
    expect(result.last_skip).not.toBeNull()
    expect(result.last_skip!.reasons).toEqual(['cooldown_pending', 'no_signal'])
  })

  it('parses board_cursor and board_wakeups (A-PR-2 G10)', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      board_cursor: { ts: 1234.5, post_id: 'post-42' },
      board_wakeups: 2,
    })
    expect(result.board_cursor).toEqual({ ts: 1234.5, post_id: 'post-42' })
    expect(result.board_wakeups).toBe(2)
  })

  it('parses an objective turn-attempt observation', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      turn_attempt: { turn_id: 4, attempts: 3, first_started_at: 1713398000 },
    })
    expect(result.turn_attempt).not.toBeNull()
    expect(result.turn_attempt!.attempts).toBe(3)
  })

  it('leaves A-PR-2 fields undefined for old payloads that omit them', () => {
    const result = parseKeeperCompositeSnapshot(VALID_SNAPSHOT)
    expect(result.last_skip).toBeUndefined()
    expect(result.turn_attempt).toBeUndefined()
    expect(result.board_cursor).toBeUndefined()
    expect(result.board_wakeups).toBeUndefined()
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
        operator_disposition_reason: 'provider_runtime_error',
        model_used: 'claude-code:auto',
        stop_reason: 'max_turns',
        duration_ms: 87736,
        error: {
          kind: 'config',
          message_preview: 'unknown field fallback_runtime',
          message_truncated: false,
        },
        runtime: {
          name: 'primary',
          selected_model: 'claude-code:auto',
          attempt_count: 2,
          fallback_applied: true,
          outcome: 'exhausted',
          degraded_retry_applied: false,
          degraded_retry_runtime: null,
          fallback_reason: 'turn_timeout',
        },
      },
    })

    expect(result.execution?.latest_receipt_present).toBe(true)
    expect(result.execution?.terminal_reason_code).toBe('config_error')
    expect(result.execution?.runtime?.fallback_reason).toBe('turn_timeout')
    expect(result.execution?.error?.message_preview).toContain('fallback_runtime')
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
        reason: 'provider_runtime_error',
        raw_phase: 'Running',
        is_live: false,
        source: 'execution_receipt',
      },
    })

    expect(result.runtime_attention?.state).toBe('blocked')
    expect(result.runtime_attention?.reason).toBe('provider_runtime_error')
    expect(result.runtime_attention?.fiber_stop_requested).toBe(false)
  })

  it('parses secret projection status without secret values', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      secret_projection: {
        status: 'ready',
        configured: true,
        root: '/mock/workspace/.masc/secrets/sangsu',
        source: 'workspace_masc_secrets',
        effective_roots: [
          {
            root: '/mock/workspace/.masc/secrets/base',
            source: 'workspace_masc_secrets',
            status: 'ready',
            configured: true,
            env_count: 1,
            file_count: 0,
          },
          {
            root: '/mock/workspace/.masc/secrets/sangsu',
            source: 'workspace_masc_secrets',
            status: 'ready',
            configured: true,
            env_count: 1,
            file_count: 1,
          },
        ],
        env_count: 1,
        file_count: 1,
        env_names: ['GH_TOKEN'],
        file_mounts: [
          {
            host_path: '/mock/workspace/.masc/secrets/sangsu/files/home/keeper/.ssh/id_ed25519',
            container_path: '/home/keeper/.ssh/id_ed25519',
          },
        ],
        values_validated: true,
        error: null,
        next_action: 'none',
      },
    })

    expect(result.secret_projection?.status).toBe('ready')
    expect(result.secret_projection?.effective_roots.map(root => root.root)).toEqual([
      '/mock/workspace/.masc/secrets/base',
      '/mock/workspace/.masc/secrets/sangsu',
    ])
    expect(result.secret_projection?.env_names).toEqual(['GH_TOKEN'])
    expect(JSON.stringify(result.secret_projection)).not.toContain('ghs_')
  })

  it('parses snapshot with measurement context actions', () => {
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      measurement: {
        captured: true,
        context_actions: {
          compact: true,
          handoff: false,
        },
      },
    })
    expect(result.measurement.context_actions).toBeDefined()
    expect(result.measurement.context_actions!.compact).toBe(true)
  })

  it('parses collapsed_from when Stable hides a raw keeper phase', () => {
    // `Stable` is the TLA+ composite projection of seven raw keeper phases
    // (Offline/Paused/Stopped/Crashed/Restarting/Dead). The runtime
    // observer does not emit it today; the schema supports it for a planned
    // backend that surfaces the collapse with the raw phase in `collapsed_from`.
    const result = parseKeeperCompositeSnapshot({
      ...VALID_SNAPSHOT,
      phase: 'Stable',
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

})
