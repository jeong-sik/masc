import { html } from 'htm/preact'
import { render as renderDirectly } from 'preact'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
const api = vi.hoisted(() => ({
  fetchRuntimeProviders: vi.fn(), fetchRuntimeResolved: vi.fn(),
  fetchRuntimeModelMetrics: vi.fn(), fetchDashboardRuntimeProbe: vi.fn(), probeOfficialClientLogin: vi.fn(),
}))
vi.mock('../api/dashboard-runtime', async original => ({
  ...await original<typeof import('../api/dashboard-runtime')>(),
  fetchRuntimeResolved: api.fetchRuntimeResolved,
  fetchRuntimeModelMetrics: api.fetchRuntimeModelMetrics,
  probeOfficialClientLogin: api.probeOfficialClientLogin,
}))
vi.mock('../api/dashboard', async original => ({
  ...await original<typeof import('../api/dashboard')>(),
  fetchRuntimeProviders: api.fetchRuntimeProviders,
  fetchDashboardRuntimeProbe: api.fetchDashboardRuntimeProbe,
}))
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { reloadRuntimeCatalog, resetRuntimeCatalog, runtimeCatalogState } from '../lib/runtime-catalog-resource'
import { OverviewRuntimeStats } from './overview/runtime-stats'
import { ConfigResolutionPanel } from './tools/config-resolution-panel'
let epoch = 0, generation = 0
function workspace(name: string | null) {
  expect(hydrateExecutionSnapshot({
    execution_publication_epoch: `observation-audit-${epoch}`,
    execution_publication_generation: ++generation,
    status: { project: 'audit', workspace_root: name === null ? null : `/audit/${name}` },
  } as Parameters<typeof hydrateExecutionSnapshot>[0])).toBe(true)
}
function catalog(name: string) {
  return { providers: [{
    provider: 'shared.model', runtime_id: 'shared.model', provider_id: 'shared',
    provider_display_name: `Catalog ${name}`, protocol: 'claude-code', available: true,
    models: ['model'], note: `workspace-${name}-spec`,
  }] }
}
function metrics(name: string) {
  return { window_minutes: 60, models: [{ model_id: `Only-${name}-metric`,
    success_count: 1, error_count: 0, total_input_tokens: 123,
    total_output_tokens: 12, p50_latency_ms: 5, p95_latency_ms: 8,
    usage_sample_count: 1, usage_missing_count: 0,
    telemetry_sample_count: 1, telemetry_missing_count: 0,
  }] }
}
function resolution(name: string) {
  const path = { path: `/audit/${name}`, exists: true, source: 'workspace' }
  return { status: 'ready', warnings: [], base_path: path, workspace_path: path,
    resolved_base_path: path, data_root: path, prompt_markdown_dir: path,
    source_mismatch: false, server_workspace_mismatch: false, diagnostics: [],
    build: { release_version: 'dev', started_at: '2026-10-04T00:00:00Z', uptime_seconds: 1 },
    keeper_runtime: null, fleet_safety: null, fd_accountant: null,
  }
}
function probe(name: string) {
  return { generated_at: '2026-10-04T00:00:00Z', refreshed_at_unix: 1,
    cache_ttl_sec: 30, cache_hit: false, cache_age_sec: 0, refresh_state: 'served_stale',
    probe: { source: 'runtime.toml', status: 'ok', checked_at: '2026-10-04T00:00:00Z', probe_ok: true,
      summary: { runtimes: 1, probed: 1, reachable: 1, failed: 0, skipped: 0, default_runtime_id: 'shared.model' },
      providers: [{ runtime_id: 'shared.model', provider_id: 'shared', status: 'reachable',
        http_status: 200, latency_ms: 5, probe_url: `https://${name.toLowerCase()}.example.invalid/models`, error: null }],
      observations: [`workspace-${name}-probe`], errors: [], limitations: [],
    },
  }
}
beforeEach(() => {
  resetRuntimeCatalog(); vi.resetAllMocks(); generation = 0
  invalidateExecutionSnapshotGeneration(`observation-audit-${++epoch}`, 0); workspace('A')
  api.fetchRuntimeProviders.mockResolvedValueOnce(catalog('A')).mockResolvedValue(catalog('B'))
  api.fetchRuntimeResolved.mockResolvedValue({ config_path: null, default_runtime: null,
    runtimes: [], lanes: [], assignments: [] })
})
afterEach(() => { cleanup(); resetRuntimeCatalog(); vi.restoreAllMocks() })
it('withdraws A metrics and reads B when workspace changes', async () => {
  api.fetchRuntimeModelMetrics.mockResolvedValueOnce(metrics('A')).mockResolvedValue(metrics('B'))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await view.findByText('Only-A-metric')
  await view.findByText('Catalog A')
  await act(async () => { workspace('B') })
  await view.findByText('Catalog B')
  await view.findByText('Only-B-metric')
  expect(view.queryByText('Only-A-metric')).toBeNull()
  expect(api.fetchRuntimeModelMetrics).toHaveBeenCalledTimes(2)
})
it('discards delayed A metrics after B becomes current', async () => {
  let finishA!: (value: unknown) => void
  api.fetchRuntimeModelMetrics.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
    .mockResolvedValue(metrics('B'))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await view.findByText('Catalog A')
  await waitFor(() => expect(api.fetchRuntimeModelMetrics).toHaveBeenCalledTimes(1))
  const request = api.fetchRuntimeModelMetrics.mock.calls[0]![2] as { signal: AbortSignal }
  await act(async () => { workspace('B') })
  await view.findByText('Catalog B')
  await act(async () => { finishA(metrics('A')) })
  await view.findByText('Only-B-metric')
  expect(view.queryByText('Only-A-metric')).toBeNull()
  expect(request.signal.aborted).toBe(true)
})
it('does not join a delayed A probe to the B runtime spec', async () => {
  let finishA!: (value: unknown) => void
  api.fetchDashboardRuntimeProbe.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
    .mockResolvedValue(probe('B'))
  const view = render(html`<${ConfigResolutionPanel} runtimeResolution=${resolution('A')} />`)
  await waitFor(() => expect(runtimeCatalogState.value).toEqual({ status: 'loaded', data: catalog('A').providers }))
  await waitFor(() => expect(api.fetchDashboardRuntimeProbe).toHaveBeenCalledTimes(1))
  await act(async () => { workspace('B') })
  view.rerender(html`<${ConfigResolutionPanel} runtimeResolution=${resolution('B')} />`)
  await waitFor(() => expect(runtimeCatalogState.value).toEqual({ status: 'loaded', data: catalog('B').providers }))
  await act(async () => { finishA(probe('A')) })
  await view.findByText('workspace-B-probe')
  expect(view.queryByText('workspace-A-probe')).toBeNull()
  expect(view.queryByText('https://a.example.invalid/models')).toBeNull()
  expect(view.getByTestId('runtime-probe-catalog-spec').textContent).toContain('workspace-B-spec')
  expect(api.fetchDashboardRuntimeProbe).toHaveBeenCalledTimes(2)
})

it('withdraws readings and sends no observation requests without a confirmed workspace', async () => {
  api.fetchRuntimeModelMetrics.mockResolvedValueOnce(metrics('A')).mockResolvedValue(metrics('B'))
  api.fetchDashboardRuntimeProbe.mockResolvedValueOnce(probe('A')).mockResolvedValue(probe('B'))
  const view = render(html`<${OverviewRuntimeStats} /><${ConfigResolutionPanel} runtimeResolution=${resolution('A')} />`)
  await view.findByText('Only-A-metric'); await view.findByText('workspace-A-probe')
  await act(async () => { workspace(null) })
  expect(view.queryByText('Only-A-metric')).toBeNull()
  expect(view.queryByText('workspace-A-probe')).toBeNull()
  expect(view.getByRole('button', { name: 'refresh probe' }).hasAttribute('disabled')).toBe(true)
  fireEvent.click(view.getByRole('button', { name: '통계 새로 읽기' }))
  expect(api.fetchRuntimeModelMetrics).toHaveBeenCalledTimes(1)
  expect(api.fetchDashboardRuntimeProbe).toHaveBeenCalledTimes(1)
  await act(async () => { workspace('B') })
  await view.findByText('Only-B-metric'); await view.findByText('workspace-B-probe')
})

it('cannot revive an old A metrics response after A to B to A', async () => {
  let finishA!: (value: unknown) => void
  api.fetchRuntimeProviders.mockReset().mockResolvedValue(catalog('shared'))
  api.fetchRuntimeModelMetrics.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
    .mockResolvedValueOnce(metrics('B')).mockResolvedValue(metrics('new-A'))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(api.fetchRuntimeModelMetrics).toHaveBeenCalledTimes(1))
  await act(async () => { workspace('B') }); await view.findByText('Only-B-metric')
  await act(async () => { workspace('A') }); await view.findByText('Only-new-A-metric')
  await act(async () => { finishA(metrics('old-A')) })
  expect(view.queryByText('Only-old-A-metric')).toBeNull()
  expect(view.getByText('Only-new-A-metric')).toBeTruthy()
})

it('late A errors cannot replace B metrics or probe observations', async () => {
  let failMetrics!: (error: Error) => void, failProbe!: (error: Error) => void
  api.fetchRuntimeModelMetrics.mockImplementationOnce(() => new Promise((_resolve, reject) => { failMetrics = reject }))
    .mockResolvedValue(metrics('B'))
  api.fetchDashboardRuntimeProbe.mockImplementationOnce(() => new Promise((_resolve, reject) => { failProbe = reject }))
    .mockResolvedValue(probe('B'))
  const view = render(html`<${OverviewRuntimeStats} /><${ConfigResolutionPanel} runtimeResolution=${resolution('A')} />`)
  await waitFor(() => expect(api.fetchRuntimeModelMetrics).toHaveBeenCalledTimes(1))
  await waitFor(() => expect(api.fetchDashboardRuntimeProbe).toHaveBeenCalledTimes(1))
  await act(async () => { workspace('B') })
  await view.findByText('Only-B-metric'); await view.findByText('workspace-B-probe')
  await act(async () => { failMetrics(new Error('A metrics failure')); failProbe(new Error('A probe failure')) })
  expect(view.getByText('Only-B-metric')).toBeTruthy()
  expect(view.getByText('workspace-B-probe')).toBeTruthy()
  expect(view.queryByText(/A metrics failure/)).toBeNull()
  expect(view.queryByText(/A probe failure/)).toBeNull()
})

function usage(percent: number) {
  return { config_path: null, default_runtime: null, runtimes: [], lanes: [], assignments: [],
    provider_usage_windows: [{ scope: 'account:shared', providers: [{ id: 'shared', display_name: 'shared' }],
      state: 'reported', windows: [{ window: { kind: 'five_hour' }, utilization: { unit: 'percent', value: percent },
        resets_at: null, observed_at: 1, limit_id: null, source: 'fixture', role: 'gates_model_calls' }] }],
  }
}
it('provider usage responses remain owned by their workspace even when provider IDs match', async () => {
  let finishA!: (value: unknown) => void
  api.fetchRuntimeModelMetrics.mockResolvedValue(metrics('current'))
  api.fetchRuntimeResolved.mockReset().mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
    .mockResolvedValue(usage(20))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await waitFor(() => expect(api.fetchRuntimeResolved).toHaveBeenCalledTimes(1))
  const request = api.fetchRuntimeResolved.mock.calls[0]![0] as { signal: AbortSignal }
  await act(async () => { workspace('B') })
  await view.findByText(/5시간 20% 사용/)
  await act(async () => { finishA(usage(67)) })
  expect(view.queryByText(/5시간 67% 사용/)).toBeNull()
  expect(request.signal.aborted).toBe(true)
})

it('late manual login results never appear on a new workspace account with the same ID', async () => {
  let finishA!: (value: unknown) => void
  api.fetchRuntimeModelMetrics.mockResolvedValue(metrics('current'))
  api.probeOfficialClientLogin.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
  const view = render(html`<${OverviewRuntimeStats} />`)
  await view.findByText('Catalog A')
  fireEvent.click(view.getByRole('button', { name: '로그인 확인' }))
  await waitFor(() => expect(api.probeOfficialClientLogin).toHaveBeenCalledTimes(1))
  await act(async () => { workspace('B') }); await view.findByText('Catalog B')
  await act(async () => { finishA({ runtime_id: 'shared.model', measured_at: 1, login: { status: 'ready', detail: 'Only-A-login' } }) })
  expect(view.queryByText(/Only-A-login/)).toBeNull()
  expect(view.getByText('로그인 미측정')).toBeTruthy()
  expect(api.probeOfficialClientLogin).toHaveBeenCalledTimes(1)
})

it('cancels owned observation requests when the panels unmount', async () => {
  api.fetchRuntimeModelMetrics.mockImplementation(() => new Promise(() => {}))
  api.fetchDashboardRuntimeProbe.mockImplementation(() => new Promise(() => {}))
  const view = render(html`<${OverviewRuntimeStats} /><${ConfigResolutionPanel} runtimeResolution=${resolution('A')} />`)
  await waitFor(() => expect(api.fetchRuntimeModelMetrics).toHaveBeenCalledTimes(1))
  await waitFor(() => expect(api.fetchDashboardRuntimeProbe).toHaveBeenCalledTimes(1))
  const metricsSignal = api.fetchRuntimeModelMetrics.mock.calls[0]![2].signal as AbortSignal
  const probeSignal = api.fetchDashboardRuntimeProbe.mock.calls[0]![1].signal as AbortSignal
  view.unmount()
  expect(metricsSignal.aborted).toBe(true); expect(probeSignal.aborted).toBe(true)
})

it('accepts a login click immediately after the account mounts, before passive effects flush', async () => {
  let finish!: (value: unknown) => void
  api.fetchRuntimeModelMetrics.mockResolvedValue(metrics('current'))
  api.probeOfficialClientLogin.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
  await reloadRuntimeCatalog()
  const container = document.createElement('div'); document.body.append(container)
  try {
    // Direct render and DOM click deliberately avoid testing-library's act
    // wrapper, which would flush the passive effect before the first click.
    renderDirectly(html`<${OverviewRuntimeStats} />`, container)
    const button = container.querySelector('[data-testid="overview-client-shared"] button') as HTMLButtonElement
    button.click()
    await waitFor(() => expect(api.probeOfficialClientLogin).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(button.disabled).toBe(true))
    await act(async () => { finish({ runtime_id: 'shared.model', measured_at: 1, login: { status: 'ready' } }) })
    await waitFor(() => expect(container.textContent).toContain('CLI 자체 보고: ready'))
    expect(button.disabled).toBe(false)
  } finally { renderDirectly(null, container); container.remove() }
})
