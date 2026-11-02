import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
const api = vi.hoisted(() => ({ getWithResponse: vi.fn(), post: vi.fn() }))
vi.mock('../../api/core', async original => ({ ...await original<typeof import('../../api/core')>(), ...api }))
import { GoalConfirmationPanel, _testResetConfirmationReceipts } from './goal-confirmation'

const criterion = { revision: 'revision-1', title: 'Original criterion', metric: 'passed cases', target_value: '10' }
const verdict = { criterion, request_id: 'request-1', verification_run_id: 'run-1', outcome: 'proven', reason: null,
  authority: { kind: 'system_llm_agent', actor: 'verifier' }, evidence: '<script>literal evidence</script> 10/10', recorded_at: '2026-09-10T00:00:00Z' }
const workspace = { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }
const owner = (goalId = 'goal-1', key = 'owner-a', currentWorkspace = workspace, credentialScope = 'credential-a') =>
  ({ key, goalId, workspace: currentWorkspace, credentialScope })
const current = () => true
const panelDefaults = { readAuthority: {}, lifecyclePending: false, hasLifecyclePending: () => false }
function evidence(confirmed = false, id = 'goal-1') {
  return { inspection_operator_id: 'inspecting-operator', goal: { id, phase: confirmed ? 'completed' : 'awaiting_confirmation', criterion_revision: criterion.revision,
      title: criterion.title, metric: criterion.metric, target_value: criterion.target_value },
    verification: { goal_id: id, updated_at: '2026-09-10T00:00:00Z', completion: confirmed
      ? { state: 'human_confirmed', verdict, operator_id: 'operator-1', confirmed_at: '2026-09-10T01:00:00Z' }
      : { state: 'proof_proven', verdict } } }
}
function response(data: unknown, matched = true) {
  return { data, headers: new Headers(matched ? { 'x-masc-workspace-read': 'matched-v1' } : {}) }
}
afterEach(() => { cleanup(); _testResetConfirmationReceipts() })
beforeEach(() => { api.getWithResponse.mockReset(); api.post.mockReset() })
describe('real Goal confirmation component through API decoding', () => {
  it('shows exact evidence, sends its workspace and proof binding, and requires post/readback completion', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockResolvedValueOnce(response(evidence(true)))
    let resolve!: (value: unknown) => void
    api.post.mockReturnValue(new Promise(r => { resolve = r }))
    const confirmed = vi.fn()
    const { container } = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${confirmed} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    expect(container.querySelector('script')).toBeNull()
    expect(screen.getByText(verdict.evidence)).toBeTruthy()
    expect(api.getWithResponse.mock.calls[0]?.[0]).toContain('expected_base_path=%2Fworkspace-a')
    expect(api.post).toHaveBeenCalledWith('/api/v1/goals/confirmation', {
      goal_id: 'goal-1', criterion_revision: 'revision-1', request_id: 'request-1', verification_run_id: 'run-1',
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
      expected_operator_id: 'inspecting-operator',
    }, undefined, undefined, undefined, true)
    expect(confirmed).not.toHaveBeenCalled()
    resolve(evidence(true))
    await screen.findByText(/최종 확인 완료 · operator-1/)
    expect(confirmed).toHaveBeenCalledOnce()
    expect(api.getWithResponse).toHaveBeenCalledTimes(2)
  })
  it('preserves uncertainty after a committed POST whose readback fails', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockRejectedValueOnce(new Error('readback unavailable'))
    api.post.mockResolvedValue(evidence(true))
    const props = { ...panelDefaults, owner: owner(), isCurrent: current, onConfirmed: vi.fn() }
    const ui = render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    ui.unmount()
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    expect(await screen.findByText(/서버에 반영되었을 수 있습니다/)).toBeTruthy()
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    expect(api.post).toHaveBeenCalledTimes(1)
  })
  it('rejects an unattested proof and offers a fresh evidence retry', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(evidence(), false)).mockResolvedValueOnce(response(evidence()))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    await screen.findByText(/작업 공간 확인 응답이 없어/)
    expect(api.post).not.toHaveBeenCalled()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
  })
  it('refuses a proof whose criterion differs from the Goal at the same revision', async () => {
    const wrong = evidence()
    wrong.goal.metric = 'different metric'
    api.getWithResponse.mockResolvedValue(response(wrong))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    await screen.findByText(/목표 기준과 verifier 증명의 내용이 다릅니다/)
    expect(api.post).not.toHaveBeenCalled()
  })
  it('does not accept a response that changes the inspected criterion at the same revision', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    const wrong = structuredClone(evidence(true))
    wrong.goal.metric = 'different metric'
    wrong.verification.completion.verdict.criterion.metric = 'different metric'
    api.post.mockResolvedValue(wrong)
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/제출한 증명 또는 완료 상태와 일치하지 않습니다/)
    expect(api.getWithResponse).toHaveBeenCalledTimes(1)
  })
  it('does not accept a response that changes the inspected verifier evidence', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    const wrong = structuredClone(evidence(true))
    wrong.verification.completion.verdict.evidence = 'different evidence'
    api.post.mockResolvedValue(wrong)
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/제출한 증명 또는 완료 상태와 일치하지 않습니다/)
    expect(api.getWithResponse).toHaveBeenCalledTimes(1)
  })
  it('does not substitute a new proof after a stale POST refusal', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    api.post.mockRejectedValue(new Error('current criterion changed'))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/current criterion changed/)
    expect(api.getWithResponse).toHaveBeenCalledTimes(1)
    expect(api.post).toHaveBeenCalledTimes(1)
  })
  it('ignores a previous selection response', async () => {
    let old!: (value: unknown) => void
    api.getWithResponse.mockReturnValueOnce(new Promise(r => { old = r })).mockResolvedValueOnce(response(evidence(false, 'goal-2')))
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner('goal-2', 'owner-b')} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    await screen.findByText('이 증명으로 목표 완료 확인')
    old(response(evidence()))
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(2))
    api.post.mockRejectedValue(new Error('stop'))
    fireEvent.click(screen.getByText('이 증명으로 목표 완료 확인'))
    expect(api.post.mock.calls[0]?.[1].goal_id).toBe('goal-2')
  })
  it('restarts a proof read when the same owner receives a new tree observation', async () => {
    let old!: (value: unknown) => void
    api.getWithResponse.mockReturnValueOnce(new Promise(r => { old = r })).mockResolvedValueOnce(response(evidence()))
    let observation = 1
    const firstCurrent = () => observation === 1
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${firstCurrent} onConfirmed=${vi.fn()} />`)
    observation = 2
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} readAuthority=${{}} owner=${owner()} isCurrent=${() => observation === 2} onConfirmed=${vi.fn()} />`)
    await screen.findByText('이 증명으로 목표 완료 확인')
    old(response(evidence()))
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(2))
  })
  it('keeps the original uncertain binding after failed and successful rereads', async () => {
    api.getWithResponse.mockResolvedValueOnce(response(evidence()))
      .mockRejectedValueOnce(new Error('readback offline'))
      .mockResolvedValueOnce(response(evidence()))
    api.post.mockRejectedValue(new Error('response lost'))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/response lost/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(/readback offline/)
    expect(screen.getByText(/response lost/)).toBeTruthy()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('request-1')
    fireEvent.click(screen.getByText('이 증명으로 목표 완료 확인'))
    await waitFor(() => expect(api.post).toHaveBeenCalledTimes(2))
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('run-1')
  })
  it('blocks confirmation while a lifecycle action for the same Goal is pending', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    let pending = true
    const hasLifecyclePending = () => pending
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current}
      lifecyclePending=${true} hasLifecyclePending=${hasLifecyclePending} onConfirmed=${vi.fn()} />`)
    await screen.findByText(/같은 목표의 다른 변경 요청/)
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current}
      lifecyclePending=${false} hasLifecyclePending=${hasLifecyclePending} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    expect(api.post).not.toHaveBeenCalled()
    pending = false
  })
  it('keeps a pending request with its original credential and blocks a second confirmation', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    let resolve!: (value: unknown) => void
    api.post.mockReturnValue(new Promise(r => { resolve = r }))
    const confirmed = vi.fn()
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${confirmed} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner('goal-1', 'owner-b', workspace, 'credential-b')} isCurrent=${current} onConfirmed=${confirmed} />`)
    await screen.findByText(/다른 연결 또는 인증의 같은 목표 확인/)
    expect(screen.queryByText(/이전 연결 확인 요청 진행 중/)).toBeNull()
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    resolve(evidence(true))
    await screen.findByText(/다른 연결에서 보낸 확인 요청의 결과가 미확인/)
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
    expect(confirmed).not.toHaveBeenCalled()
    expect(api.post).toHaveBeenCalledTimes(1)
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${confirmed} />`)
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
  })
  it('retains the original proof identity across a server reconnect under the same credential', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    let resolve!: (value: unknown) => void
    api.post.mockReturnValue(new Promise(r => { resolve = r }))
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner('goal-1', 'new-epoch')} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    expect((await screen.findByText(/이전 연결 확인 요청 진행 중/)).textContent).toContain('request-1')
    resolve(evidence(true))
    expect((await screen.findByText(/이전 확인 요청 결과 미확인/)).textContent).toContain('run-1')
  })
})
