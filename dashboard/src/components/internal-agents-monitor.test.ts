import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'

const api = vi.hoisted(() => ({
  fetchExactLaneRuns: vi.fn(),
  fetchVerificationRuns: vi.fn(),
  fetchFusionRuns: vi.fn(),
}))

vi.mock('../api/dashboard', () => api)
vi.mock('../sse-store', () => ({
  registerInternalAgentRefresh: vi.fn(() => vi.fn()),
}))

import { InternalAgentsMonitor } from './internal-agents-monitor'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('InternalAgentsMonitor', () => {
  it('expands a verification run and shows its ordered tool evidence', async () => {
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({
      count: 1,
      generatedAt: 'now',
      runs: [{
        verificationId: 'vrf-1',
        taskId: 'task-1',
        producer: 'keeper-a',
        authorityKind: 'system_llm_agent',
        authorityActor: 'judge-1',
        startedAt: 1,
        status: 'approved',
        elapsedSeconds: 0.2,
        evaluatorRuntime: 'reviewer-runtime',
        tools: [{
          toolName: 'report_review_verdict',
          input: { verdict: 'APPROVE' },
          disposition: 'completed',
          outputExcerpt: 'Completion verdict recorded: APPROVE',
          outputTruncated: false,
          durationMs: 2,
        }],
      }],
    })

    render(html`<${InternalAgentsMonitor} />`)
    await waitFor(() => expect(screen.getByText('Verification')).toBeTruthy())
    fireEvent.click(screen.getByRole('button', { name: /Verification task-1/i }))
    expect(await screen.findByText(/report_review_verdict/)).toBeTruthy()
    expect(screen.getByText(/Completion verdict recorded: APPROVE/)).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Judge' }))
    expect(screen.queryByText('report_review_verdict')).toBeNull()
  })
})
