import { describe, expect, it } from 'vitest'

import type { Keeper } from '../types'
import type { KeeperRuntimeTraceResponse } from '../api/keeper'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import { deriveKeeperRuntimeProjection } from './keeper-runtime-projection'

const NOW_MS = Date.parse('2026-05-21T00:10:00Z')

function keeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    status: 'active',
    phase: 'Running',
    keepalive_running: true,
    ...overrides,
  } as Keeper
}

function composite(overrides: Partial<KeeperCompositeSnapshot> = {}): KeeperCompositeSnapshot {
  const base = {
    keeper: 'sangsu',
    correlation_id: 'corr-1',
    run_id: 'run-1',
    ts: 1,
    phase: 'running',
    turn_phase: 'idle',
    decision: { stage: 'idle' },
    runtime: { state: 'idle' },
    compaction: { stage: 'idle' },
    measurement: { captured: true },
    invariants: {
      phase_turn_alignment: true,
      no_runtime_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
    phase_diagnosis: {
      current_phase: 'Running',
      derived_phase: 'Running',
      can_execute_turn: true,
      conditions: {
        launch_pending: false,
        fiber_alive: true,
        heartbeat_healthy: true,
        turn_healthy: true,
        context_within_budget: true,
        context_handoff_needed: false,
        compaction_active: false,
        handoff_active: false,
        operator_paused: false,
        stop_requested: false,
        dead_tombstone_latched: false,
        drain_complete: false,
        context_overflow: false,
      },
      determining_condition: 'running_fiber_alive',
      rows: [],
    },
    is_live: false,
    last_outcome: null,
    execution: {
      latest_receipt_present: true,
      recorded_at: '2026-05-21T00:00:00Z',
      outcome: 'receipt_done',
      terminal_reason_code: 'completed',
      operator_disposition: 'pass',
      operator_disposition_reason: 'healthy',
      model_used: null,
      stop_reason: 'completed',
      duration_ms: 1000,
      error: null,
      runtime: null,
    },
    runtime_attention: {
      state: 'ok',
      needs_attention: false,
      blocked: false,
      fiber_stop_requested: false,
      reason: null,
      raw_phase: 'running',
      is_live: false,
      source: 'execution_receipt',
    },
    recommended_actions: [],
  } as KeeperCompositeSnapshot
  return { ...base, ...overrides } as KeeperCompositeSnapshot
}

function runtimeTrace(overrides: Partial<KeeperRuntimeTraceResponse> = {}): KeeperRuntimeTraceResponse {
  const base = {
    keeper: 'sangsu',
    trace_id: 'trace-1',
    turn_id: 7,
    manifest_path: '/tmp/manifest.jsonl',
    manifest_path_present: true,
    manifest_total_rows: 6,
    manifest_returned_rows: 6,
    receipt_returned_rows: 1,
    turn_identity: { requested_keeper_turn_id: 7 },
    provider_attempts: {},
    event_bus: {},
    memory: {},
    runtime_lens: {
      turn_clock: {
        keeper_turn_id: 7,
        terminal_event_present: true,
        terminal_event: 'turn_finished',
        max_oas_turn_count: 3,
      },
      axes: {},
      swimlanes: {},
      clock_edges: [],
      clock_groups: [],
      gaps: [],
    },
    linked_artifacts: { receipts: [], checkpoints: [], tool_call_logs: [] },
    manifest_rows: [],
    receipts: [],
    health: 'ok',
    stale_reason: null,
  } as unknown as KeeperRuntimeTraceResponse
  return { ...base, ...overrides } as KeeperRuntimeTraceResponse
}

describe('deriveKeeperRuntimeProjection', () => {
  it('couples heartbeat, context, fiber, stop, trace, tool, and FSM lanes', () => {
    const projection = deriveKeeperRuntimeProjection({
      keeper: keeper({
        last_heartbeat: '2026-05-21T00:00:00Z',
        context_ratio: 0.97,
        runtime_warning_ctx_ratio: 0.95,
      }),
      composite: composite({
        phase: 'failing',
        turn_phase: 'executing',
        decision: { stage: 'tool_optional' },
        runtime: { state: 'degraded_retry' },
        compaction: { stage: 'idle' },
      }),
      runtimeTrace: runtimeTrace(),
      runtimeResolution: {
        warnings: ['Runtime build commit differs from server repo HEAD.'],
        source_mismatch: true,
      },
      nowMs: NOW_MS,
    })

    expect(projection.headline).toBe('조치 필요')
    expect(projection.heartbeat.stale).toBe(true)
    expect(projection.context.breach).toBe(true)
    expect(projection.fiberAlive.alive).toBe(true)
    expect(projection.fsmLanes.map(lane => lane.axis)).toEqual(['KSM', 'KTC', 'KDP', 'KCL', 'KMC'])
    expect(projection.signals.map(signal => signal.kind)).toEqual([
      'operational_state',
      'ksm_phase',
      'heartbeat',
      'context_ratio',
      'fiber_alive',
      'stop_requested',
      'runtime_trace',
      'runtime_warning',
      'fsm_raw_lanes',
    ])
    expect(projection.synchronizationDetail).toContain('hb stale')
    expect(projection.synchronizationDetail).toContain('ctx breach')
    expect(projection.synchronizationDetail).toContain('fiber alive')
    expect(projection.synchronizationDetail).toContain('stop clear')
    expect(projection.synchronizationDetail).toContain('KSM failing')
  })

  it('lets stop requests dominate the coupled headline and tone', () => {
    const projection = deriveKeeperRuntimeProjection({
      keeper: keeper(),
      composite: composite({
        runtime_attention: {
          ...composite().runtime_attention!,
          fiber_stop_requested: true,
        },
      }),
      nowMs: NOW_MS,
    })

    expect(projection.stopRequested).toBe(true)
    expect(projection.headline).toBe('종료 신호')
    expect(projection.tone).toBe('bad')
  })

  it('does not turn a stale execution receipt into current attention', () => {
    const projection = deriveKeeperRuntimeProjection({
      keeper: keeper(),
      composite: composite({
        is_live: true,
        turn_phase: 'executing',
        runtime_attention: {
          ...composite().runtime_attention!,
          execution_current: false,
          stale_execution_receipt: true,
          is_live: true,
        },
      }),
      runtimeTrace: runtimeTrace(),
      nowMs: NOW_MS,
    })

    expect(projection.headline).toBe('턴 진행 중')
    expect(projection.tone).toBe('ok')
  })
})
