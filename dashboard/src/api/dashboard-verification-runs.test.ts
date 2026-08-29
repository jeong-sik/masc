// The registry exists so a review that produced no verdict is visible. These
// cases pin that the decoder never turns such a row into something healthier
// than it is, and that each outcome's cause survives into the one column the
// panel shows.

import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({
  get: getMock,
}))

import {
  fetchVerificationRuns,
  parseVerificationRunsResponse,
  type DashboardVerificationRunsResponse,
  type VerificationRunRecord,
} from './dashboard-verification-runs'

// Indexing straight into `runs` reads as possibly-undefined under the
// dashboard's strict config. Asserting the count first and binding the row
// keeps the cases type-safe and makes each one state how many rows it expects.
function onlyRun(parsed: DashboardVerificationRunsResponse): VerificationRunRecord {
  expect(parsed.runs).toHaveLength(1)
  const [run] = parsed.runs
  if (!run) throw new Error('expected exactly one run')
  return run
}

afterEach(() => {
  getMock.mockReset()
})

function row(overrides: Record<string, unknown> = {}) {
  return {
    verification_id: 'vrf-24b43c36',
    task_id: 'task-136',
    producer: 'keeper-kidsnote-agent',
    authority_kind: 'system_llm_agent',
    authority_actor: 'system-llm-agent-473b608e',
    started_at: 1_754_000_000,
    status: 'approved',
    elapsed_s: 2.5,
    tools: [],
    evaluator_runtime: 'judge-runtime',
    ...overrides,
  }
}

describe('parseVerificationRunsResponse', () => {
  it('maps a completed review onto the record shape', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row()],
    })
    expect(parsed.count).toBe(1)
    expect(parsed.generatedAt).toBe('2026-08-05T00:00:00Z')
    expect(onlyRun(parsed)).toMatchObject({
      verificationId: 'vrf-24b43c36',
      taskId: 'task-136',
      producer: 'keeper-kidsnote-agent',
      authorityActor: 'system-llm-agent-473b608e',
      status: 'approved',
      elapsedSeconds: 2.5,
      evaluatorRuntime: 'judge-runtime',
    })
  })

  it('preserves ordered typed tool evidence', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({
        tools: [{
          tool_name: 'report_review_verdict',
          input: { verdict: 'APPROVE' },
          disposition: 'completed',
          output_excerpt: 'Completion verdict recorded: APPROVE',
          output_truncated: false,
          duration_ms: 1.25,
          finished_at: 1786000002.25,
        }],
      })],
    })
    expect(onlyRun(parsed).tools).toEqual([{
      toolName: 'report_review_verdict',
      input: { verdict: 'APPROVE' },
      disposition: 'completed',
      outputExcerpt: 'Completion verdict recorded: APPROVE',
      outputTruncated: false,
      durationMs: 1.25,
      finishedAt: 1786000002.25,
    }])
  })

  it('reads a rejection cause from `reason`', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({ status: 'rejected', reason: 'aria attributes are not committed' })],
    })
    expect(onlyRun(parsed).status).toBe('rejected')
    expect(onlyRun(parsed).cause).toBe('aria attributes are not committed')
  })

  it('reads a failure cause from `detail` and keeps the gate', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [
        row({
          status: 'not_reviewed',
          gate: 'evaluator_unavailable',
          detail: 'no runtime',
          retryable: true,
        }),
      ],
    })
    expect(onlyRun(parsed).status).toBe('not_reviewed')
    expect(onlyRun(parsed).cause).toBe('no runtime')
    expect(onlyRun(parsed).gate).toBe('evaluator_unavailable')
    expect(onlyRun(parsed).retryable).toBe(true)
  })

  // The completion authority stops scheduling its own retry when the same
  // review is known to keep failing the same way (a single-atom review whose
  // seed message alone exceeds the target's whole budget, for example) —
  // `retryable: false` is how an operator tells that apart from an ordinary
  // in-flight `not_reviewed` row that will resolve itself on the next pulse.
  it('surfaces a non-retryable not_reviewed row distinctly from a retryable one', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [
        row({
          status: 'not_reviewed',
          gate: 'evaluator_unavailable',
          detail: 'newest conversation atom does not fit the model input budget',
          retryable: false,
        }),
      ],
    })
    expect(onlyRun(parsed).retryable).toBe(false)
  })

  it('keeps the typed infrastructure stage without inventing a verdict', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({
        status: 'infrastructure_unavailable',
        stage: 'lookup_surface',
        detail: 'producer metadata unavailable',
      })],
    })
    expect(onlyRun(parsed)).toMatchObject({
      status: 'infrastructure_unavailable',
      infrastructureStage: 'lookup_surface',
      cause: 'producer metadata unavailable',
    })
  })

  it('rejects an unknown infrastructure stage', () => {
    expect(() => parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({
        status: 'infrastructure_unavailable',
        stage: 'probably_available',
        detail: 'producer metadata unavailable',
      })],
    })).toThrow('runs[0].stage has unknown value')
  })

  it('rejects an unrecognized status as a protocol break', () => {
    expect(() => parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({ status: 'probably_fine' })],
    })).toThrow('runs[0].status has unknown status')
  })

  it('rejects rows with no verification id instead of dropping evidence', () => {
    expect(() => parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({ verification_id: '' })],
    })).toThrow('runs[0].verification_id must be a non-empty string')
  })

  it('rejects a malformed root instead of projecting an empty registry', () => {
    expect(() => parseVerificationRunsResponse(null)).toThrow('root must be an object')
  })

  it('surfaces the reason an approval states', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({ reason: 'ran the suite in the sandbox: 9355/9355' })],
    })
    expect(onlyRun(parsed).cause).toBe('ran the suite in the sandbox: 9355/9355')
  })

  // Approvals written before the reviewer channel carried a reason have no
  // such field. They still decode, with nothing to show.
  it('decodes an approval that states no reason', () => {
    const parsed = parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row()],
    })
    expect(onlyRun(parsed).cause).toBeUndefined()
  })

  it('rejects outcome-specific fields on the wrong constructor', () => {
    expect(() => parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 1,
      runs: [row({ detail: 'cannot belong to approved' })],
    })).toThrow('runs[0] fields mismatch')
  })

  it('rejects a count that disagrees with the decoded rows', () => {
    expect(() => parseVerificationRunsResponse({
      generated_at: '2026-08-05T00:00:00Z',
      count: 2,
      runs: [row()],
    })).toThrow('root.count=2 does not match runs.length=1')
  })
})

describe('fetchVerificationRuns', () => {
  it('reads the dashboard verification-runs endpoint', async () => {
    getMock.mockResolvedValue({
      generated_at: '2026-08-05T00:00:00Z',
      runs: [row()],
      count: 1,
    })
    const result = await fetchVerificationRuns()
    expect(getMock).toHaveBeenCalledWith(
      '/api/v1/dashboard/verification-runs',
      expect.objectContaining({ signal: undefined }),
    )
    expect(result.runs).toHaveLength(1)
  })
})
