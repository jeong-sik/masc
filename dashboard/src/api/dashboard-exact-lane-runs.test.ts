import { describe, expect, it } from 'vitest'
import { parseExactLaneRunsResponse } from './dashboard-exact-lane-runs'

describe('parseExactLaneRunsResponse', () => {
  it('decodes one completed exact lane record', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      runs: [{
        run_id: 'exact-librarian-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        input: { kind: 'exact', payload: { message_count: 4 } },
        status: 'succeeded',
        elapsed_s: 0.4,
        output: { fact_count: 3 },
      }],
    })
    expect(parsed.runs[0]).toMatchObject({
      lane: 'librarian_exact',
      status: 'succeeded',
      input: { kind: 'exact', payload: { message_count: 4 } },
      output: { fact_count: 3 },
    })
  })

  it('rejects an unknown lane instead of guessing', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      runs: [{
        run_id: 'x', lane: 'mystery', subject_id: 's', actor: 'a',
        started_at: 1, input: { kind: 'exact', payload: {} }, status: 'running',
      }],
    })).toThrow('unknown value')
  })

  it('rejects removed research input instead of replaying it', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-09T00:00:00Z',
      count: 1,
      runs: [{
        run_id: 'librarian-research-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        input: {
          kind: 'research',
          raw_trace_path: '/tmp/raw-traces/librarian-research-1.jsonl',
          payload: { message_count: 4 },
        },
        status: 'running',
      }],
    })).toThrow('unknown value')
  })

  it('decodes both explicit completion persistence failure states', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 2,
      runs: [
        {
          run_id: 'failed-append',
          lane: 'compaction_exact',
          subject_id: 'trace-1',
          actor: 'keeper-a',
          started_at: 1,
          input: { kind: 'exact', payload: {} },
          status: 'completion_persistence_failed',
          intended_status: 'failed',
          intended_code: 'model_error',
          intended_detail: 'typed failure detail',
          elapsed_s: 0.4,
          output: { partial: true },
          persistence_error: 'append rejected before commit',
          persistence_state: 'not_persisted',
        },
        {
          run_id: 'unknown-append',
          lane: 'librarian_exact',
          subject_id: 'trace-2',
          actor: 'keeper-b',
          started_at: 2,
          input: { kind: 'exact', payload: {} },
          status: 'completion_durability_unknown',
          intended_status: 'succeeded',
          elapsed_s: 0.5,
          output: { fact_count: 2 },
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
    })
    expect(parsed.runs[1]).toMatchObject({
      status: 'completion_durability_unknown',
      intendedStatus: 'succeeded',
      persistenceState: 'durability_unknown',
    })
  })

  it('rejects a persistence status paired with the wrong durability state', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 1,
      runs: [{
        run_id: 'mismatch',
        lane: 'compaction_exact',
        subject_id: 'trace',
        actor: 'keeper-a',
        started_at: 1,
        input: { kind: 'exact', payload: {} },
        status: 'completion_persistence_failed',
        intended_status: 'succeeded',
        elapsed_s: 0.4,
        output: {},
        persistence_error: 'append failed',
        persistence_state: 'durability_unknown',
      }],
    })).toThrow('persistence_state must be')
  })
})
