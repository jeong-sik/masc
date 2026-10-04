import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { RuntimeSetupPicker } from './runtime-setup-picker'
import * as api from '../api/runtime-setup'
import * as login from '../api/setup-login'
vi.mock('../api/runtime-setup', () => ({ discoverSetupModels: vi.fn(), selectSetupAccount: vi.fn(), importAntigravityAccount: vi.fn(), prepareSetupModel: vi.fn(), saveSetupSelections: vi.fn() }))
vi.mock('../api/setup-login', () => ({ streamSetupLogin: vi.fn(), sendLoginInput: vi.fn(), cancelSetupLogin: vi.fn(), fetchLoginReceipt: vi.fn() }))
vi.mock('../lib/model-setup-resume', () => ({ resumeSavedModelSetup: vi.fn(async () => ({ kind: 'active' })) }))
const account = 'b'.repeat(64), previous = 'c'.repeat(64), id = 'a'.repeat(64)
const model = { id: 'chosen', label: 'Selected Model', context: 32000, tools: true }
const clients = [['codex', 'codex-app-server'], ['claude', 'claude-code'], ['antigravity', 'antigravity-cli'], ['muse', 'muse-serve']] as const
function inventory(integrationId: string, protocol: string) { return { source_revision: 'source', setup_revision: 'revision', runtimes: [],
  integrations: [{ id: integrationId, display_name: integrationId, protocol, setup_support: 'new_connection' }] } }
function renderClient(integrationId: string, protocol: string) {
  const saved = vi.fn()
  const view = render(html`<${RuntimeSetupPicker} inventory=${inventory(integrationId, protocol)} onSaved=${saved} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: integrationId } })
  return { ...view, saved }
}
beforeEach(() => {
  vi.mocked(api.discoverSetupModels).mockResolvedValue([model])
  vi.mocked(api.selectSetupAccount).mockImplementation(async integration_id => ({ integration_id, account_ref: previous }))
  vi.mocked(api.saveSetupSelections).mockResolvedValue({ unverified: [], notRechecked: [], durability: 'durable', lockReleaseUnconfirmed: false })
  vi.mocked(login.streamSetupLogin).mockImplementation(async (source, emit) => {
    emit({ event: 'started', login_id: id, integration_id: source.integration_id, account_ref: account })
    emit({ event: 'complete', source: { integration_id: source.integration_id, account_ref: account }, authentication: 'authenticated' })
  })
})
afterEach(() => { cleanup(); vi.resetAllMocks(); sessionStorage.clear() })
it.each(clients)('%s login binds account through discovery, selection and verified save', async (integrationId, protocol) => {
  const { saved } = renderClient(integrationId, protocol)
  fireEvent.click(screen.getByText('새 계정 로그인'))
  await screen.findByLabelText('Selected Model')
  expect(api.discoverSetupModels).toHaveBeenCalledWith({ integration_id: integrationId, account_ref: account }, expect.anything())
  expect(api.selectSetupAccount).not.toHaveBeenCalled()
  fireEvent.click(screen.getByLabelText('Selected Model'))
  fireEvent.click(screen.getByText('선택한 모델 추가'))
  expect((screen.getByText('선택한 계정 다시 로그인') as HTMLButtonElement).disabled).toBe(false)
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(saved).toHaveBeenCalledOnce())
  expect(api.saveSetupSelections).toHaveBeenCalledWith('revision', [expect.objectContaining({ source: { integration_id: integrationId, account_ref: account } })], expect.anything())
})
it('retains the selected account through failed refresh and adding models', async () => {
  renderClient('codex', 'codex-app-server')
  fireEvent.click(screen.getByText('새 계정 로그인')); await screen.findByLabelText('Selected Model')
  fireEvent.click(screen.getByLabelText('Selected Model')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  vi.mocked(api.discoverSetupModels).mockRejectedValueOnce(new Error('private-provider-error'))
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/))
  await screen.findByText(/설치된 CLI와 로그인 상태를 확인/)
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/)); await screen.findByLabelText('Selected Model')
  expect(api.selectSetupAccount).not.toHaveBeenCalled()
  expect(vi.mocked(api.discoverSetupModels).mock.calls.every(([source]) => source.account_ref === account)).toBe(true)
  expect(document.body.textContent).not.toContain('private-provider-error')
})
it('allows Antigravity refresh after login discovery failed even without credential_kind', async () => {
  vi.mocked(api.discoverSetupModels).mockRejectedValueOnce(new Error('catalog unavailable'))
  renderClient('antigravity', 'antigravity-cli')
  fireEvent.click(screen.getByText('새 계정 로그인')); await screen.findByText(/로그인 자료는 보존되었습니다/)
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/)); await screen.findByLabelText('Selected Model')
  expect(api.discoverSetupModels).toHaveBeenLastCalledWith({ integration_id: 'antigravity', account_ref: account }, expect.anything())
})
it('blocks login and recovery while discovery is pending and discards replies after unmount', async () => {
  let resolve!: (models: api.Model[]) => void
  vi.mocked(api.discoverSetupModels).mockReturnValue(new Promise(done => { resolve = done }))
  sessionStorage.setItem('masc.setup.login.codex', id)
  const view = renderClient('codex', 'codex-app-server')
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/))
  await waitFor(() => expect(api.discoverSetupModels).toHaveBeenCalledOnce())
  expect((screen.getByText('새 계정 로그인') as HTMLButtonElement).disabled).toBe(true)
  expect((screen.getByText('로그인 상태 다시 확인') as HTMLButtonElement).disabled).toBe(true)
  view.unmount(); resolve([model])
  await Promise.resolve()
  expect(login.streamSetupLogin).not.toHaveBeenCalled()
})
it('recovering a different account removes earlier model selections before loading its catalog', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  renderClient('codex', 'codex-app-server')
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/)); await screen.findByLabelText('Selected Model')
  fireEvent.click(screen.getByLabelText('Selected Model')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  expect(screen.getByRole('list', { name: '기본 모델과 대체 순서' })).toBeTruthy()
  vi.mocked(login.fetchLoginReceipt).mockResolvedValue({ login_id: id, integration_id: 'codex', status: 'complete',
    account_ref: account, authentication: 'authenticated', invocation_verified: false })
  fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
  await screen.findByLabelText('Selected Model')
  expect(screen.queryByRole('list', { name: '기본 모델과 대체 순서' })).toBeNull()
  expect(api.discoverSetupModels).toHaveBeenLastCalledWith({ integration_id: 'codex', account_ref: account }, expect.anything())
})

it.each(['failed', 'running', 'complete'] as const)('checking a %s receipt for the selected account preserves choices', async status => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  renderClient('codex', 'codex-app-server')
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/)); await screen.findByLabelText('Selected Model')
  fireEvent.click(screen.getByLabelText('Selected Model')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  vi.mocked(login.fetchLoginReceipt).mockResolvedValue({ login_id: id, integration_id: 'codex', status,
    account_ref: previous, ...(status === 'complete' ? { authentication: 'authenticated' as const } : {}), invocation_verified: false })
  fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
  await waitFor(() => expect((screen.getByText('로그인 상태 다시 확인') as HTMLButtonElement).disabled).toBe(false))
  expect(screen.getByRole('list', { name: '기본 모델과 대체 순서' })).toBeTruthy()
  expect(api.discoverSetupModels).toHaveBeenCalledOnce()
})
it('a failed receipt request preserves the current choices', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  renderClient('codex', 'codex-app-server')
  fireEvent.click(screen.getByText(/서버 계정 선택 후 모델 목록 확인|선택한 계정 모델 목록 새로고침/)); await screen.findByLabelText('Selected Model')
  fireEvent.click(screen.getByLabelText('Selected Model')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  vi.mocked(login.fetchLoginReceipt).mockRejectedValue(new Error('unavailable'))
  fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
  await screen.findByText(/로그인 결과를 확인하지 못했습니다/)
  expect(screen.getByRole('list', { name: '기본 모델과 대체 순서' })).toBeTruthy()
})

it.each(['running', 'failed', 'cancelled', 'interrupted'] as const)(
  'recovering a different %s account preserves the selected account and model choices', async status => {
    sessionStorage.setItem('masc.setup.login.codex', id)
    renderClient('codex', 'codex-app-server')
    fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
    await screen.findByLabelText('Selected Model')
    fireEvent.click(screen.getByLabelText('Selected Model'))
    fireEvent.click(screen.getByText('선택한 모델 추가'))
    vi.mocked(login.fetchLoginReceipt).mockResolvedValue({ login_id: id, integration_id: 'codex', status,
      account_ref: account, invocation_verified: false })
    fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
    await screen.findByText(status === 'running' ? /로그인 종료 여부를 아직 확인하지 못했습니다/ : /로그인이 중단되었습니다/)
    expect(screen.getByRole('list', { name: '기본 모델과 대체 순서' })).toBeTruthy()
    expect(api.discoverSetupModels).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByText('선택한 계정 모델 목록 새로고침'))
    await screen.findByLabelText('Selected Model')
    expect(api.discoverSetupModels).toHaveBeenLastCalledWith({ integration_id: 'codex', account_ref: previous }, expect.anything())
    fireEvent.click(screen.getByText('검증 후 선택 저장'))
    await waitFor(() => expect(api.saveSetupSelections).toHaveBeenCalledOnce())
    expect(api.saveSetupSelections).toHaveBeenCalledWith('revision', [expect.objectContaining({
      source: { integration_id: 'codex', account_ref: previous },
    })], expect.anything())
  },
)

it('explicitly retries a different recovered account without replacing choices before completion', async () => {
  sessionStorage.setItem('masc.setup.login.codex', id)
  renderClient('codex', 'codex-app-server')
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
  await screen.findByLabelText('Selected Model')
  fireEvent.click(screen.getByLabelText('Selected Model'))
  fireEvent.click(screen.getByText('선택한 모델 추가'))
  vi.mocked(login.fetchLoginReceipt).mockResolvedValue({ login_id: id, integration_id: 'codex', status: 'interrupted',
    account_ref: account, invocation_verified: false })
  fireEvent.click(screen.getByText('로그인 상태 다시 확인'))
  let emit!: (event: login.LoginEvent) => void
  let complete!: () => void
  vi.mocked(login.streamSetupLogin).mockImplementation((_source, receive) => {
    emit = receive
    receive({ event: 'started', login_id: id, integration_id: 'codex', account_ref: account })
    return new Promise(resolve => { complete = resolve })
  })
  fireEvent.click(await screen.findByText('중단된 계정 다시 로그인'))
  await waitFor(() => expect(login.streamSetupLogin).toHaveBeenCalledWith(
    { integration_id: 'codex', account_ref: account }, expect.anything(), expect.anything()))
  expect(screen.getByRole('list', { name: '기본 모델과 대체 순서' })).toBeTruthy()
  expect(screen.getByText('선택한 계정 모델 목록 새로고침')).toBeTruthy()
  expect(api.discoverSetupModels).toHaveBeenCalledOnce()
  emit({ event: 'complete', source: { integration_id: 'codex', account_ref: account }, authentication: 'authenticated' })
  complete()
  await screen.findByLabelText('Selected Model')
  expect(screen.queryByRole('list', { name: '기본 모델과 대체 순서' })).toBeNull()
  expect(api.discoverSetupModels).toHaveBeenLastCalledWith({ integration_id: 'codex', account_ref: account }, expect.anything())
})

it.each([['codex', 'codex-app-server'], ['claude', 'claude-code']])('%s account replacement clears hidden sibling connections but preserves another account', async (client, protocol) => {
  const first = `${client}-one`, sibling = `${client}-two`, other = `${client}-other`
  const grouped = {
    ...inventory(first, protocol),
    integrations: [first, sibling, other].map(id => ({ id, display_name: id, protocol, setup_support: 'existing_connection' })),
    account_groups: [{ id: '1'.repeat(64), integration_ids: [first, sibling], runtime_ids: [`${first}.luna`, `${sibling}.luna`] }],
    runtimes: [first, sibling, other].map(id => ({ id: `${id}.luna`, provider_id: id, display_name: id, protocol, model: 'luna', endpoint: null })),
  }
  render(html`<${RuntimeSetupPicker} inventory=${grouped} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(new RegExp(`연결 ${sibling}\\.luna`)))
  fireEvent.click(screen.getByLabelText(new RegExp(`연결 ${other}\\.luna`)))
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: first } })
  fireEvent.click(screen.getByText('새 계정 로그인'))
  await screen.findByLabelText('Selected Model')
  expect((screen.getByLabelText(new RegExp(`연결 ${sibling}\\.luna`)) as HTMLInputElement).checked).toBe(false)
  expect((screen.getByLabelText(new RegExp(`연결 ${other}\\.luna`)) as HTMLInputElement).checked).toBe(true)
  fireEvent.click(screen.getByLabelText('Selected Model'))
  fireEvent.click(screen.getByText('선택한 모델 추가'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(api.saveSetupSelections).toHaveBeenCalled())
  const choices = vi.mocked(api.saveSetupSelections).mock.calls[0]![1]
  expect(choices).toMatchObject([
    { kind: 'existing', id: `${other}.luna` },
    { kind: 'new', source: { integration_id: first, account_ref: account } },
  ])
})
