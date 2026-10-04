import { html } from 'htm/preact'
import { render, fireEvent, screen, waitFor, cleanup } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { RuntimeSetupPicker } from './runtime-setup-picker'
import { post, postControlPlane } from '../api/core'
import { modelSetupResumeState } from '../lib/model-setup-resume'
vi.mock('../api/core', () => { const post = vi.fn(); return { post, postControlPlane: vi.fn((path, body) => post(path, body)) } })
afterEach(() => { cleanup(); vi.resetAllMocks(); modelSetupResumeState.value = { kind: 'idle' } })
const inventory = { source_revision: 'source', setup_revision: 'paired-revision', runtimes: [], integrations: [
  { id: 'openrouter', display_name: 'OpenRouter', protocol: 'openai-compatible-http', setup_support: 'new_connection', endpoint: 'https://openrouter.ai/api/v1' },
] }
it('groups legacy providers by account while preserving both context variants in selection', async () => {
  const grouped = {
    ...inventory,
    integrations: ['first', 'first-wide', 'second'].map(id => ({ id, display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'existing_connection' })),
    account_groups: [
      { id: '1'.repeat(32), integration_ids: ['first', 'first-wide'], runtime_ids: ['first.luna', 'first-wide.luna'] },
      { id: '2'.repeat(32), integration_ids: ['second'], runtime_ids: ['second.luna'] },
    ],
    runtimes: [
      { id: 'first.luna', provider_id: 'first', display_name: 'Codex', protocol: 'codex-app-server', model: 'gpt-6-luna', endpoint: null, max_context: 272000 },
      { id: 'first-wide.luna', provider_id: 'first-wide', display_name: 'Codex', protocol: 'codex-app-server', model: 'gpt-6-luna', endpoint: null, max_context: 500000 },
      { id: 'second.luna', provider_id: 'second', display_name: 'Codex', protocol: 'codex-app-server', model: 'gpt-6-luna', endpoint: null, max_context: 272000 },
    ],
  }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/accounts/select')) return { schema: 'masc.web_setup_account_selection.v1', account_selected: true, invocation_verified: false, account_ref: 'b'.repeat(64) }
    if (path.endsWith('/models')) return { models: [] }
    throw new Error('save unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${grouped} onSaved=${vi.fn()} />`)
  expect(screen.getAllByRole('option')).toHaveLength(3) // prompt and two accounts
  expect(screen.getAllByRole('checkbox')).toHaveLength(3) // every runtime remains selectable
  fireEvent.click(screen.getByLabelText(/11111111.*272,000 context/))
  fireEvent.click(screen.getByLabelText(/500,000 context/))
  expect(screen.getAllByText(/500,000 context/).length).toBeGreaterThan(1)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'first' } })
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/accounts/select', { integration_id: 'first' }))
  await waitFor(() => expect((screen.getByText('검증 후 선택 저장') as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', {
    revision: 'paired-revision', connections: [], selection: [{ runtime_id: 'first.luna' }, { runtime_id: 'first-wide.luna' }],
  }))
})
it.each([{ enabled: false, setup_support: 'new_connection' }, { enabled: true, setup_support: 'unsupported' }])('uses an enabled supported member when the first account connection is unavailable: %j', async unavailable => {
  const grouped = {
    ...inventory,
    integrations: [
      { id: 'unavailable', display_name: 'Codex', protocol: 'codex-app-server', ...unavailable },
      { id: 'available', display_name: 'Codex', protocol: 'codex-app-server', enabled: true, setup_support: 'new_connection' },
    ],
    account_groups: [{ id: 'a'.repeat(32), integration_ids: ['unavailable', 'available'], runtime_ids: [] }],
  }
  vi.mocked(post).mockImplementation(async path => path.endsWith('/accounts/select')
    ? { schema: 'masc.web_setup_account_selection.v1', account_selected: true, invocation_verified: false, account_ref: 'b'.repeat(64) }
    : { models: [] })
  render(html`<${RuntimeSetupPicker} inventory=${grouped} onSaved=${vi.fn()} />`)
  const options = screen.getAllByRole('option') as HTMLOptionElement[]
  expect(options.map(option => option.value)).toEqual(['', 'available'])
  expect(options[1]?.disabled).toBe(false)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'available' } })
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/accounts/select', { integration_id: 'available' }))
})

it('requires a new selection after refresh disables the selected account connection', () => {
  const grouped = {
    ...inventory,
    integrations: ['first', 'second'].map(id => ({ id, display_name: 'Codex', protocol: 'codex-app-server', enabled: true, setup_support: 'new_connection' })),
    account_groups: [{ id: 'a'.repeat(32), integration_ids: ['first', 'second'], runtime_ids: [] }],
  }
  const view = render(html`<${RuntimeSetupPicker} inventory=${grouped} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'first' } })
  const refreshed = { ...grouped, integrations: grouped.integrations.map(row => ({ ...row, enabled: row.id === 'second' })) }
  view.rerender(html`<${RuntimeSetupPicker} inventory=${refreshed} onSaved=${vi.fn()} />`)
  expect((screen.getByLabelText('공급자') as HTMLSelectElement).value).toBe('')
  expect((screen.getAllByRole('option') as HTMLOptionElement[]).map(option => option.value)).toEqual(['', 'second'])
  expect(screen.queryByText('서버 계정 선택 후 모델 목록 확인')).toBeNull()
  expect(post).not.toHaveBeenCalled()
})

it('selects multiple models and default by clicking, hides key, resumes only after verified save', async () => {
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/models')) return { models: [
      { id: 'model-a', label: 'Model A', context: 100000, tools: true },
      { id: 'model-b', label: 'Model B', context: 200000, tools: true },
      { id: 'unknown', label: 'Unknown', context: null, tools: null },
    ] }
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'native-b', runtime_ids: ['native-b', 'native-a'] }
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
  expect(document.body.textContent).not.toContain('추론 노력')
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
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/))
  view.rerender(html`<${RuntimeSetupPicker} inventory=${{ ...initial, setup_revision: 'new-revision' }} onSaved=${vi.fn()} />`)
  vi.mocked(post).mockRejectedValue(new Error('private-backend-secret'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
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
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
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

it('keeps saved success distinct when server activation fails', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'old.id', runtime_ids: ['old.id'] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/모델 저장과 응답·도구 검증은 완료했습니다/)
  expect(screen.queryByText(/연결 저장 결과를 확인하지 못했습니다/)).toBeNull()
  expect(modelSetupResumeState.value.kind).toBe('failed')
})
// A provider that declined the check for the account's usage does not fail the
// save: the runtime is published unmeasured and the notice names it instead of
// saying the model was verified.
it('keeps uncertain durability visible after activation failure without repeating the save', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'unconfirmed', warnings: [] }, readiness: 'verified', runtime_id: 'old.id', runtime_ids: ['old.id'] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/디스크 저장 내구성을 확인하지 못했습니다/)
  expect(screen.queryByText(/연결 저장 결과를 확인하지 못했습니다/)).toBeNull()
  expect(vi.mocked(post).mock.calls.filter(([path]) => path.endsWith('/connections'))).toHaveLength(1)
})
it.each([undefined, { durability: 'unknown' }])('refuses a save receipt with missing or unknown durability %j', async commit => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockResolvedValue({ configured: true, readiness: 'verified', runtime_id: 'old.id', runtime_ids: ['old.id'], commit })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
  expect(vi.mocked(post).mock.calls.filter(([path]) => path.endsWith('/resume'))).toHaveLength(0)
})
it('displays a lock release warning after the committed save without exposing server diagnostics', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [{ code: 'runtime_config_lock_release_unconfirmed', detail: 'private-server-path' }] }, readiness: 'verified', runtime_id: 'old.id', runtime_ids: ['old.id'] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/설정 잠금 해제를 확인하지 못했습니다/)
  expect(document.body.textContent).not.toContain('private-server-path')
  expect(screen.queryByText(/연결 저장 결과를 확인하지 못했습니다/)).toBeNull()
  expect(vi.mocked(post).mock.calls.filter(([path]) => path.endsWith('/connections'))).toHaveLength(1)
})
it.each([undefined, [{ code: 'unknown' }]])('refuses missing or unknown lock warning metadata %j', async warnings => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockResolvedValue({ configured: true, readiness: 'verified', runtime_id: 'old.id', runtime_ids: ['old.id'], commit: { durability: 'durable', warnings } })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
  expect(vi.mocked(post).mock.calls.filter(([path]) => path.endsWith('/resume'))).toHaveLength(0)
})
it('names a runtime saved without the check because of a usage limit', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'usage_limited', runtime_id: 'old.id', runtime_ids: ['old.id'],
      unverified: [{ runtime_id: 'old.id', code: 'quota_exhausted' }] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/사용 한도에 걸려 응답·도구 검증은 못 했습니다: old\.id \(quota_exhausted\)/)
  expect(screen.queryByText(/응답·도구 검증은 완료했습니다/)).toBeNull()
  expect(screen.queryByText(/연결 저장 결과를 확인하지 못했습니다/)).toBeNull()
})
// A save that kept a bound runtime without calling it again is not a
// verification of that runtime, and the notice must not say it was.
it('names a bound runtime the save did not check again', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'partly_checked', runtime_id: 'old.id', runtime_ids: ['old.id'],
      unverified: [], not_rechecked: ['old.id'] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/기존 연결은 이번에 다시 확인하지 않았습니다: old\.id\./)
  expect(screen.queryByText(/응답·도구 검증은 완료했습니다/)).toBeNull()
  expect(screen.queryByText(/연결 저장 결과를 확인하지 못했습니다/)).toBeNull()
})
it('refuses a receipt that reports verified beside a not_rechecked list', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'old.id', runtime_ids: ['old.id'], not_rechecked: ['old.id'] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
})
it('refuses a usage-limited receipt that does not name a saved runtime', async () => {
  const initial = { ...inventory, runtimes: [{ id: 'old.id', provider_id: 'old', display_name: 'Existing', protocol: 'codex-app-server', model: 'Model', endpoint: null }] }
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'usage_limited', runtime_id: 'old.id', runtime_ids: ['old.id'],
      unverified: [{ runtime_id: 'other.id', code: 'quota_exhausted' }] }
    throw new Error('activation unavailable')
  })
  render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
})
it('prepares only the chosen model without a numeric input', async () => {
  vi.mocked(post).mockImplementation(async path => path.endsWith('/models')
    ? { models: [{ id: 'unknown', label: 'Unknown', context: null, tools: null }] }
    : { model: 'unknown', context: 32768, tools: true, context_source: 'serving_endpoint' })
  render(html`<${RuntimeSetupPicker} inventory=${inventory} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'openrouter' } })
  fireEvent.click(screen.getByText('모델 목록 확인')); await screen.findByText('이 모델만 준비')
  fireEvent.click(screen.getByText('이 모델만 준비'))
  await screen.findByText(/실행 context를 확인했습니다/)
  expect(post).toHaveBeenCalledWith('/api/v1/setup/context', { source: { integration_id: 'openrouter', endpoint: 'https://openrouter.ai/api/v1' }, model: 'unknown', load: false })
  expect((screen.getByLabelText('Unknown') as HTMLInputElement).disabled).toBe(false)
  expect(document.querySelector('input[type=number]')).toBeNull()
})
it('uses native Codex discovery without endpoint or credential-path inputs', async () => {
  vi.mocked(post).mockImplementation(async path => path.endsWith('/accounts/select')
    ? { schema: 'masc.web_setup_account_selection.v1', account_selected: true, invocation_verified: false, account_ref: 'b'.repeat(64) }
    : { models: [{ id: 'fresh-model', label: 'Fresh', context: 272000, tools: null,
      supported_reasoning_efforts: ['low', 'high', 'ultra', 'adaptive-v2'], default_reasoning_effort: 'native-auto' }] })
  const cli = { ...inventory, integrations: [{ id: 'codex', display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'new_connection' }] }
  render(html`<${RuntimeSetupPicker} inventory=${cli} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'codex' } })
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인')); await screen.findByLabelText('Fresh')
  expect(screen.getByText('추론 노력 · 기본: native-auto · 지원: low, high, ultra, adaptive-v2')).toBeTruthy()
  expect(screen.getAllByRole('combobox')).toHaveLength(1)
  expect(post).toHaveBeenCalledWith('/api/v1/setup/models', { integration_id: 'codex', account_ref: 'b'.repeat(64) })
  expect(screen.queryByLabelText('서버 API 주소')).toBeNull()
  expect(screen.queryByLabelText('새 연결 API 키')).toBeNull()
})

it('displays a native reported default when the supported effort list is empty', async () => {
  vi.mocked(post).mockImplementation(async path => path.endsWith('/accounts/select')
    ? { schema: 'masc.web_setup_account_selection.v1', account_selected: true, invocation_verified: false, account_ref: 'b'.repeat(64) }
    : { models: [{ id: 'native-default', label: 'Native default', context: 272000, tools: null,
      supported_reasoning_efforts: [], default_reasoning_effort: 'medium' }] })
  const cli = { ...inventory, integrations: [{ id: 'codex', display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'new_connection' }] }
  render(html`<${RuntimeSetupPicker} inventory=${cli} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'codex' } })
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
  await screen.findByText('추론 노력 · 기본: medium · 지원: 보고된 선택지 없음')
  expect((screen.getByLabelText('Native default') as HTMLInputElement).disabled).toBe(false)
})

it('imports an explicitly selected server account and keeps only its opaque reference through context and save', async () => {
  const account_ref = 'a'.repeat(64)
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/accounts/antigravity')) return { schema: 'masc.web_setup_account.v1', account_imported: true, invocation_verified: false, account_ref,
      catalog: { models: [{ id: 'account-model', label: 'Account model', context: null, tools: null }] } }
    if (path.endsWith('/context')) return { model: 'account-model', context: 32768, tools: true }
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'native-account', runtime_ids: ['native-account'] }
    return { runtime_ready: true, exact_output_authority_available: false, model_setup: { status: 'available' } }
  })
  const initial = { ...inventory, integrations: [{ id: 'antigravity', display_name: 'Antigravity', protocol: 'antigravity-cli', setup_support: 'new_connection' }] }
  const view = render(html`<${RuntimeSetupPicker} inventory=${initial} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'antigravity' } })
  expect(post).not.toHaveBeenCalled()
  fireEvent.click(screen.getByText('서버의 로그인된 Antigravity 계정 사용'))
  await screen.findByLabelText(/Account model/)
  expect(post).toHaveBeenCalledWith('/api/v1/setup/accounts/antigravity', { integration_id: 'antigravity' })
  view.rerender(html`<${RuntimeSetupPicker} inventory=${{ ...initial, setup_revision: 'later-revision' }} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByText('이 모델만 준비'))
  await waitFor(() => expect((screen.getByLabelText('Account model') as HTMLInputElement).disabled).toBe(false))
  expect(post).toHaveBeenCalledWith('/api/v1/setup/context', { source: { integration_id: 'antigravity', account_ref }, model: 'account-model', load: false })
  fireEvent.click(screen.getByLabelText('Account model')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', { revision: 'paired-revision',
    connections: [{ source: { integration_id: 'antigravity', account_ref }, models: [{ id: 'account-model', context: 32768, streaming: true }] }],
    selection: [{ connection: 0, model: 0 }] }))
  expect(document.body.textContent).not.toContain(account_ref)
  expect(document.querySelector('input[type="password"]')).toBeNull()
})

it('owns cancellation of a pending save and never treats cancellation as rollback or starts resume', async () => {
  vi.mocked(postControlPlane).mockImplementation((_path, _body, _headers, options) => new Promise((_resolve, reject) => {
    options?.signal?.addEventListener('abort', () => reject(new DOMException('operator cancelled', 'AbortError')), { once: true })
  }))
  const selected = { ...inventory, runtimes: [{ id: 'existing.model', provider_id: 'existing', display_name: 'Existing', model: 'Model', protocol: 'codex-app-server', endpoint: null }] }
  render(html`<${RuntimeSetupPicker} inventory=${selected} onSaved=${vi.fn()} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  fireEvent.click(await screen.findByText('요청 대기 취소'))
  await screen.findByText(/연결 저장 결과를 확인하지 못했습니다/)
  expect(post).not.toHaveBeenCalledWith('/api/v1/runtime/setup/resume', {})
})
it('cancels its pending model discovery when the settings surface unmounts', async () => {
  let observed: AbortSignal | undefined
  vi.mocked(postControlPlane).mockImplementation((_path, _body, _headers, options) => new Promise((_resolve, reject) => {
    observed = options?.signal
    observed?.addEventListener('abort', () => reject(new DOMException('unmounted', 'AbortError')), { once: true })
  }))
  const view = render(html`<${RuntimeSetupPicker} inventory=${inventory} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'openrouter' } }); fireEvent.click(screen.getByText('모델 목록 확인'))
  await waitFor(() => expect(observed).toBeDefined())
  view.unmount(); expect(observed?.aborted).toBe(true)
})

it('does not mistake cancelled account import for missing authentication', async () => {
  vi.mocked(postControlPlane).mockImplementation((_path, _body, _headers, options) => new Promise((_resolve, reject) => {
    options?.signal?.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), { once: true })
  }))
  const accounts = { ...inventory, integrations: [{ id: 'antigravity', display_name: 'Antigravity', protocol: 'antigravity-cli', setup_support: 'new_connection' }] }
  render(html`<${RuntimeSetupPicker} inventory=${accounts} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'antigravity' } })
  fireEvent.click(screen.getByText('서버의 로그인된 Antigravity 계정 사용')); fireEvent.click(await screen.findByText('요청 대기 취소'))
  await screen.findByText(/계정 가져오기 응답 대기를 취소했습니다/)
  expect(screen.queryByText(/계정을 가져오지 못했습니다/)).toBeNull()
})

it('asks no Muse input byte budget and retains account reference through verified save', async () => {
  const account_ref = 'c'.repeat(64)
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/accounts/select')) return { schema: 'masc.web_setup_account_selection.v1', account_selected: true, invocation_verified: false, account_ref }
    if (path.endsWith('/models')) return { source: 'muse_providerCatalog', models: [
      { id: 'muse-selected', label: 'Muse Selected', context: 8192, tools: null },
      { id: 'unknown', label: 'Muse Unknown', context: null, tools: null }] }
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'muse.selected', runtime_ids: ['muse.selected'] }
    return { runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } }
  })
  const cli = { ...inventory, integrations: [{ id: 'muse-code', display_name: 'Muse Code', protocol: 'muse-serve', setup_support: 'new_connection' }] }
  render(html`<${RuntimeSetupPicker} inventory=${cli} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: 'muse-code' } })
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
  await screen.findByLabelText(/Muse Selected/)
  expect((screen.getByLabelText(/Muse Unknown/) as HTMLInputElement).disabled).toBe(true)
  expect(screen.queryByText('이 모델만 준비')).toBeNull()
  expect(screen.queryByText('context 적용')).toBeNull()
  expect(screen.getByText(/Muse가 이 모델의 context를 보고하지 않았습니다/)).toBeTruthy()
  // Muse asks for no input byte limit: selecting a reported model is enough.
  expect(screen.queryByLabelText('Muse 입력 한도 (bytes)')).toBeNull()
  fireEvent.click(screen.getByLabelText(/Muse Selected/))
  expect((screen.getByText('선택한 모델 추가') as HTMLButtonElement).disabled).toBe(false)
  fireEvent.click(screen.getByText('선택한 모델 추가')); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', {
    revision: 'paired-revision', connections: [{ source: { integration_id: 'muse-code', account_ref },
      models: [{ id: 'muse-selected', context: 8192, streaming: true }] }],
    selection: [{ connection: 0, model: 0 }] }))
})

it('cancels a pending resume after save without reporting activation or calling onSaved', async () => {
  let resumeSignal: AbortSignal | undefined
  vi.mocked(postControlPlane).mockImplementation((path, _body, _headers, options) => {
    if (path.endsWith('/connections')) return Promise.resolve({ configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'existing.model', runtime_ids: ['existing.model'] })
    resumeSignal = options?.signal
    return new Promise((_resolve, reject) => resumeSignal?.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), { once: true }))
  })
  const saved = vi.fn()
  const selected = { ...inventory, runtimes: [{ id: 'existing.model', provider_id: 'existing', display_name: 'Existing', model: 'Model', protocol: 'codex-app-server', endpoint: null }] }
  render(html`<${RuntimeSetupPicker} inventory=${selected} onSaved=${saved} />`)
  fireEvent.click(screen.getByLabelText(/Existing · 연결 (old\.id|existing\.model) · Model/)); fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(resumeSignal).toBeDefined())
  fireEvent.click(screen.getByText('요청 대기 취소'))
  await screen.findByText(/설정 적용 응답 대기를 취소했습니다/)
  expect(resumeSignal?.aborted).toBe(true)
  expect(saved).not.toHaveBeenCalled()
  expect(modelSetupResumeState.value.kind).toBe('idle')
  expect(screen.queryByText(/선택한 모델의 응답·도구 호출을 확인하고 저장했습니다/)).toBeNull()
})

it.each([['codex', 'codex-app-server'], ['claude', 'claude-code']])('uses documented %s context without unsupported preparation requests', async (id, protocol) => {
  const account_ref = 'd'.repeat(64)
  vi.mocked(post).mockImplementation(async path => {
    if (path.endsWith('/accounts/select')) return { schema: 'masc.web_setup_account_selection.v1', account_selected: true, invocation_verified: false, account_ref }
    if (path.endsWith('/models')) return { models: [{ id: 'unreported', label: 'Unreported model', context: null, tools: null }] }
    if (path.endsWith('/connections')) return { configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'native.model', runtime_ids: ['native.model'] }
    return { runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } }
  })
  const available = { ...inventory, integrations: [{ id, display_name: id, protocol, setup_support: 'new_connection' }] }
  render(html`<${RuntimeSetupPicker} inventory=${available} onSaved=${vi.fn()} />`)
  fireEvent.change(screen.getByLabelText('공급자'), { target: { value: id } })
  fireEvent.click(screen.getByText('서버 계정 선택 후 모델 목록 확인'))
  const context = await screen.findByLabelText('Unreported model context (tokens)')
  expect(screen.getByText('선택한 계정 모델 목록 새로고침')).toBeTruthy()
  expect(screen.queryByText('이 모델만 준비')).toBeNull()
  expect(screen.getByText(/공식 모델 문서에서 확인한 context/)).toBeTruthy()
  expect((screen.getByLabelText(/Unreported model · 실행 context 확인 필요/) as HTMLInputElement).disabled).toBe(true)
  for (const value of ['0', '-1', '1.5', '9007199254740992']) {
    fireEvent.input(context, { target: { value } })
    expect((screen.getByText('context 적용') as HTMLButtonElement).disabled).toBe(true)
  }
  fireEvent.input(context, { target: { value: '123456' } }); fireEvent.click(screen.getByText('context 적용'))
  fireEvent.click(screen.getByLabelText('Unreported model')); fireEvent.click(screen.getByText('선택한 모델 추가'))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', {
    revision: 'paired-revision', connections: [{ source: { integration_id: id, account_ref }, models: [{ id: 'unreported', context: 123456, streaming: true }] }],
    selection: [{ connection: 0, model: 0 }],
  }))
  expect(vi.mocked(post).mock.calls.some(([path]) => path.endsWith('/context'))).toBe(false)
})

it('identifies grouped accounts by reported email and keeps duplicate runtime connections distinguishable', async () => {
  const grouped = {
    ...inventory,
    integrations: ['personal-a', 'personal-b', 'work'].map(id => ({ id, display_name: id, protocol: 'codex-app-server', setup_support: 'existing_connection' })),
    account_groups: [
      { id: '1'.repeat(32), integration_ids: ['personal-a', 'personal-b'], runtime_ids: ['personal-a.luna', 'personal-b.luna'] },
      { id: '2'.repeat(32), integration_ids: ['work'], runtime_ids: ['work.luna'] },
    ],
    account_emails: [
      { integration_id: 'personal-a', state: 'read', email: 'personal@example.test' },
      { integration_id: 'personal-b', state: 'read', email: 'personal@example.test' },
      { integration_id: 'work', state: 'read', email: 'work@example.test' },
    ],
    runtimes: ['personal-a', 'personal-b', 'work'].map(id => ({ id: `${id}.luna`, provider_id: id, display_name: 'Codex', protocol: 'codex-app-server', model: 'luna', endpoint: null, max_context: 272000 })),
  }
  vi.mocked(post).mockRejectedValue(new Error('stop after observing selection'))
  render(html`<${RuntimeSetupPicker} inventory=${grouped} onSaved=${vi.fn()} />`)
  expect(screen.getByRole('option', { name: /personal@example.test/ })).toBeTruthy()
  expect(screen.getByRole('option', { name: /work@example.test/ })).toBeTruthy()
  fireEvent.click(screen.getByLabelText(/연결 personal-b\.luna/))
  fireEvent.click(screen.getByLabelText(/연결 personal-a\.luna/))
  fireEvent.click(screen.getByText('검증 후 선택 저장'))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/setup/connections', {
    revision: 'paired-revision', connections: [], selection: [{ runtime_id: 'personal-b.luna' }, { runtime_id: 'personal-a.luna' }],
  }))
})
