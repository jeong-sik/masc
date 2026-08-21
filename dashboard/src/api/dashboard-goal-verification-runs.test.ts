import { afterEach, describe, expect, it, vi } from 'vitest'

const getMock = vi.hoisted(() => vi.fn())

vi.mock('./core', () => ({ get: getMock }))

import {
  fetchGoalVerificationRuns,
  parseGoalVerificationRunsResponse,
} from './dashboard-goal-verification-runs'

afterEach(() => {
  getMock.mockReset()
})

function row(overrides: Record<string, unknown> = {}) {
  return {
    run_id: '019f-goal-run',
    goal_id: 'goal-a',
    review_kind: 'proof',
    authority_actor: 'verifier_exact',
    started_at: 1786000000,
    status: 'committed',
    elapsed_s: 1.25,
    evaluator_runtime: 'reviewer-runtime',
    tools: [{
      tool_name: 'verification_read_file',
      input: { producer: 'builder', file_path: 'artifacts/proof.txt' },
      disposition: 'completed',
      output_excerpt: 'proof bytes',
      output_truncated: false,
      duration_ms: 3,
      finished_at: 1786000001,
    }],
    ...overrides,
  }
}

describe('parseGoalVerificationRunsResponse', () => {
  it('keeps the Goal identity, proof kind, runtime, and tool evidence', () => {
    const parsed = parseGoalVerificationRunsResponse({
      generated_at: '2026-08-21T00:00:00Z',
      count: 1,
      runs: [row()],
    })
    expect(parsed.runs[0]).toMatchObject({
      goalId: 'goal-a',
      reviewKind: 'proof',
      status: 'committed',
      evaluatorRuntime: 'reviewer-runtime',
      tools: [{ toolName: 'verification_read_file' }],
    })
  })

  it('keeps a deferred run nonterminal with its retry decision', () => {
    const parsed = parseGoalVerificationRunsResponse({
      generated_at: '2026-08-21T00:00:00Z',
      count: 1,
      runs: [row({
        status: 'deferred',
        retryable: false,
        detail: 'linked task has no performer tree',
        tools: [],
      })],
    })
    expect(parsed.runs[0]).toMatchObject({
      status: 'deferred',
      retryable: false,
      detail: 'linked task has no performer tree',
    })
  })

  it('keeps a crash-replayable reviewed run with its tool evidence', () => {
    const parsed = parseGoalVerificationRunsResponse({
      generated_at: '2026-08-21T00:00:00Z',
      count: 1,
      runs: [row({ status: 'reviewed' })],
    })
    expect(parsed.runs[0]).toMatchObject({
      status: 'reviewed',
      tools: [{ toolName: 'verification_read_file' }],
    })
  })

  it('rejects an unknown review kind and outcome-specific field drift', () => {
    expect(() => parseGoalVerificationRunsResponse({
      generated_at: 'now',
      count: 1,
      runs: [row({ review_kind: 'maybe-proof' })],
    })).toThrow('review_kind has unknown value')
    expect(() => parseGoalVerificationRunsResponse({
      generated_at: 'now',
      count: 1,
      runs: [row({ detail: 'not valid on committed' })],
    })).toThrow('fields mismatch')
  })
})

describe('fetchGoalVerificationRuns', () => {
  it('reads the Goal verification runs route', async () => {
    getMock.mockResolvedValue({ generated_at: 'now', count: 0, runs: [] })
    await fetchGoalVerificationRuns()
    expect(getMock).toHaveBeenCalledWith(
      '/api/v1/dashboard/goal-verification-runs',
      expect.objectContaining({ signal: undefined }),
    )
  })
})
