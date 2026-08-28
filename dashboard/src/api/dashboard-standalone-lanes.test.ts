import { describe, expect, it } from 'vitest'
import { parseStandaloneLanesSnapshot } from './dashboard-standalone-lanes'

function row(laneId: string, status = 'idle') {
  return {
    lane_id: laneId,
    label: laneId,
    required: laneId === 'board_attention_exact' || laneId === 'hitl_auto_judge',
    observation_only: true,
    configured: true,
    configuration_state: 'ready',
    admitted_slots: ['primary'],
    dropped_slots: [],
    admission_error: null,
    status,
    retained_run_count: status === 'no_retained_observation' ? 0 : 1,
    running_count: status === 'running' ? 1 : 0,
    succeeded_count: status === 'no_retained_observation' ? 0 : 1,
    failed_count: 0,
    cancelled_count: 0,
    last_started_at: status === 'no_retained_observation' ? null : 10,
    last_terminal_at: status === 'no_retained_observation' ? null : 11,
    last_outcome: status === 'no_retained_observation' ? null : 'succeeded',
    p50_elapsed_s: status === 'no_retained_observation' ? null : 1,
    selected_slots: status === 'no_retained_observation' ? [] : [{ slot_id: 'primary', count: 1 }],
  }
}

function snapshot() {
  return {
    schema: 'masc.standalone_llm_lanes.v1',
    generated_at: '2026-08-27T00:00:00Z',
    observed_at_unix: 20,
    observation_only: true,
    exact_run_projection_count: 4,
    exact_run_source_total: 4,
    exact_run_projection_truncated: false,
    lanes: [
      row('board_attention_exact', 'running'),
      row('hitl_auto_judge'),
      row('librarian_exact'),
      row('compaction_exact', 'no_retained_observation'),
      row('assembler_exact', 'no_retained_observation'),
      row('verifier_exact'),
    ],
  }
}

describe('standalone lane snapshot decoder', () => {
  it('keeps all six lane states and observed slot counts', () => {
    const parsed = parseStandaloneLanesSnapshot(snapshot())
    expect(parsed.lanes).toHaveLength(6)
    expect(parsed.lanes[0]?.status).toBe('running')
    expect(parsed.lanes[0]?.selectedSlots).toEqual([{ slotId: 'primary', count: 1 }])
    expect(parsed.lanes[3]?.status).toBe('no_retained_observation')
  })

  it('rejects a projection that claims control semantics', () => {
    expect(() => parseStandaloneLanesSnapshot({ ...snapshot(), observation_only: false }))
      .toThrow(/observation_only must be true/)
  })
})
