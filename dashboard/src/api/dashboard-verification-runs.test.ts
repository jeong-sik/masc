// RFC-0361 D4 — completion-authority review registry decoding.
//
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
} from './dashboard-verification-runs'

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
    evaluator_runtime: 'cross-verifier',
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
    expect(parsed.runs[0]).toMatchObject({
      verificationId: 'vrf-24b43c36',
      taskId: 'task-136',
      producer: 'keeper-kidsnote-agent',
      authorityActor: 'system-llm-agent-473b608e',
      status: 'approved',
      elapsedSeconds: 2.5,
      evaluatorRuntime: 'cross-verifier',
    })
  })

  it('reads a rejection cause from `reason`', () => {
    const parsed = parseVerificationRunsResponse({
      runs: [row({ status: 'rejected', reason: 'aria attributes are not committed' })],
    })
    expect(parsed.runs[0].status).toBe('rejected')
    expect(parsed.runs[0].cause).toBe('aria attributes are not committed')
  })

  it('reads a failure cause from `detail` and keeps the gate', () => {
    const parsed = parseVerificationRunsResponse({
      runs: [
        row({ status: 'not_reviewed', gate: 'evaluator_unavailable', detail: 'no runtime' }),
      ],
    })
    expect(parsed.runs[0].status).toBe('not_reviewed')
    expect(parsed.runs[0].cause).toBe('no runtime')
    expect(parsed.runs[0].gate).toBe('evaluator_unavailable')
  })

  it('maps an unrecognized status to `unknown` rather than a real outcome', () => {
    // The backend emits a closed set, so an unrecognized value is a protocol
    // break. Mapping it onto `approved` would let a garbled row claim a Task
    // passed review; mapping it onto a specific failure would misattribute one.
    const parsed = parseVerificationRunsResponse({
      runs: [row({ status: 'probably_fine' })],
    })
    expect(parsed.runs[0].status).toBe('unknown')
  })

  it('drops rows with no verification id', () => {
    const parsed = parseVerificationRunsResponse({
      runs: [row(), row({ verification_id: '' }), { status: 'approved' }],
    })
    expect(parsed.runs).toHaveLength(1)
  })

  it('survives a malformed payload', () => {
    expect(parseVerificationRunsResponse(null)).toEqual({
      runs: [],
      count: 0,
      generatedAt: null,
    })
  })
})

describe('fetchVerificationRuns', () => {
  it('reads the dashboard verification-runs endpoint', async () => {
    getMock.mockResolvedValue({ runs: [row()], count: 1 })
    const result = await fetchVerificationRuns()
    expect(getMock).toHaveBeenCalledWith(
      '/api/v1/dashboard/verification-runs',
      expect.objectContaining({ signal: undefined }),
    )
    expect(result.runs).toHaveLength(1)
  })
})
