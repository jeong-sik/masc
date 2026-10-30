import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Keeper } from '../types'
import type { KeeperMetricsWindow } from '../api/keeper-metrics'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'

const fetchKeeperMetrics = vi.hoisted(() => vi.fn())
const workspace = vi.hoisted(() => ({ current: null as unknown as Signal<ExecutionWorkspaceAuthority | null> }))
vi.mock('../api/keeper-metrics', () => ({ fetchKeeperMetrics }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  workspace.current = signal<ExecutionWorkspaceAuthority | null>(null)
  return { executionWorkspaceAuthority: workspace.current }
})
vi.mock('./keeper-detail-charts', () => ({
  ContextChart: () => null,
  TokenTrendChart: () => null,
  MetricsCharts: ({ keeper }: { keeper: Keeper }) => html`<div data-testid="observed-chart"
    data-value=${keeper.metrics_series?.[0]?.total_tokens} />`,
}))
vi.mock('./keeper-detail-ctx-composition', () => ({ CtxCompositionPanel: () => null }))
vi.mock('./keeper-detail-telemetry', () => ({ InferenceTelemetryPanel: () => null, PromptTelemetryPanel: () => null }))

import { KeeperMetricsPanel } from './keeper-metrics-panel'
import { clearStoredToken, setStoredToken } from '../api/core'

const keeper = { name: 'selected' } as Keeper
const authority = (root: string): ExecutionWorkspaceAuthority => ({ epoch: 'fixture', workspaceRoot: root, connectionGeneration: 1 })
const windowOf = (value: number): KeeperMetricsWindow => ({
  keeper: keeper.name, series: [{ ts: 1, total_tokens: value }] as KeeperMetricsWindow['series'],
  scannedRows: 1, skippedRows: 0, limit: 120,
})
function pending() {
  let resolve!: (value: KeeperMetricsWindow) => void
  let reject!: (error: Error) => void
  const promise = new Promise<KeeperMetricsWindow>((ok, fail) => { resolve = ok; reject = fail })
  return { promise, resolve, reject }
}
const expectValue = async (value: number) => waitFor(() =>
  expect(screen.getByTestId('observed-chart').getAttribute('data-value')).toBe(String(value)))

beforeEach(() => {
  expect(executionWorkspaceAuthority).toBe(workspace.current)
  fetchKeeperMetrics.mockReset()
  workspace.current.value = authority('/workspace-a')
  setStoredToken('credential-a')
})
afterEach(() => { cleanup(); clearStoredToken() })

describe('selected metrics request authority', () => {
  it('withdraws ready metrics on credential change and rejects an older delayed success', async () => {
    const old = pending(), fresh = pending()
    fetchKeeperMetrics.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise)
    render(html`<${KeeperMetricsPanel} keeper=${keeper} />`)
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(1))
    await act(async () => setStoredToken('credential-b'))
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(2))
    await act(async () => fresh.resolve(windowOf(20)))
    await expectValue(20)
    await act(async () => old.resolve(windowOf(10)))
    await expectValue(20)
    const next = pending()
    fetchKeeperMetrics.mockReturnValueOnce(next.promise)
    await act(async () => setStoredToken('credential-c'))
    expect(screen.queryByTestId('observed-chart')).toBeNull()
    await act(async () => next.resolve(windowOf(30)))
    await expectValue(30)
  })

  it('does not revive old success or failure through auth A to B to A', async () => {
    const first = pending(), middle = pending(), latest = pending()
    fetchKeeperMetrics.mockReturnValueOnce(first.promise).mockReturnValueOnce(middle.promise).mockReturnValueOnce(latest.promise)
    render(html`<${KeeperMetricsPanel} keeper=${keeper} />`)
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(1))
    await act(async () => setStoredToken('credential-b'))
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(2))
    await act(async () => setStoredToken('credential-a'))
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(3))
    await act(async () => latest.resolve(windowOf(30)))
    await act(async () => { first.resolve(windowOf(10)); middle.reject(new Error('retired credential failure')) })
    await expectValue(30)
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('withdraws ready data while workspace is unknown and rejects a former workspace reply', async () => {
    fetchKeeperMetrics.mockResolvedValueOnce(windowOf(10))
    render(html`<${KeeperMetricsPanel} keeper=${keeper} />`)
    await expectValue(10)
    await act(async () => { workspace.current.value = null })
    expect(screen.queryByTestId('observed-chart')).toBeNull()
    const old = pending(), fresh = pending()
    fetchKeeperMetrics.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise)
    await act(async () => { workspace.current.value = authority('/workspace-b') })
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(2))
    await act(async () => { workspace.current.value = authority('/workspace-a') })
    await waitFor(() => expect(fetchKeeperMetrics).toHaveBeenCalledTimes(3))
    await act(async () => fresh.resolve(windowOf(30)))
    await act(async () => old.reject(new Error('retired workspace failure')))
    await expectValue(30)
    expect(screen.queryByRole('alert')).toBeNull()
  })
})
