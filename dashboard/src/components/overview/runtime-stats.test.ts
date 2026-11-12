import { confirmRuntimeTestWorkspace } from '../../lib/runtime-workspace.test-fixture'
import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor, act } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { get, post } from '../../api/core'
import { publishDashboardObservationChange } from '../../lib/observation-refresh'
import { route } from '../../router'
import { OverviewRuntimeStats } from './runtime-stats'
import { reloadRuntimeCatalog } from '../../lib/runtime-catalog-resource'
vi.mock('../../api/core', async original => ({
  ...await original<typeof import('../../api/core')>(), get: vi.fn(), post: vi.fn(),
}))
vi.mock('../../api/dev-token', () => ({ ensureDevToken: vi.fn(async () => {}) }))
vi.mock('../../api/model-metrics-stream', async original => {
  const { modelMetricsSubscriptionFixture } = await import('../../lib/model-metrics.test-fixture')
  const { decodeRuntimeModelMetricsResponse } = await import('../../api/dashboard-runtime')
  return { ...await original<typeof import('../../api/model-metrics-stream')>(),
    subscribeModelMetricsStream: modelMetricsSubscriptionFixture(async (window, _bucket, options) => {
      const raw = await get(`/api/v1/models/metrics?window=${window}`, options)
      const value = decodeRuntimeModelMetricsResponse(raw)
      if (!value) throw new Error('invalid metrics fixture')
      if (!value.cost_ledger_read || value.cost_ledger_read.state === 'pending') throw new Error('Model metrics stream did not answer its original query')
      return value
    }) }
})
const catalogMock = vi.hoisted(() => ({ value: { status: 'idle' } as (typeof import('../../lib/runtime-catalog-resource').runtimeCatalogState)['value'] }))
vi.mock('../../lib/runtime-catalog-resource', () => ({
  runtimeCatalogState: catalogMock,
  loadRuntimeCatalog: vi.fn(),
  reloadRuntimeCatalog: vi.fn(async () => {}),
}))
afterEach(() => { cleanup(); catalogMock.value = { status: 'idle' }; vi.useRealTimers(); vi.restoreAllMocks(); vi.resetAllMocks() })
beforeEach(() => { confirmRuntimeTestWorkspace(); vi.mocked(reloadRuntimeCatalog).mockResolvedValue(undefined) })
const response = { window_minutes: 60,
  cost_ledger_read: { state: 'available', malformed_rows: 0, schema_violation_rows: 2, identity_conflict_rows: 1 },
  models: [{ model_id: 'runtime_lane_example', success_count: 8, error_count: 2,
    total_input_tokens: 1234, total_output_tokens: 0, p50_latency_ms: 125, p95_latency_ms: 900,
    usage_sample_count: 6, usage_missing_count: 2, telemetry_sample_count: 5, telemetry_missing_count: 3 }],
}
it.each([false, true])('reads and renders HTTP dollar usage with official clients present=%s', async mixed => {
  const http = { provider: 'openrouter.one', runtime_id: 'openrouter.one', provider_id: 'openrouter',
    provider_display_name: 'OpenRouter account', protocol: 'openai-compatible-http', usage_read_configured: true, models: [] }
  catalogMock.value = { status: 'loaded', data: [http,
    { ...http, provider: 'openrouter.two', runtime_id: 'openrouter.two' },
    ...(mixed ? [{ provider: 'codex.one', provider_id: 'codex', protocol: 'codex-app-server', models: [] }] : []),
  ] }
  let utilization: { unit: 'usd'; value: number; limit: number | null } = { unit: 'usd', value: 7.5, limit: 20 }
  vi.mocked(get).mockImplementation(async path => path === '/api/v1/runtime/resolved' ? {
    config_path: null, default_route: null, default_runtime: null, runtimes: [], lanes: [], assignments: [],
    provider_usage_windows: [{ scope: 'account:openrouter', providers: [{ id: 'openrouter', display_name: 'OpenRouter account' }],
      state: 'reported', windows: [{ limit_id: null, window: { kind: 'provider_label', label: 'credit limit' },
        utilization, resets_at: null, observed_at: 1_100, source: 'openrouter.key_read', role: 'gates_model_calls' }] }],
  } : response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByTestId('overview-client-usage-openrouter').textContent).toContain('$7.5000 사용 / $20.0000 한도 · $12.5000 남음'))
  expect(get).toHaveBeenCalledWith('/api/v1/runtime/resolved', expect.anything())
  expect(view.getAllByTestId('overview-client-openrouter')).toHaveLength(1)
  expect(view.getByTestId('overview-client-openrouter').querySelector('button')).toBeNull()
  expect(view.getByTestId('overview-client-openrouter').textContent).not.toContain('로그인 미측정')
  expect(view.queryAllByRole('button', { name: '로그인 확인' })).toHaveLength(mixed ? 1 : 0)
  utilization = { unit: 'usd', value: 21.5, limit: null }
  fireEvent.click(view.getByRole('button', { name: '통계 새로 읽기' }))
  await waitFor(() => expect(view.getByTestId('overview-client-usage-openrouter').textContent).toContain('$21.5000 사용 · 키 한도 없음'))
  expect(view.getByTestId('overview-client-usage-openrouter').textContent).not.toContain('$20.0000 한도')
  expect(post).not.toHaveBeenCalled()
})
it('shows each official client account once with its provider-reported usage', async () => {
  catalogMock.value = { status: 'loaded', data: [
    { provider: 'claude_one.shared', provider_id: 'claude_one', provider_display_name: 'Claude · one', protocol: 'claude-code', available: true, models: [] },
    { provider: 'claude_one.other', provider_id: 'claude_one', provider_display_name: 'Claude · one', protocol: 'claude-code', available: true, models: [] },
    { provider: 'claude_alias.shared', provider_id: 'claude_alias', provider_display_name: 'Claude · alias', protocol: 'claude-code', available: true, models: [] },
    { provider: 'codex_two.shared', provider_id: 'codex_two', provider_display_name: 'Codex · two', protocol: 'codex-app-server', available: false, models: [] },
  ] }
  vi.mocked(get).mockImplementation(async path => path === '/api/v1/runtime/resolved' ? {
    config_path: null, default_route: null, default_runtime: null, runtimes: [], lanes: [], assignments: [],
    provider_usage_windows_since: 1_000,
    provider_usage_windows: [
      { scope: 'account:1', providers: [{ id: 'claude_one', display_name: 'Claude · one' }, { id: 'claude_alias', display_name: 'Claude · alias' }], state: 'reported', windows: [{
        limit_id: null, window: { kind: 'five_hour' }, utilization: { unit: 'fraction', value: 0.67 },
        resets_at: null, observed_at: 1_100, source: 'claude_code.rate_limit_event', role: 'gates_model_calls',
      }] },
      { scope: 'provider:codex_two', providers: [{ id: 'codex_two', display_name: 'Codex · two' }], state: 'not_reported_since_start', windows: [] },
    ],
  } : response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  const accounts = view.getByTestId('overview-provider-accounts')
  expect(accounts.textContent).toContain('Claude · one')
  expect(accounts.textContent).toContain('Codex · two')
  expect(accounts.textContent?.match(/Claude · one/g)).toHaveLength(1)
  expect(accounts.textContent).toContain('로그인 미측정')
  await waitFor(() => expect(view.getByTestId('overview-client-usage-claude_one').textContent).toContain('5시간 67% 사용'))
  expect(view.getByTestId('overview-client-usage-codex_two').textContent).toContain('서버 시작 이후 미보고')
  expect(view.getByTestId('overview-client-usage-claude_alias').textContent).toContain('5시간 67% 사용')
  expect(view.getByTestId('overview-client-usage-claude_one').textContent).toContain('공유 사용량 계정: Claude · one, Claude · alias')
  expect(view.getByText(/아래 토큰·지연 표는 모델명 기준 집계/)).toBeTruthy()
  vi.mocked(post).mockResolvedValue({
    schema: 'masc.dashboard.official-client-probe.v1',
    ok: true,
    runtime_id: 'claude_one.shared',
    client_kind: 'claude_code',
    configured_model: 'shared-model',
    measured_at: 1_000,
    login: {
      status: 'ready', authenticated: true,
      evidence_source: 'configured_executable_self_report',
      identity_verified: false, auth_method: 'claude.ai',
      subscription_type: 'max', api_provider: 'firstParty',
    },
    client: { user_agent: null },
    execution: { status: 'not_measured', reason: 'login_probe_does_not_submit_model_turn' },
  })
  fireEvent.click(view.getByTestId('overview-client-claude_one').querySelector('button')!)
  await waitFor(() => expect(view.getByTestId('overview-client-claude_one').textContent).toContain('CLI 자체 보고: ready'))
  expect(view.getByTestId('overview-client-codex_two').textContent).toContain('로그인 미측정')
  expect(post).toHaveBeenCalledWith('/api/v1/runtime/official-client/probe', { runtime_id: 'claude_one.shared' })
})
it('omits ordinary HTTP/local and Muse rows without a usage-window producer', async () => {
  catalogMock.value = { status: 'loaded', data: [
    { provider: 'plain.model', provider_id: 'plain', protocol: 'openai-compatible-http', usage_read_configured: false, models: [] },
    { provider: 'local.model', provider_id: 'local', protocol: 'ollama-http', models: [] },
    { provider: 'muse.model', provider_id: 'muse', protocol: 'muse-serve', models: [] },
  ] }
  vi.mocked(get).mockResolvedValue(response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  expect(view.queryByTestId('overview-provider-accounts')).toBeNull()
  expect(view.getByText('사용량 창을 보고할 수 있는 제공자 계정이 없습니다.')).toBeTruthy()
  expect(vi.mocked(get).mock.calls.some(([path]) => path === '/api/v1/runtime/resolved')).toBe(false)
})

it('shows a catalog failure instead of silently omitting account monitoring', async () => {
  catalogMock.value = { status: 'error', message: 'HTTP 503' }
  vi.mocked(get).mockResolvedValue(response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  expect(view.getByRole('alert').textContent).toContain('제공자 계정 목록을 읽지 못했습니다: HTTP 503')
  expect(view.queryByTestId('overview-provider-accounts')).toBeNull()
})
it('shows lane measurements and provenance with a direct detail route', async () => {
  vi.mocked(get).mockResolvedValue(response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  const table = view.getByRole('table')
  for (const text of ['입력 1,234', '출력 0', 'p50 125 ms', 'p95 900 ms', '오류 없음 8', '오류 2', '사용량 보고 6 · 누락 2']) expect(table.textContent).toContain(text)
  expect(view.getByText(/서버 집계 창:/).textContent).toContain('60분')
  expect(view.getByText(/비용 원장 읽기 완료/).textContent).toContain('스키마 위반 2')
  const link = view.getByRole('link', { name: '토큰·지연 상세' })
  expect(link.getAttribute('href')).toContain('view=cost')
  fireEvent.click(link)
  expect(route.value.tab).toBe('monitoring')
  expect(route.value.params).toMatchObject({ section: 'runtime', view: 'cost' })
})
it('distinguishes unreported metrics and unavailable ledger from recorded zero', async () => {
  vi.mocked(get).mockResolvedValue({ window_minutes: 60, cost_ledger_read: { state: 'unavailable', detail: 'permission denied' },
    models: [{ model_id: 'runtime_lane_missing', success_count: 0, error_count: 2 }] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('permission denied'))
  for (const text of ['입력 미보고', '출력 미보고', 'p95 미보고', '사용량 보고 미보고', '오류 없음 0']) expect(view.getByRole('table').textContent).toContain(text)
  expect(view.getByText(/서버 집계 창:/).textContent).toContain('60분')
})
it('rejects an empty payload without an answered ledger instead of inventing zero usage', async () => {
  vi.mocked(get).mockResolvedValue({ window_minutes: 60, total_entries: 0, models: [] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('alert')).toBeTruthy())
  expect(view.queryByRole('table')).toBeNull()
})
it.each([{ state: 'draining' }, {}])('rejects unrecognized stream ledger state %j', async ledger => {
  vi.mocked(get).mockResolvedValue({ window_minutes: 60, total_entries: 0, cost_ledger_read: ledger, models: [] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('alert')).toBeTruthy())
  expect(view.queryByText(/서버가 첫 집계를 준비/)).toBeNull()
})
it.each([{}, { models: [null] }, { models: [{}] }])('rejects malformed inventories: %j', async value => {
  vi.mocked(get).mockResolvedValue(value)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('alert')).toBeTruthy())
  expect(view.queryByText(/초기 캐시 응답/)).toBeNull()
  expect(view.queryByRole('table')).toBeNull()
})
it('retries HTTP failure without numeric placeholders', async () => {
  vi.mocked(get).mockRejectedValueOnce(new Error('HTTP 503'))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('HTTP 503'))
  expect(view.queryByRole('table')).toBeNull()
  vi.mocked(get).mockResolvedValueOnce(response)
  fireEvent.click(view.getByRole('button', { name: '통계 새로 읽기' }))
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  expect(view.queryByRole('alert')).toBeNull()
})
it('requests the chosen period and ignores superseded responses', async () => {
  let finishOld!: (value: unknown) => void
  vi.mocked(get).mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(get).toHaveBeenCalledWith('/api/v1/models/metrics?window=60', expect.anything()))
  vi.mocked(get).mockResolvedValueOnce({ ...response, window_minutes: 30 })
  fireEvent.change(view.getByLabelText('집계 요청 기간'), { target: { value: '30' } })
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  expect(get).toHaveBeenLastCalledWith('/api/v1/models/metrics?window=30', expect.anything())
  await act(async () => { finishOld({ window_minutes: 60, models: [] }) })
  expect(view.getByText(/서버 집계 창:/).textContent).toContain('30분')
  expect(view.getByRole('table')).toBeTruthy()
})


const pending = { window_minutes: 60, bucket_minutes: 0, total_entries: 0,
  total_error_entries: 0, cost_ledger_read: { state: 'pending' }, latency_buckets: [], models: [] }

it('rejects the retired pending projection and only resumes on an explicit new reading', async () => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.mocked(get).mockResolvedValueOnce(pending).mockResolvedValueOnce(response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await act(async () => { await vi.advanceTimersByTimeAsync(0) })
  expect(view.getByRole('alert').textContent).toContain('did not answer its original query')
  expect(view.queryByText(/초기 캐시 응답/)).toBeNull()
  expect(view.queryByText('비용 원장 읽기 상태 미보고')).toBeNull()
  await act(async () => { publishDashboardObservationChange({ topic: 'model_metrics' }); await vi.advanceTimersByTimeAsync(0) })
  expect(get).toHaveBeenCalledTimes(1)
  fireEvent.click(view.getByRole('button', { name: '통계 새로 읽기' }))
  await act(async () => { await vi.advanceTimersByTimeAsync(0) })
  expect(view.getByText('runtime_lane_example')).toBeTruthy()
  expect(view.queryByRole('status')).toBeNull()
})

it('cancels its initial reading when unmounted', async () => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.mocked(get).mockImplementation(() => new Promise(() => {}))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await act(async () => { await vi.advanceTimersByTimeAsync(0) })
  const signal = vi.mocked(get).mock.calls[0]![1]!.signal!
  view.unmount()
  expect(signal.aborted).toBe(true)
  await act(async () => {
    publishDashboardObservationChange({ topic: 'model_metrics' }); await vi.advanceTimersByTimeAsync(0)
    window.dispatchEvent(new Event('focus'))
  })
  expect(get).toHaveBeenCalledTimes(1)
})

it('distinguishes an available empty aggregate from a pending initial cache', async () => {
  vi.mocked(get).mockResolvedValue({ ...response, models: [] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('반환된 집계에 런타임 기록이 없습니다.')).toBeTruthy())
  expect(view.queryByText(/서버가 첫 집계를 준비/)).toBeNull()
  expect(view.queryByRole('table')).toBeNull()
})
