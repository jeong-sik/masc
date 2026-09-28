import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { SetupAccountLogin } from './setup-account-login'
import * as api from '../api/setup-login'
vi.mock('../api/setup-login', () => ({ streamSetupLogin: vi.fn(), sendLoginInput: vi.fn(), cancelSetupLogin: vi.fn(), fetchLoginReceipt: vi.fn() }))
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetAllMocks(); sessionStorage.clear() })
const id = 'a'.repeat(64), account = 'b'.repeat(64), newer = 'c'.repeat(64)
function props() { return { integrationId: 'codex', selected: null, busy: false, onReplaceAccount: vi.fn(), onBusy: vi.fn(), onAccount: vi.fn(), onComplete: vi.fn() } }
it('does not let a delayed cancel response abort a newer login', async () => {
  let emit!: (event: api.LoginEvent) => void
  let resolveFirst!: () => void
  let resolveCancel!: () => void
  const signals: AbortSignal[] = []
  vi.mocked(api.streamSetupLogin).mockImplementation((_source, receive, signal) => {
    emit = receive; signals.push(signal)
    receive({ event: 'started', login_id: id, integration_id: 'codex', account_ref: account })
    return new Promise(resolve => { if (signals.length === 1) resolveFirst = resolve })
  })
  vi.mocked(api.cancelSetupLogin).mockReturnValue(new Promise(resolve => { resolveCancel = resolve }))
  render(html`<${SetupAccountLogin} ...${props()} />`)
  fireEvent.click(screen.getByText('새 계정 로그인')); await screen.findByLabelText('로그인 코드')
  fireEvent.click(screen.getByText('로그인 취소'))
  expect(signals[0]?.aborted).toBe(true)
  emit({ event: 'complete', source: { integration_id: 'codex', account_ref: account }, authentication: 'authenticated' }); resolveFirst()
  await waitFor(() => expect((screen.getByText('새 계정 로그인') as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByText('새 계정 로그인')); await waitFor(() => expect(signals).toHaveLength(2))
  resolveCancel(); await waitFor(() => expect(signals[0]?.aborted).toBe(true))
  expect(signals[1]?.aborted).toBe(false)
})
it('uses the current parent selection instead of an older recovered account', async () => {
  const callbacks = props()
  vi.mocked(api.streamSetupLogin).mockImplementation(async (_source, emit) => {
    emit({ event: 'started', login_id: id, integration_id: 'codex', account_ref: account })
    emit({ event: 'complete', source: { integration_id: 'codex', account_ref: account }, authentication: 'authenticated' })
  })
  const view = render(html`<${SetupAccountLogin} ...${callbacks} />`)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  await waitFor(() => expect(callbacks.onComplete).toHaveBeenCalledOnce())
  view.rerender(html`<${SetupAccountLogin} ...${callbacks} selected=${{ integration_id: 'codex', account_ref: newer }} />`)
  fireEvent.click(screen.getByText('선택한 계정 다시 로그인'))
  await waitFor(() => expect(api.streamSetupLogin).toHaveBeenCalledTimes(2))
  expect(vi.mocked(api.streamSetupLogin).mock.calls[1]?.[0]).toEqual({ integration_id: 'codex', account_ref: newer })
})
it('isolates code submission, holds input until transport acknowledgement and recovers lost completion', async () => {
  let emit!: (event: api.LoginEvent) => void
  let rejectStream!: (reason: Error) => void
  const callbacks = props()
  vi.mocked(api.streamSetupLogin).mockImplementation((_source, receive) => {
    emit = receive
    receive({ event: 'started', login_id: id, integration_id: 'codex', account_ref: account })
    receive({ event: 'output', stream: 'stdout', text: '\x1b[31mOpen https://example.invalid/device\x1b[0m' })
    return new Promise((_resolve, reject) => { rejectStream = reject })
  })
  vi.mocked(api.fetchLoginReceipt).mockResolvedValue({ login_id: id, integration_id: 'codex', status: 'complete',
    account_ref: account, authentication: 'authenticated', invocation_verified: false })
  render(html`<${SetupAccountLogin} ...${callbacks} />`)
  fireEvent.click(screen.getByText('새 계정 로그인')); await screen.findByLabelText('로그인 코드')
  const input = screen.getByLabelText('로그인 코드') as HTMLInputElement
  expect(input.type).toBe('password')
  fireEvent.input(input, { target: { value: 'private-login-code' } }); fireEvent.click(screen.getByText('코드 전달'))
  await waitFor(() => expect(api.sendLoginInput).toHaveBeenCalledWith(id, { kind: 'text', text: 'private-login-code' }, expect.anything()))
  expect(input.value).toBe(''); expect(input.disabled).toBe(true)
  expect(document.body.textContent).not.toContain('private-login-code')
  expect(sessionStorage.getItem('masc.setup.login.codex')).toBe(id)
  expect(screen.getByLabelText('로그인 안내').textContent).toBe('Open https://example.invalid/device')
  emit({ event: 'input_ready' }); await waitFor(() => expect(input.disabled).toBe(false))
  fireEvent.click(screen.getByText('입력 종료 (Ctrl-D)'))
  expect(api.sendLoginInput).toHaveBeenLastCalledWith(id, { kind: 'key', key: 'eof' }, expect.anything())
  rejectStream(new Error('lost final frame'))
  await waitFor(() => expect(callbacks.onComplete).toHaveBeenCalledWith({ integration_id: 'codex', account_ref: account }))
  expect(api.fetchLoginReceipt).toHaveBeenCalledWith(id, 'codex', expect.anything())
})
it('ignores a recovery response after unmount and aborts its request', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  let resolve!: (receipt: api.LoginReceipt) => void
  let signal: AbortSignal | undefined
  vi.mocked(api.fetchLoginReceipt).mockImplementation((_id, _integration, observed) => {
    signal = observed; return new Promise(done => { resolve = done })
  })
  const callbacks = props()
  const view = render(html`<${SetupAccountLogin} ...${callbacks} />`)
  fireEvent.click(await screen.findByText('로그인 상태 다시 확인'))
  await waitFor(() => expect(api.fetchLoginReceipt).toHaveBeenCalledOnce())
  view.unmount()
  expect(signal?.aborted).toBe(true)
  resolve({ login_id: id, integration_id: 'codex', status: 'complete', account_ref: account, authentication: 'authenticated', invocation_verified: false })
  await Promise.resolve()
  expect(callbacks.onComplete).not.toHaveBeenCalled()
})

it('keeps login usable when recovery storage reads, writes and removals are denied', async () => {
  for (const method of ['getItem', 'setItem', 'removeItem'] as const) {
    vi.spyOn(Storage.prototype, method).mockImplementation(() => { throw new DOMException('denied', 'SecurityError') })
  }
  const callbacks = props()
  vi.mocked(api.streamSetupLogin).mockImplementation(async (_source, emit) => {
    emit({ event: 'started', login_id: id, integration_id: 'codex', account_ref: account })
    emit({ event: 'complete', source: { integration_id: 'codex', account_ref: account }, authentication: 'authenticated' })
  })
  render(html`<${SetupAccountLogin} ...${callbacks} />`)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  await waitFor(() => expect(callbacks.onComplete).toHaveBeenCalledOnce())
  expect(screen.getByText('로그인 상태 다시 확인')).toBeTruthy()
  expect((screen.getByText('새 계정 로그인') as HTMLButtonElement).disabled).toBe(false)
})

it('retains the prior receipt when a replacement login fails before starting', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  const callbacks = props()
  vi.mocked(api.streamSetupLogin).mockRejectedValueOnce(new Error('network unavailable'))
  vi.mocked(api.fetchLoginReceipt).mockResolvedValue({ login_id: id, integration_id: 'codex', status: 'running',
    account_ref: account, invocation_verified: false })
  render(html`<${SetupAccountLogin} ...${callbacks} />`)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  await screen.findByText(/로그인을 시작하지 못했습니다/)
  expect(sessionStorage.getItem('masc.setup.login.codex')).toBe(id)
  expect(api.fetchLoginReceipt).not.toHaveBeenCalled()
  fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
  await waitFor(() => expect(api.fetchLoginReceipt).toHaveBeenCalledWith(id, 'codex', expect.anything()))
  expect(callbacks.onReplaceAccount).not.toHaveBeenCalled()
})

it('keeps the prior receipt when the new stream ends before starting', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  vi.mocked(api.streamSetupLogin).mockImplementation(async (_source, emit) => { emit({ event: 'error' }) })
  render(html`<${SetupAccountLogin} ...${props()} />`)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  await screen.findByText(/로그인 절차를 완료하지 못했습니다/)
  expect(sessionStorage.getItem('masc.setup.login.codex')).toBe(id)
  expect(screen.getByText('로그인 상태 다시 확인')).toBeTruthy()
})

it('does not cancel the prior session while a replacement has no ID', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  let reject!: (reason: Error) => void
  vi.mocked(api.streamSetupLogin).mockImplementation(() => new Promise((_resolve, fail) => { reject = fail }))
  render(html`<${SetupAccountLogin} ...${props()} />`)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  fireEvent.click(screen.getByText('로그인 취소'))
  expect(api.cancelSetupLogin).not.toHaveBeenCalled()
  reject(new Error('aborted'))
  await screen.findByText(/로그인을 시작하지 못했습니다/)
  expect(sessionStorage.getItem('masc.setup.login.codex')).toBe(id)
})

it('replaces the prior receipt only when the new login supplies an ID', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  let emit!: (event: api.LoginEvent) => void
  let resolve!: () => void
  vi.mocked(api.streamSetupLogin).mockImplementation((_source, receive) => {
    emit = receive
    return new Promise(done => { resolve = done })
  })
  render(html`<${SetupAccountLogin} ...${props()} />`)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  expect(sessionStorage.getItem('masc.setup.login.codex')).toBe(id)
  expect((screen.getByLabelText('로그인 코드') as HTMLInputElement).disabled).toBe(true)
  emit({ event: 'started', login_id: newer, integration_id: 'codex' })
  await waitFor(() => expect(sessionStorage.getItem('masc.setup.login.codex')).toBe(newer))
  resolve()
})

it('selects a completed recovery after previously observing its unfinished account', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  const callbacks = props()
  vi.mocked(api.fetchLoginReceipt)
    .mockResolvedValueOnce({ login_id: id, integration_id: 'codex', status: 'running', account_ref: account, invocation_verified: false })
    .mockResolvedValueOnce({ login_id: id, integration_id: 'codex', status: 'complete', account_ref: account,
      authentication: 'authenticated', invocation_verified: false })
  render(html`<${SetupAccountLogin} ...${callbacks} />`)
  fireEvent.click(await screen.findByText('로그인 상태 다시 확인'))
  await screen.findByText(/로그인 종료 여부를 아직 확인하지 못했습니다/)
  expect(callbacks.onReplaceAccount).not.toHaveBeenCalled()
  expect(callbacks.onAccount).not.toHaveBeenCalled()
  expect(callbacks.onComplete).not.toHaveBeenCalled()
  fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
  await waitFor(() => expect(callbacks.onComplete).toHaveBeenCalledWith({ integration_id: 'codex', account_ref: account }))
  expect(callbacks.onReplaceAccount).toHaveBeenCalledOnce()
  expect(callbacks.onAccount).toHaveBeenCalledWith({ integration_id: 'codex', account_ref: account })
})
