import { html } from 'htm/preact'
import { render, fireEvent, screen, waitFor, cleanup } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { OnboardingSettings } from './onboarding-settings'
import { get, post } from '../api/core'
vi.mock('../api/core', () => ({ get: vi.fn(), post: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
function prepare() {
  vi.mocked(get).mockImplementation(async path => path.endsWith('/status') ? {
    schema: 'masc.onboarding_status.v1', base_path: '/workspace', selected_model: null, selected_runtime: null,
    checks: [{ id: 'runtime', condition: 'needs_setup', message: 'Model needs setup', actions: [] },
      { id: 'sandbox', condition: 'needs_verification', message: 'Sandbox needs verification', actions: [] }],
  } : { source_revision: 'fixture-revision', runtimes: [{ id: 'glm.model', provider_id: 'glm', display_name: 'GLM connection', protocol: 'openai-compatible-http', endpoint: 'https://example.test', model: 'model' }] })
}
it('shows model-independent preparation and applies a hidden key without echoing it', async () => {
  prepare(); vi.mocked(post).mockResolvedValue({ ok: true, configured: true, verification: 'not_run' })
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
