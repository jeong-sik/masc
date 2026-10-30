import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

const api = vi.hoisted(() => ({ fetchGoalVerificationRuns: vi.fn() }))

vi.mock('../api/dashboard', () => api)
vi.mock('../sse-store', () => ({ registerInternalAgentRefresh: vi.fn(() => vi.fn()) }))

import { GoalVerificationRunsPanel } from './goal-verification-runs-panel'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('GoalVerificationRunsPanel', () => {
  it('expands the exact lookup tool evidence for a Goal proof run', async () => {
    api.fetchGoalVerificationRuns.mockResolvedValue({
      generatedAt: '2026-08-21T00:00:00Z',
      count: 1,
      runs: [{
        runId: 'run-a',
        goalId: 'goal-a',
        requestId: 'request-original',
        criterion: { revision: 'criterion-original', title: 'Three services', metric: 'verified services', target_value: '3' },
        evaluatedVerdict: { decision: 'approved', reason: 'original target reached' },
        reviewKind: 'proof',
        authorityActor: 'verifier_exact',
        evaluatorRuntime: 'reviewer-runtime',
        startedAt: 1786000000,
        elapsedSeconds: 1.25,
        status: 'superseded',
        tools: [{
          toolName: 'verification_read_file',
          input: { producer: 'builder', file_path: 'artifacts/proof.txt' },
          disposition: 'completed',
          outputExcerpt: 'three services verified',
          outputTruncated: false,
          durationMs: 3,
          finishedAt: 1786000001,
        }],
      }],
    })

    const { container } = render(html`<${GoalVerificationRunsPanel} />`)
    expect(await screen.findByText('goal-a')).toBeTruthy()
    expect(screen.getByText('완료증명')).toBeTruthy()
    expect(screen.getByText('새 요청으로 대체됨')).toBeTruthy()
    expect(screen.getByText('판정: 승인')).toBeTruthy()
    expect(screen.getByText('request-original')).toBeTruthy()
    expect(screen.getByText('criterion-original')).toBeTruthy()
    const summary = screen.getByText('1 tool call')
    const details = summary.closest('details')
    expect(details?.open).toBe(false)
    fireEvent.click(summary)
    expect(details?.open).toBe(true)
    expect(screen.getByText('verification_read_file')).toBeTruthy()
    expect(screen.getByText('three services verified')).toBeTruthy()
    const row = container.querySelector('[data-goal-verification-run="run-a"]')
    expect(row?.getAttribute('data-goal-id')).toBe('goal-a')
    expect(row?.getAttribute('data-run-status')).toBe('superseded')
    expect(row?.getAttribute('data-review-kind')).toBe('proof')
    expect(container.querySelector('[data-testid="goal-verification-runs-panel"]')).not.toBeNull()
  })

  it('refreshes through the same endpoint', async () => {
    api.fetchGoalVerificationRuns.mockResolvedValue({ generatedAt: 'now', count: 0, runs: [] })
    render(html`<${GoalVerificationRunsPanel} />`)
    await waitFor(() => expect(api.fetchGoalVerificationRuns).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(api.fetchGoalVerificationRuns).toHaveBeenCalledTimes(2))
  })
})
