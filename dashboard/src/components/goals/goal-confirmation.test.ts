import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
const api = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('../../api/core', () => api)
import { GoalConfirmationPanel } from './goal-confirmation'
const criterion = { revision: 'revision-1', title: 'Original criterion', metric: 'passed cases', target_value: '10' }
const verdict = { criterion, request_id: 'request-1', verification_run_id: 'run-1', outcome: 'proven', reason: null,
  authority: { kind: 'system_llm_agent', actor: 'verifier' }, evidence: '<script>literal evidence</script> 10/10', recorded_at: '2026-09-10T00:00:00Z' }
function evidence(confirmed = false, id = 'goal-1') {
  return { goal: { id, phase: confirmed ? 'completed' : 'awaiting_confirmation', criterion_revision: criterion.revision },
    verification: { goal_id: id, updated_at: '2026-09-10T00:00:00Z', completion: confirmed
      ? { state: 'human_confirmed', verdict, operator_id: 'operator-1', confirmed_at: '2026-09-10T01:00:00Z' }
      : { state: 'proof_proven', verdict } } }
}
afterEach(cleanup)
beforeEach(() => { api.get.mockReset(); api.post.mockReset() })
describe('real Goal confirmation component through API decoding', () => {
  it('shows exact evidence, sends its binding and requires post/readback completion', async () => {
    api.get.mockResolvedValueOnce(evidence()).mockResolvedValueOnce(evidence(true))
    let resolve!: (value: unknown) => void
    api.post.mockReturnValue(new Promise(r => { resolve = r }))
    const confirmed = vi.fn()
    const { container } = render(html`<${GoalConfirmationPanel} goalId="goal-1" onConfirmed=${confirmed} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    expect(container.querySelector('script')).toBeNull()
    expect(screen.getByText(verdict.evidence)).toBeTruthy()
    expect(api.post).toHaveBeenCalledWith('/api/v1/goals/confirmation', {
      goal_id: 'goal-1', criterion_revision: 'revision-1', request_id: 'request-1', verification_run_id: 'run-1' })
    expect(confirmed).not.toHaveBeenCalled()
    expect(screen.queryByText(/최종 확인 완료/)).toBeNull()
    resolve(evidence(true))
    await screen.findByText(/최종 확인 완료 · operator-1/)
    expect(confirmed).toHaveBeenCalledOnce()
    expect(api.get).toHaveBeenCalledTimes(2)
  })
  it('preserves uncertainty after a committed POST whose readback fails', async () => {
    api.get.mockResolvedValueOnce(evidence()).mockRejectedValueOnce(new Error('readback unavailable'))
    api.post.mockResolvedValue(evidence(true))
    render(html`<${GoalConfirmationPanel} goalId="goal-1" onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/최종 확인 완료/)).toBeNull()
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
  })
  it('shows read permission failure and offers fresh evidence retry', async () => {
    api.get.mockRejectedValueOnce(new Error('403 forbidden')).mockResolvedValueOnce(evidence())
    render(html`<${GoalConfirmationPanel} goalId="goal-1" onConfirmed=${vi.fn()} />`)
    await screen.findByText(/403 forbidden/)
    expect(api.post).not.toHaveBeenCalled()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
  })
  it('does not substitute a new proof after stale POST refusal', async () => {
    api.get.mockResolvedValue(evidence())
    api.post.mockRejectedValue(new Error('current criterion changed'))
    render(html`<${GoalConfirmationPanel} goalId="goal-1" onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/current criterion changed/)
    expect(api.get).toHaveBeenCalledTimes(1)
    expect(api.post).toHaveBeenCalledTimes(1)
  })
  it('ignores the previous selection response', async () => {
    let old!: (value: unknown) => void
    api.get.mockReturnValueOnce(new Promise(r => { old = r })).mockResolvedValueOnce(evidence(false, 'goal-2'))
    const ui = render(html`<${GoalConfirmationPanel} goalId="goal-1" onConfirmed=${vi.fn()} />`)
    ui.rerender(html`<${GoalConfirmationPanel} goalId="goal-2" onConfirmed=${vi.fn()} />`)
    await screen.findByText('이 증명으로 목표 완료 확인')
    old(evidence())
    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(2))
    api.post.mockRejectedValue(new Error('stop'))
    fireEvent.click(screen.getByText('이 증명으로 목표 완료 확인'))
    expect(api.post.mock.calls[0]?.[1].goal_id).toBe('goal-2')
  })
})
