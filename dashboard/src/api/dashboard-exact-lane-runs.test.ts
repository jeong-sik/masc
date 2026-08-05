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
        input: { message_count: 4 },
        status: 'succeeded',
        elapsed_s: 0.4,
        output: { fact_count: 3 },
      }],
    })
    expect(parsed.runs[0]).toMatchObject({
      lane: 'librarian_exact',
      status: 'succeeded',
      input: { message_count: 4 },
      output: { fact_count: 3 },
    })
  })

  it('rejects an unknown lane instead of guessing', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      runs: [{
        run_id: 'x', lane: 'mystery', subject_id: 's', actor: 'a',
        started_at: 1, input: {}, status: 'running',
      }],
    })).toThrow('unknown value')
  })
})
