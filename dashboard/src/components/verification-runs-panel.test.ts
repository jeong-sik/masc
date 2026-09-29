import { cleanup, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

const api = vi.hoisted(() => ({ fetchVerificationRuns: vi.fn() }))
vi.mock('../api/dashboard', () => api)
vi.mock('../sse-store', () => ({ registerInternalAgentRefresh: vi.fn(() => vi.fn()) }))

import { parseVerificationRunsResponse } from '../api/dashboard-verification-runs'
import { VerificationRunsPanel } from './verification-runs-panel'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('VerificationRunsPanel', () => {
  it('renders cancellation, no verdict and an empty approval reason from the producer protocol', async () => {
    const outcomes = [
      { status: 'review_cancelled', detail: 'review fiber cancelled: owner stopped' },
      { status: 'not_reviewed', gate: 'evaluator_unavailable', detail: 'no runtime' },
      { status: 'approved', reason: '' },
    ]
    api.fetchVerificationRuns.mockResolvedValue(parseVerificationRunsResponse({
      generated_at: '2026-09-29T00:00:00Z', count: outcomes.length,
      runs: outcomes.map((outcome, index) => ({
        verification_id: `vrf-${index}`, task_id: `task-${index}`, producer: 'keeper-a',
        authority_kind: 'system_llm_agent', authority_actor: 'judge-a', started_at: 1786000000,
        elapsed_s: 1, tools: [], ...outcome,
      })),
    }))

    const { container } = render(html`<${VerificationRunsPanel} />`)
    const cancelled = await screen.findByText('판정 취소')
    expect(cancelled.getAttribute('data-status-badge-tone')).toBe('neutral')
    expect(cancelled.closest('tr')?.textContent).toContain('review fiber cancelled: owner stopped')
    const notReviewed = screen.getByText('판정 없음')
    expect(notReviewed.getAttribute('data-status-badge-tone')).toBe('bad')
    expect(notReviewed.closest('tr')?.textContent).toContain('evaluator_unavailable')
    expect(notReviewed.closest('tr')?.textContent).toContain('no runtime')
    expect(screen.getByText('승인').getAttribute('data-status-badge-tone')).toBe('ok')
    expect(container.textContent).not.toContain('수동 확인 필요')
    expect(container.textContent).not.toContain('목록을 불러오지 못했습니다')
  })
})
