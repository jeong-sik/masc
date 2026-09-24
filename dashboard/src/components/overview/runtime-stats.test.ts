import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor, act } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { get, post } from '../../api/core'
import { DEFAULT_PANEL_REFRESH_MS } from '../../lib/auto-refresh'
import { route } from '../../router'
import { OverviewRuntimeStats } from './runtime-stats'
import { reloadRuntimeCatalog, runtimeCatalogState } from '../../lib/runtime-catalog-resource'
vi.mock('../../api/core', () => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('../../api/dev-token', () => ({ ensureDevToken: vi.fn(async () => {}) }))
vi.mock('../../lib/runtime-catalog-resource', () => ({
  runtimeCatalogState: { value: { status: 'idle' } },
  loadRuntimeCatalog: vi.fn(),
  reloadRuntimeCatalog: vi.fn(async () => {}),
}))
afterEach(() => { cleanup(); runtimeCatalogState.value = { status: 'idle' }; vi.useRealTimers(); vi.restoreAllMocks(); vi.resetAllMocks() })
beforeEach(() => { vi.mocked(reloadRuntimeCatalog).mockResolvedValue(undefined) })
const response = { window_minutes: 60,
  cost_ledger_read: { state: 'available', malformed_rows: 0, schema_violation_rows: 2, identity_conflict_rows: 1 },
  models: [{ model_id: 'runtime_lane_example', success_count: 8, error_count: 2,
    total_input_tokens: 1234, total_output_tokens: 0, p50_latency_ms: 125, p95_latency_ms: 900,
    usage_sample_count: 6, usage_missing_count: 2, telemetry_sample_count: 5, telemetry_missing_count: 3 }],
}
it('shows each official client account once with its provider-reported usage', async () => {
  runtimeCatalogState.value = { status: 'loaded', data: [
    { provider: 'claude_one.shared', provider_id: 'claude_one', provider_display_name: 'Claude · one', protocol: 'claude-code', available: true, models: [] },
    { provider: 'claude_one.other', provider_id: 'claude_one', provider_display_name: 'Claude · one', protocol: 'claude-code', available: true, models: [] },
    { provider: 'claude_alias.shared', provider_id: 'claude_alias', provider_display_name: 'Claude · alias', protocol: 'claude-code', available: true, models: [] },
    { provider: 'codex_two.shared', provider_id: 'codex_two', provider_display_name: 'Codex · two', protocol: 'codex-app-server', available: false, models: [] },
  ] }
  vi.mocked(get).mockImplementation(async path => path === '/api/v1/runtime/resolved' ? {
    config_path: null, default_runtime: null, runtimes: [], lanes: [], assignments: [],
    provider_usage_windows_since: 1_000,
    provider_usage_windows: [
      { scope: 'account:1', providers: ['claude_one', 'claude_alias'], state: 'reported', windows: [{
        limit_id: null, window: { kind: 'five_hour' }, utilization: { unit: 'fraction', value: 0.67 },
        resets_at: null, observed_at: 1_100, source: 'claude_code.rate_limit_event',
      }] },
      { scope: 'provider:codex_two', providers: ['codex_two'], state: 'not_reported_since_start', windows: [] },
    ],
  } : response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  const accounts = view.getByTestId('overview-official-client-accounts')
  expect(accounts.textContent).toContain('Claude · one')
  expect(accounts.textContent).toContain('Codex · two')
  expect(accounts.textContent?.match(/Claude · one/g)).toHaveLength(1)
  expect(accounts.textContent).toContain('로그인 미측정')
  await waitFor(() => expect(view.getByTestId('overview-client-usage-claude_one').textContent).toContain('5시간 67% 사용'))
  expect(view.getByTestId('overview-client-usage-codex_two').textContent).toContain('서버 시작 이후 미보고')
  expect(view.getByTestId('overview-client-usage-claude_alias').textContent).toContain('5시간 67% 사용')
  expect(view.getByTestId('overview-client-usage-claude_one').textContent).toContain('공유 Client 홈: claude_one, claude_alias')
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
it('shows a catalog failure instead of silently omitting account monitoring', async () => {
  runtimeCatalogState.value = { status: 'error', message: 'HTTP 503' }
  vi.mocked(get).mockResolvedValue(response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('runtime_lane_example')).toBeTruthy())
  expect(view.getByRole('alert').textContent).toContain('공식 Client 계정 목록을 읽지 못했습니다: HTTP 503')
  expect(view.queryByTestId('overview-official-client-accounts')).toBeNull()
})
it('keeps stale values explicit until a refresh returns fresh cache metadata', async () => {
  vi.mocked(get).mockResolvedValueOnce({ ...response,
    cache: { state: 'stale_refreshing', generated_at: 10000, age_s: 2228.4,
      last_error: 'cost ledger temporarily unreadable' } })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText(/집계 갱신 중 · 이전 집계 표시/)).toBeTruthy())
  expect(view.getByText(/응답 시점의 집계 경과/).textContent).toContain('2,228.4초')
  expect(view.getByRole('alert').textContent).toContain('cost ledger temporarily unreadable')
  expect(view.getByRole('table').textContent).toContain('입력 1,234')
  vi.mocked(get).mockResolvedValueOnce({ ...response,
    cache: { state: 'fresh', generated_at: 10001, age_s: 0 } })
  fireEvent.click(view.getByRole('button', { name: '통계 새로 읽기' }))
  await waitFor(() => expect(view.getByText(/서버가 최근 갱신한 집계/)).toBeTruthy())
  expect(view.getByText(/응답 시점의 집계 경과/).textContent).toContain('0초')
  expect(view.queryByText(/이전 집계 표시/)).toBeNull()
  expect(view.queryByRole('alert')).toBeNull()
})
it('does not invent freshness from absent or unsupported cache metadata', async () => {
  vi.mocked(get).mockResolvedValue({ ...response, cache: { state: 'unknown', age_s: -1 } })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('집계 갱신 상태 미보고')).toBeTruthy())
  expect(view.queryByText(/서버가 최근 갱신한 집계/)).toBeNull()
  expect(view.queryByText(/응답 시점의 집계 경과/)).toBeNull()
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
  vi.mocked(get).mockResolvedValue({ window_minutes: undefined, cost_ledger_read: { state: 'unavailable', detail: 'permission denied' },
    models: [{ model_id: 'runtime_lane_missing', success_count: 0, error_count: 2 }] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('permission denied'))
  for (const text of ['입력 미보고', '출력 미보고', 'p95 미보고', '사용량 보고 미보고', '오류 없음 0']) expect(view.getByRole('table').textContent).toContain(text)
  expect(view.getByText(/서버 집계 창:/).textContent).toContain('미보고')
})
it('does not interpret an empty initial cache as zero usage', async () => {
  vi.mocked(get).mockResolvedValue({ window_minutes: 60, total_entries: 0, models: [] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByRole('status').textContent).toContain('초기 캐시 응답'))
  expect(view.queryByRole('table')).toBeNull()
  expect(view.getByText('비용 원장 읽기 상태 미보고')).toBeTruthy()
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

it('follows the real pending cache envelope through to available without operator refresh', async () => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.mocked(get).mockResolvedValueOnce(pending).mockResolvedValueOnce(response)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await act(async () => { await vi.advanceTimersByTimeAsync(0) })
  expect(view.getByRole('status').textContent).toContain('서버가 첫 집계를 준비')
  expect(view.queryByText(/초기 캐시 응답/)).toBeNull()
  expect(view.queryByText('비용 원장 읽기 상태 미보고')).toBeNull()
  await act(async () => { await vi.advanceTimersByTimeAsync(DEFAULT_PANEL_REFRESH_MS) })
  expect(get).toHaveBeenCalledTimes(2)
  expect(view.getByText('runtime_lane_example')).toBeTruthy()
  expect(view.queryByRole('status')).toBeNull()
})

it('stops a pending refresh lifecycle when unmounted', async () => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.mocked(get).mockResolvedValue(pending)
  const view = render(html`<${OverviewRuntimeStats} />`)
  await act(async () => { await vi.advanceTimersByTimeAsync(0) })
  const signal = vi.mocked(get).mock.calls[0]![1]!.signal!
  view.unmount()
  expect(signal.aborted).toBe(true)
  await act(async () => {
    await vi.advanceTimersByTimeAsync(DEFAULT_PANEL_REFRESH_MS)
    window.dispatchEvent(new Event('focus'))
  })
  expect(get).toHaveBeenCalledTimes(1)
})

it('aborts the old pending window and prevents a late follow-up from replacing the new window', async () => {
  vi.useFakeTimers()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  let finishOld!: (value: unknown) => void
  vi.mocked(get).mockResolvedValueOnce(pending)
    .mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    .mockResolvedValueOnce({ ...response, window_minutes: 30 })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await act(async () => { await vi.advanceTimersByTimeAsync(0) })
  await act(async () => { await vi.advanceTimersByTimeAsync(DEFAULT_PANEL_REFRESH_MS) })
  const signal = vi.mocked(get).mock.calls[1]![1]!.signal!
  await act(async () => { fireEvent.change(view.getByLabelText('집계 요청 기간'), { target: { value: '30' } }) })
  expect(signal.aborted).toBe(true)
  await act(async () => { finishOld(pending) })
  expect(view.getByText('runtime_lane_example')).toBeTruthy()
  expect(view.getByText(/서버 집계 창:/).textContent).toContain('30분')
  expect(get).toHaveBeenCalledTimes(3)
})

it('distinguishes an available empty aggregate from a pending initial cache', async () => {
  vi.mocked(get).mockResolvedValue({ ...response, models: [] })
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(view.getByText('반환된 집계에 런타임 기록이 없습니다.')).toBeTruthy())
  expect(view.queryByText(/서버가 첫 집계를 준비/)).toBeNull()
  expect(view.queryByRole('table')).toBeNull()
})
