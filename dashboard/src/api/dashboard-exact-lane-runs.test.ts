import { describe, expect, it } from 'vitest'
import { parseExactLaneRunResponse, parseExactLaneRunsResponse } from './dashboard-exact-lane-runs'

describe('parseExactLaneRunsResponse', () => {
  it('decodes one completed Assembler exact lane record', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_id: 'exact-assembler-1',
        lane: 'assembler_exact',
        subject_id: null,
        actor: 'keeper-a',
        started_at: 1,
        status: 'succeeded',
        elapsed_s: 0.4,
        selected_slot: 'assembler-primary',
      }],
    })
    expect(parsed.runs[0]).toMatchObject({
      lane: 'assembler_exact',
      subjectId: null,
      status: 'succeeded',
      selectedSlot: 'assembler-primary',
    })
  })

  it('rejects an unknown lane instead of guessing', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_id: 'x', lane: 'mystery', subject_id: 's', actor: 'a',
        started_at: 1, status: 'running',
      }],
    })).toThrow('unknown value')
  })

  // A listing row carries no payload at all, so a payload field appearing in
  // one is a contract break rather than a value to inspect.
  it('rejects a listing row that carries a payload', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-09T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_id: 'librarian-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        status: 'running',
        input: { kind: 'exact', payload: { message_count: 4 } },
      }],
    })).toThrow()
  })

  it('reports the page it returned against the total retained', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-12T00:00:00Z',
      count: 1,
      total: 5908,
      has_more: true,
      runs: [{
        run_id: 'r', lane: 'librarian_exact', subject_id: 's', actor: 'a',
        started_at: 1, status: 'running',
      }],
    })
    expect(parsed.total).toBe(5908)
    expect(parsed.hasMore).toBe(true)
    expect(parsed.count).toBe(1)
  })
  it('decodes both explicit completion persistence failure states', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 2,
      total: 2,
      has_more: false,
      runs: [
        {
          run_id: 'failed-append',
          lane: 'compaction_exact',
          subject_id: 'trace-1',
          actor: 'keeper-a',
          started_at: 1,
          status: 'completion_persistence_failed',
          intended_status: 'failed',
          intended_code: 'model_error',
          intended_detail: 'typed failure detail',
          elapsed_s: 0.4,
          selected_slot: null,
          persistence_error: 'append rejected before commit',
          persistence_state: 'not_persisted',
        },
        {
          run_id: 'unknown-append',
          lane: 'librarian_exact',
          subject_id: 'trace-2',
          actor: 'keeper-b',
          started_at: 2,
          status: 'completion_durability_unknown',
          intended_status: 'succeeded',
          elapsed_s: 0.5,
          selected_slot: 'librarian-secondary',
          persistence_error: 'rollback settlement failed',
          persistence_state: 'durability_unknown',
        },
      ],
    })
    expect(parsed.runs[0]).toMatchObject({
      status: 'completion_persistence_failed',
      intendedStatus: 'failed',
      intendedCode: 'model_error',
      intendedDetail: 'typed failure detail',
      persistenceState: 'not_persisted',
      selectedSlot: null,
    })
    expect(parsed.runs[1]).toMatchObject({
      status: 'completion_durability_unknown',
      intendedStatus: 'succeeded',
      persistenceState: 'durability_unknown',
      selectedSlot: 'librarian-secondary',
    })
  })

  it('rejects a persistence status paired with the wrong durability state', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_id: 'mismatch',
        lane: 'compaction_exact',
        subject_id: 'trace',
        actor: 'keeper-a',
        started_at: 1,
        status: 'completion_persistence_failed',
        intended_status: 'succeeded',
        elapsed_s: 0.4,
        selected_slot: null,
        persistence_error: 'append failed',
        persistence_state: 'durability_unknown',
      }],
    })).toThrow('persistence_state must be')
  })

  it('rejects a terminal row that omits the current selected-slot contract', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_id: 'legacy-terminal',
        lane: 'librarian_exact',
        subject_id: 'trace',
        actor: 'keeper-a',
        started_at: 1,
        status: 'succeeded',
        elapsed_s: 0.4,
      }],
    })).toThrow('missing=[selected_slot]')
  })
})

describe('parseExactLaneRunResponse', () => {
  it('decodes one opened run with both payloads', () => {
    const run = parseExactLaneRunResponse({
      generated_at: '2026-08-12T00:00:00Z',
      run: {
        run_id: 'exact-librarian-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        status: 'succeeded',
        elapsed_s: 0.4,
        selected_slot: null,
        input: { kind: 'exact', payload: { message_count: 4 } },
        output: { fact_count: 3 },
      },
    })
    expect(run.input).toEqual({ kind: 'exact', payload: { message_count: 4 } })
    expect(run.output).toEqual({ fact_count: 3 })
    expect(run.selectedSlot).toBeNull()
  })

  it('rejects removed research input instead of replaying it', () => {
    expect(() => parseExactLaneRunResponse({
      generated_at: '2026-08-09T00:00:00Z',
      run: {
        run_id: 'librarian-research-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        status: 'running',
        input: {
          kind: 'research',
          raw_trace_path: '/tmp/raw-traces/librarian-research-1.jsonl',
          payload: { message_count: 4 },
        },
      },
    })).toThrow('unknown value')
  })
})
