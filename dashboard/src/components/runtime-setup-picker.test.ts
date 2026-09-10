import { html } from 'htm/preact'
import { render, fireEvent, screen, waitFor, cleanup } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { RuntimeSetupPicker } from './runtime-setup-picker'
import { post } from '../api/core'
import { modelSetupResumeState } from '../lib/model-setup-resume'
vi.mock('../api/core', () => ({ post: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks(); modelSetupResumeState.value = { kind: 'idle' } })
const inventory = { source_revision: 'source', setup_revision: 'paired-revision', runtimes: [], integrations: [
  { id: 'openrouter', display_name: 'OpenRouter', protocol: 'openai-compatible-http', setup_support: 'new_connection', endpoint: 'https://openrouter.ai/api/v1' },
] }
it('selects multiple models and default by clicking, hides key, resumes only after verified save', async () => {
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/models')) return { models: [
      { id: 'model-a', label: 'Model A', context: 100000, tools: true },
      { id: 'model-b', label: 'Model B', context: 200000, tools: true },
      { id: 'unknown', label: 'Unknown', context: null, tools: null },
    ] }
    if (path.endsWith('/connections')) return { configured: true, readiness: 'verified', runtime_id: 'native-b', runtime_ids: ['native-b', 'native-a'] }
    return { runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } }
  })
  const saved = vi.fn()
  render(html`<${RuntimeSetupPicker} inventory=${inventory} onSaved=${saved} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'openrouter' } })
  const input = screen.getByLabelText('새 연결 API 키') as HTMLInputElement
  expect(input.type).toBe('password')
  fireEvent.input(input, { target: { value: 'fixture-private-key' } })
  fireEvent.click(screen.getByText('모델 목록 확인'))
  await screen.findByLabelText('Model A')
  expect((screen.getByLabelText(/Unknown/) as HTMLInputElement).disabled).toBe(true)
  fireEvent.click(screen.getByLabelText('Model A')); fireEvent.click(screen.getByLabelText('Model B'))
  fireEvent.click(screen.getByText('선택한 모델 추가'))
  expect(input.value).toBe('')
  fireEvent.click(screen.getByText('기본으로 선택'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(saved).toHaveBeenCalledOnce())
  const call = vi.mocked(post).mock.calls.find(([path]) => path.endsWith('/connections'))
  expect(call?.[1]).toEqual({ revision: 'paired-revision', connections: [
    { source: { integration_id: 'openrouter', endpoint: 'https://openrouter.ai/api/v1', api_key: 'fixture-private-key' }, models: [{ id: 'model-b', context: 200000, streaming: true }] },
    { source: { integration_id: 'openrouter', endpoint: 'https://openrouter.ai/api/v1', api_key: 'fixture-private-key' }, models: [{ id: 'model-a', context: 100000, streaming: true }] },
  ], selection: [{ connection: 0, model: 0 }, { connection: 1, model: 0 }] })
  expect(document.body.textContent).not.toContain('fixture-private-key')
  expect(post).toHaveBeenCalledWith('/api/v1/runtime/setup/resume', {})
})
it('keeps selected revision across inventory changes and hides backend errors', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  const view = render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText('Existing · Model'))
  view.rerender(html`<${RuntimeSetupPicker} inventory=${{ ...initial, setup_revision: 'new-revision' }} onSaved=${vi.fn()} />`)
  vi.mocked(post).mockRejectedValue(new Error('private-backend-secret'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결을 저장하지 못했습니다/)
  expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', { revision: 'paired-revision', connections: [], selection: [{ runtime_id: 'old.id' }] })
  expect(post).not.toHaveBeenCalledWith('/api/v1/runtime/setup/resume', {})
  expect(document.body.textContent).not.toContain('private-backend-secret')
})

it('binds a discovered key and models to their original endpoint and revision before addition', async () => {
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/models')) return { models: [{ id: 'model-a', label: 'Model A', context: 100000, tools: true }] }
    throw new Error('configuration changed')
  })
  const view = render(html`<${RuntimeSetupPicker} inventory=${inventory} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'openrouter' } })
  fireEvent.input(screen.getByLabelText('새 연결 API 키'), { target: { value: 'endpoint-a-private-key' } })
  fireEvent.click(screen.getByText('모델 목록 확인'))
  await screen.findByLabelText('Model A')
  const changed = { ...inventory, setup_revision: 'revision-b', integrations: inventory.integrations.map(row => ({ ...row, endpoint: 'https://other.invalid/v1' })) }
  view.rerender(html`<${RuntimeSetupPicker} inventory=${changed} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText('Model A')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결을 저장하지 못했습니다/)
  const body = vi.mocked(post).mock.calls.find(([path]) => path.endsWith('/connections'))?.[1]
  expect(body).toEqual({ revision: 'paired-revision', connections: [{
    source: { integration_id: 'openrouter', endpoint: 'https://openrouter.ai/api/v1', api_key: 'endpoint-a-private-key' },
    models: [{ id: 'model-a', context: 100000, streaming: true }],
  }], selection: [{ connection: 0, model: 0 }] })
  expect(document.body.textContent).not.toContain('endpoint-a-private-key')
})
it('invalidates discovered models when the account key changes', async () => {
  vi.mocked(post).mockResolvedValue({ models: [{ id: 'model-a', label: 'Model A', context: 100000, tools: true }] })
  render(html`<${RuntimeSetupPicker} inventory=${inventory} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'openrouter' } })
  fireEvent.click(screen.getByText('모델 목록 확인')); await screen.findByLabelText('Model A')
  fireEvent.input(screen.getByLabelText('새 연결 API 키'), { target: { value: 'different-account' } })
  expect(screen.queryByLabelText('Model A')).toBeNull()
  expect(screen.queryByText('선택한 모델 추가')).toBeNull()
})
