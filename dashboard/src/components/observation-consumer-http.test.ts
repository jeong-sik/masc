import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { TRANSPORT_RETRY_MAX_MS } from '../config/constants'
import { confirmRuntimeTestWorkspace } from '../lib/runtime-workspace.test-fixture'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { AttributionPanel } from './attribution-panel'
import { LogViewer } from './logs'
import { Overview } from './overview/overview'
import { subscribeToolsAutoRefresh } from './tools/tool-state'
import { subscribeToolSeriesRefresh } from './tools/tool-series-state'

const disposers: Array<() => void> = []

const settle = () => act(async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.dynamicImportSettled()
})

beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('consumer-http-a', { source: 'manual' })
  confirmRuntimeTestWorkspace()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})

afterEach(() => {
  cleanup()
  for (const dispose of disposers.splice(0)) dispose()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('observation consumer HTTP failure identity', () => {
  it.each([
    { name: 'tool inventory', topic: 'tools' as const, subscribe: subscribeToolsAutoRefresh },
    { name: 'tool metrics', topic: 'tool_metrics' as const, subscribe: subscribeToolSeriesRefresh },
  ])('keeps a managed $name refusal terminal until the credential changes', async ({ topic, subscribe }) => {
    const fetch = vi.fn(async () => Response.json({ error: 'refused' }, { status: 403 }))
    vi.stubGlobal('fetch', fetch)
    disposers.push(subscribe())
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_MAX_MS * 4) })
    expect(fetch).toHaveBeenCalledTimes(1)
    await act(async () => { setStoredToken('consumer-http-b', { source: 'manual' }) })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('keeps a wrapped Effect HTTP refusal terminal until the credential changes', async () => {
    const fetch = vi.fn(async () => Response.json({ error: 'refused' }, { status: 403 }))
    vi.stubGlobal('fetch', fetch)
    render(html`<${LogViewer} />`)
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'logs' })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_MAX_MS * 4) })
    expect(fetch).toHaveBeenCalledTimes(1)
    await act(async () => { setStoredToken('consumer-http-b', { source: 'manual' }) })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('does not let a transient aggregate failure hide a refused sibling HTTP read', async () => {
    const fetch = vi.fn(async (path: string) => Response.json({ error: 'source failed' }, {
      status: path.includes('/summary') ? 500 : 403,
    }))
    vi.stubGlobal('fetch', fetch)
    render(html`<${AttributionPanel} />`)
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
    publishDashboardObservationChange({ topic: 'attribution' })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_MAX_MS * 4) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('waits for a later Overview refusal after its telemetry sibling fails', async () => {
    let finishSummary: (response: Response) => void = () => {}
    const summary = new Promise<Response>(resolve => { finishSummary = resolve })
    const fetch = vi.fn(async (path: string) => {
      if (path.includes('/telemetry/summary')) return summary
      return Response.json({ error: 'source failed' }, {
        status: path.includes('/telemetry?') ? 500 : 403,
      })
    })
    const telemetryCallCount = () => fetch.mock.calls.filter(([path]) => path.includes('/telemetry')).length
    vi.stubGlobal('fetch', fetch)
    render(html`<${Overview} />`)
    await settle()
    expect(telemetryCallCount()).toBe(2)
    await act(async () => { finishSummary(Response.json({ error: 'refused' }, { status: 403 })) })
    await settle()
    publishDashboardObservationChange({ topic: 'telemetry' })
    publishDashboardObservationRecovery()
    window.dispatchEvent(new Event('focus'))
    await act(async () => { await vi.advanceTimersByTimeAsync(TRANSPORT_RETRY_MAX_MS * 4) })
    expect(telemetryCallCount()).toBe(2)
    await act(async () => { setStoredToken('consumer-http-b', { source: 'manual' }) })
    await settle()
    expect(telemetryCallCount()).toBe(4)
  })
})
