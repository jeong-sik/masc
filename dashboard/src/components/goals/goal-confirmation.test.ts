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
const epoch = 'execution-epoch-a'
const instance = '018f83d7-93a4-7f5d-9a72-123456789abc'
const owner = (goalId = 'goal-1', key = 'owner-a', currentWorkspace = workspace, credentialScope = 'credential-a') =>
  ({ key, goalId, workspace: currentWorkspace, credentialScope, executionEpoch: epoch })
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
  return { data, headers: new Headers(matched ? { 'x-masc-workspace-read': 'matched-v1',
    'x-masc-execution-publication-epoch': epoch, 'x-masc-runtime-instance-id': instance } : {}) }
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
    const confirm = await screen.findByText('이 증명으로 목표 완료 확인')
    expect(confirm.previousElementSibling?.textContent).toContain('Snapshot 밖의 지급 누락 여부는 확인되지 않았습니다')
    fireEvent.click(confirm)
    expect(container.querySelector('script')).toBeNull()
    expect(screen.getByText(verdict.evidence)).toBeTruthy()
    expect(api.getWithResponse.mock.calls[0]?.[0]).toContain('expected_base_path=%2Fworkspace-a')
    expect(api.getWithResponse.mock.calls[0]?.[1].reportCredentialRefusal).toBe(false)
    expect(api.post).toHaveBeenCalledWith('/api/v1/goals/confirmation', {
      goal_id: 'goal-1', criterion_revision: 'revision-1', request_id: 'request-1', verification_run_id: 'run-1',
      expected_workspace: { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' },
      expected_operator_id: 'inspecting-operator',
      expected_runtime_instance_id: instance,
    }, undefined, undefined, undefined, true, expect.objectContaining({ reportCredentialRefusal: false, beforeResponseBody: expect.any(Function) }))
    expect(confirmed).not.toHaveBeenCalled()
    resolve(evidence(true))
    await screen.findByText(/최종 확인 완료 · operator-1/)
    expect(confirmed).toHaveBeenCalledOnce()
    expect(api.getWithResponse).toHaveBeenCalledTimes(2)
  })
  it('shows the first recorded operator before explicitly resuming incomplete confirmation', async () => {
    const partial = structuredClone(evidence(true))
    partial.goal.phase = 'awaiting_confirmation'
    api.getWithResponse.mockResolvedValue(response(partial))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    const status = await screen.findByText(/운영자 확인은 이미 기록되었습니다/)
    expect(status.textContent).toContain('operator-1')
    expect(status.textContent).toContain('2026-09-10T01:00:00Z')
    expect(status.textContent).toContain('목표 완료와 후속 처리는 아직 확인되지 않았습니다')
    expect(screen.getByText('이 증명의 완료 처리 재개')).toBeTruthy()
    expect(api.post).not.toHaveBeenCalled()
  })
  it('refuses a proof from another execution epoch or without a unique server instance', async () => {
    const foreign = response(evidence())
    foreign.headers.set('x-masc-execution-publication-epoch', 'other-epoch')
    const missing = response(evidence())
    missing.headers.delete('x-masc-runtime-instance-id')
    const duplicate = response(evidence())
    duplicate.headers.append('x-masc-runtime-instance-id', instance)
    api.getWithResponse.mockResolvedValueOnce(foreign).mockResolvedValueOnce(missing).mockResolvedValueOnce(duplicate)
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    await screen.findByText(/증거 조회에 실패했습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(2))
    await screen.findByText(/증거 조회에 실패했습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(3))
    await screen.findByText(/증거 조회에 실패했습니다/)
    expect(api.post).not.toHaveBeenCalled()
  })
  it('keeps the submitted outcome uncertain when readback comes from another instance', async () => {
    const changed = response(evidence(true))
    changed.headers.set('x-masc-runtime-instance-id', '018f83d7-93a4-7f5d-9a72-abcdef123456')
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockResolvedValueOnce(changed)
    api.post.mockResolvedValue(evidence(true))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(api.post).toHaveBeenCalledTimes(1)
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
    await screen.findByText(/증거 조회에 실패했습니다/)
    expect(api.post).not.toHaveBeenCalled()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
  })
  it('refuses a proof whose criterion differs from the Goal at the same revision', async () => {
    const wrong = evidence()
    wrong.goal.metric = 'different metric'
    api.getWithResponse.mockResolvedValue(response(wrong))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    await screen.findByText(/증거 조회에 실패했습니다/)
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
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/제출한 증명 또는 완료 상태와 일치하지 않습니다/)).toBeNull()
    expect(api.getWithResponse).toHaveBeenCalledTimes(1)
  })
  it('does not accept a response that changes the inspected verifier evidence', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    const wrong = structuredClone(evidence(true))
    wrong.verification.completion.verdict.evidence = 'different evidence'
    api.post.mockResolvedValue(wrong)
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/제출한 증명 또는 완료 상태와 일치하지 않습니다/)).toBeNull()
    expect(api.getWithResponse).toHaveBeenCalledTimes(1)
  })
  it('does not substitute a new proof after a stale POST refusal', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    api.post.mockRejectedValue(new Error('current criterion changed'))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/current criterion changed/)).toBeNull()
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
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(/증거 조회에 실패했습니다/)
    expect(screen.queryByText(/readback offline/)).toBeNull()
    expect(screen.queryByText(/response lost/)).toBeNull()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('request-1')
    fireEvent.click(screen.getByText('이 증명으로 목표 완료 확인'))
    await waitFor(() => expect(api.post).toHaveBeenCalledTimes(2))
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('요청 기록')
  })
  it('does not reveal an earlier error to a different operator using the same credential', async () => {
    const next = structuredClone(evidence())
    next.inspection_operator_id = 'different-operator'
    next.verification.completion.verdict = { ...verdict, request_id: 'new-request', verification_run_id: 'new-run', evidence: 'new proof' }
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockResolvedValueOnce(response(next))
    api.post.mockRejectedValue(new Error('private old error'))
    render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/private old error/)).toBeNull()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('new proof')
    const previous = screen.getByText(/이전 확인 요청 결과 미확인/).textContent ?? ''
    expect(previous).toContain('요청 기록')
    expect(previous).not.toContain('request-1')
    expect(previous).not.toContain('run-1')
    expect(previous).not.toContain('private old error')
  })
  it('does not reveal an earlier server instance’s error after inspecting a replacement', async () => {
    const next = structuredClone(evidence())
    next.verification.completion.verdict = { ...verdict, request_id: 'new-request', verification_run_id: 'new-run', evidence: 'new proof' }
    const replacement = response(next)
    replacement.headers.set('x-masc-execution-publication-epoch', 'epoch-b')
    replacement.headers.set('x-masc-runtime-instance-id', '018f83d7-93a4-7f5d-9a72-abcdef123456')
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockResolvedValueOnce(replacement)
    api.post.mockRejectedValue(new Error('private old error'))
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(/private old error/)).toBeNull()
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults}
      owner=${{ ...owner('goal-1', 'owner-b'), executionEpoch: 'epoch-b' }} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('new proof')
    const previous = screen.getByText(/이전 확인 요청 결과 미확인/).textContent ?? ''
    expect(previous).toContain('요청 기록')
    expect(previous).not.toContain('request-1')
    expect(previous).not.toContain('run-1')
    expect(previous).not.toContain('private old error')
  })
  it('requires a fresh inspection after remount while keeping the earlier uncertain receipt', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    api.post.mockRejectedValue(new Error('response lost'))
    const props = { ...panelDefaults, owner: owner(), isCurrent: current, onConfirmed: vi.fn() }
    const first = render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
    first.unmount()
    render(html`<${GoalConfirmationPanel} ...${props} />`)
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    expect(screen.queryByText(verdict.evidence)).toBeNull()
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    expect(screen.getByText('현재 증거를 다시 조회해 주세요.')).toBeTruthy()
    expect(screen.queryByText('현재 증거의 접근 권한을 다시 확인하는 중입니다.')).toBeNull()
    expect(api.post).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText(verdict.evidence)
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('request-1')
  })
  it('withdraws a dismissed receipt when the tree observation changes', async () => {
    let refresh!: (value: unknown) => void
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockResolvedValueOnce(response(evidence()))
      .mockReturnValueOnce(new Promise(r => { refresh = r }))
    api.post.mockRejectedValue(new Error('response lost'))
    const readAuthority = {}
    const props = { ...panelDefaults, readAuthority, owner: owner(), isCurrent: current, onConfirmed: vi.fn() }
    const ui = render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
    ui.rerender(html`<${GoalConfirmationPanel} ...${{ ...props, readAuthority: {} }} />`)
    expect(screen.queryByText(verdict.evidence)).toBeNull()
    await screen.findByText('인증된 verifier 증거를 불러오는 중...')
    refresh(response(evidence()))
    await screen.findByText(verdict.evidence)
    expect(screen.getByText(/이전 확인 요청 결과 미확인/).textContent).toContain('request-1')
  })
  it('does not leave a retired inspection looking in flight after the tree changes', async () => {
    let retired!: (value: unknown) => void
    api.getWithResponse.mockResolvedValueOnce(response(evidence())).mockReturnValueOnce(new Promise(r => { retired = r }))
    api.post.mockRejectedValue(new Error('response lost'))
    const props = { ...panelDefaults, readAuthority: {}, owner: owner(), isCurrent: current, onConfirmed: vi.fn() }
    const ui = render(html`<${GoalConfirmationPanel} ...${props} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('현재 증거의 접근 권한을 다시 확인하는 중입니다.')
    ui.rerender(html`<${GoalConfirmationPanel} ...${{ ...props, readAuthority: {} }} />`)
    expect(screen.queryByText('현재 증거의 접근 권한을 다시 확인하는 중입니다.')).toBeNull()
    expect(screen.getByText('현재 증거를 다시 조회해 주세요.')).toBeTruthy()
    retired(response(evidence()))
    await waitFor(() => expect(api.getWithResponse).toHaveBeenCalledTimes(2))
    expect(screen.queryByText(verdict.evidence)).toBeNull()
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
    expect(screen.queryByText('인증된 verifier 증거를 불러오는 중...')).toBeNull()
    expect(screen.queryByText(/이전 연결 확인 요청 진행 중/)).toBeNull()
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    resolve(evidence(true))
    await screen.findByText(/다른 연결의 확인 요청 결과가 미확인/)
    expect(screen.queryByText('이 증명으로 목표 완료 확인')).toBeNull()
    fireEvent.click(screen.getByText('현재 증거 다시 조회'))
    await screen.findByText('이 증명으로 목표 완료 확인')
    expect(confirmed).not.toHaveBeenCalled()
    expect(api.post).toHaveBeenCalledTimes(1)
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${confirmed} />`)
    await screen.findByText(/서버에 반영되었을 수 있습니다/)
  })
  it('retains an earlier request without showing its proof across a server reconnect', async () => {
    api.getWithResponse.mockResolvedValue(response(evidence()))
    let resolve!: (value: unknown) => void
    api.post.mockReturnValue(new Promise(r => { resolve = r }))
    const ui = render(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner()} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    fireEvent.click(await screen.findByText('이 증명으로 목표 완료 확인'))
    ui.rerender(html`<${GoalConfirmationPanel} ...${panelDefaults} owner=${owner('goal-1', 'new-epoch')} isCurrent=${current} onConfirmed=${vi.fn()} />`)
    expect((await screen.findByText(/이전 연결 확인 요청 진행 중/)).textContent).toContain('요청 기록')
    expect(screen.queryByText(verdict.evidence)).toBeNull()
    resolve(evidence(true))
    expect((await screen.findByText(/이전 확인 요청 결과 미확인/)).textContent).toContain('요청 기록')
  })
})
