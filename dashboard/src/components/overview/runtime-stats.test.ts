import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor, act } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { get } from '../../api/core'
import { route } from '../../router'
import { OverviewRuntimeStats } from './runtime-stats'
vi.mock('../../api/core', () => ({ get: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
const response = { window_minutes: 60,
  cost_ledger_read: { state: 'available', malformed_rows: 0, schema_violation_rows: 2, identity_conflict_rows: 1 },
  models: [{ model_id: 'runtime_lane_example', success_count: 8, error_count: 2,
    total_input_tokens: 1234, total_output_tokens: 0, p50_latency_ms: 125, p95_latency_ms: 900,
    usage_sample_count: 6, usage_missing_count: 2, telemetry_sample_count: 5, telemetry_missing_count: 3 }],
}
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
