import { html } from 'htm/preact'
import { render, fireEvent, screen, waitFor, cleanup } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { OnboardingSettings } from './onboarding-settings'
import { get, post } from '../api/core'
import { modelSetupResumeState } from '../lib/model-setup-resume'
vi.mock('../api/core', () => { const post = vi.fn(); return { get: vi.fn(), post, postControlPlane: vi.fn((path, body) => post(path, body)) } })
vi.mock('../api/setup-login', () => ({ streamSetupLogin: vi.fn(), sendLoginInput: vi.fn(), cancelSetupLogin: vi.fn(), fetchLoginReceipt: vi.fn() }))
import { streamSetupLogin } from '../api/setup-login'
afterEach(() => { cleanup(); vi.resetAllMocks(); modelSetupResumeState.value = { kind: 'idle' } })
function prepare() {
  vi.mocked(get).mockImplementation(async path => path.endsWith('/status') ? {
    schema: 'masc.onboarding_status.v1', base_path: '/workspace', selected_model: null, selected_runtime: null,
    checks: [{ id: 'runtime', condition: 'needs_setup', message: 'Model needs setup', actions: [] },
      { id: 'sandbox', condition: 'needs_verification', message: 'Sandbox needs verification', actions: [] }],
  } : { source_revision: 'fixture-revision', runtimes: [{ id: 'glm.model', provider_id: 'glm', display_name: 'GLM connection', protocol: 'openai-compatible-http', endpoint: 'https://example.test', model: 'model' }] })
}
it('shows model-independent preparation and applies a hidden key without echoing it', async () => {
  prepare(); vi.mocked(post).mockImplementation(async path => path.endsWith('/resume')
    ? { runtime_ready: true, exact_output_authority_available: false, model_setup: { status: 'available' } }
    : { ok: true, configured: true, verification: 'not_run' })
  render(html`<${OnboardingSettings} />`)
  await screen.findByText(/Model needs setup/)
  expect(screen.getByText(/Sandbox needs verification/)).toBeTruthy()
  await screen.findByText('GLM connection')
  fireEvent.change(screen.getByLabelText('연결'), { target: { value: 'glm' } })
  const key = screen.getByLabelText('API 키') as HTMLInputElement
  expect(key.type).toBe('password')
  fireEvent.input(key, { target: { value: 'fixture-private-key' } })
  fireEvent.click(screen.getByText('비공개로 저장'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/credential', { provider_id: 'glm', secret: 'fixture-private-key', source_revision: 'fixture-revision' }))
  await screen.findByText(/모델 응답과 도구 검증은 아직 필요/)
  await screen.findByText(/작업 완료 검증용 모델 연결은 추가 설정/ )
  expect(post).toHaveBeenCalledWith('/api/v1/runtime/setup/resume', {})
  expect(key.value).toBe('')
  expect(document.body.textContent).not.toContain('fixture-private-key')
})
it('never echoes rejected backend diagnostics containing submitted secrets', async () => {
  prepare(); vi.mocked(post).mockRejectedValue(new Error('fixture-private-key rejected'))
  render(html`<${OnboardingSettings} />`)
  await screen.findByText('GLM connection')
  fireEvent.change(screen.getByLabelText('연결'), { target: { value: 'glm' } })
  fireEvent.input(screen.getByLabelText('API 키'), { target: { value: 'fixture-private-key' } })
  fireEvent.click(screen.getByText('비공개로 저장'))
  await screen.findByText(/API 키를 적용하지 못했습니다/)
  expect(document.body.textContent).not.toContain('fixture-private-key')
})

it('mounts official account login in production onboarding and refreshes after verified save', async () => {
  const account_ref = 'b'.repeat(64)
  vi.mocked(get).mockImplementation(async path => path.endsWith('/status') ? {
    schema: 'masc.onboarding_status.v1', base_path: '/workspace', selected_model: null, selected_runtime: null, checks: [],
  } : { source_revision: 'source', setup_revision: 'revision', runtimes: [], integrations: [
    { id: 'codex', display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'new_connection' }] })
  vi.mocked(streamSetupLogin).mockImplementation(async (_source, emit) => {
    emit({ event: 'started', login_id: 'a'.repeat(64), integration_id: 'codex', account_ref })
    emit({ event: 'complete', source: { integration_id: 'codex', account_ref }, authentication: 'authenticated' })
  })
  vi.mocked(post).mockImplementation(async path => path.endsWith('/models')
    ? { models: [{ id: 'model', label: 'Selected model', context: 32000, tools: true }] }
    : path.endsWith('/connections') ? { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'codex.model', runtime_ids: ['codex.model'] }
      : { runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } })
  render(html`<${OnboardingSettings} />`)
  fireEvent.change(await screen.findByLabelText('공급자'), { target: { value: 'codex' } })
  fireEvent.click(screen.getByText('새 계정 로그인'))
  fireEvent.click(await screen.findByLabelText('Selected model'))
  fireEvent.click(screen.getByText('선택한 모델 추가'))
  const initialRefreshes = vi.mocked(get).mock.calls.filter(([path]) => path.endsWith('/inventory')).length
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/선택한 모델의 응답·도구 호출을 확인하고 저장했습니다/)
  await waitFor(() => expect(vi.mocked(get).mock.calls.filter(([path]) => path.endsWith('/inventory')).length).toBeGreaterThan(initialRefreshes))
  expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', expect.objectContaining({ connections: [
    { source: { integration_id: 'codex', account_ref }, models: [{ id: 'model', context: 32000, streaming: true }] }] }))
})

it('releases parent controls when a failed inventory refresh unmounts a busy picker', async () => {
  let failInventory = false
  vi.mocked(get).mockImplementation(async path => {
    if (path.endsWith('/status')) return {
      schema: 'masc.onboarding_status.v1', base_path: '/workspace', selected_model: null, selected_runtime: null, checks: [],
    }
    if (failInventory) throw new Error('inventory unavailable')
    return { source_revision: 'source', setup_revision: 'revision', runtimes: [], integrations: [
      { id: 'codex', display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'new_connection' }] }
  })
  vi.mocked(streamSetupLogin).mockImplementation(async (_source, emit) => {
    emit({ event: 'complete', source: { integration_id: 'codex', account_ref: 'b'.repeat(64) }, authentication: 'authenticated' })
  })
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/models')) return { models: [{ id: 'model', label: 'Selected model', context: 32000, tools: true }] }
    if (path.endsWith('/connections')) {
      failInventory = true
      return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'codex.model', runtime_ids: ['codex.model'] }
    }
    return { runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } }
  })
  render(html`<${OnboardingSettings} />`)
  fireEvent.change(await screen.findByLabelText('공급자'), { target: { value: 'codex' } })
  fireEvent.click(screen.getByText('새 계정 로그인'))
  fireEvent.click(await screen.findByLabelText('Selected model'))
  fireEvent.click(screen.getByText('선택한 모델 추가'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(screen.queryByLabelText('모델 연결 선택')).toBeNull())
  await waitFor(() => expect((screen.getByText('준비 상태 새로고침') as HTMLButtonElement).disabled).toBe(false))
  expect((screen.getByLabelText('API 키') as HTMLInputElement).disabled).toBe(false)
  failInventory = false
  fireEvent.click(screen.getByText('준비 상태 새로고침'))
  await screen.findByLabelText('모델 연결 선택')
})
