// @vitest-environment happy-dom
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { startDashboardTransportFallback } from './dashboard-transport-fallback'
import {
  dashboardWsLastError,
  dashboardWsReady,
  dashboardWsSseFallbackActive,
  dashboardWsSseFallbackReason,
} from './dashboard-ws-state'

interface CutoverWindow extends Window {
  __MASC_DASHBOARD_WS_ONLY__?: boolean
}

function fallbackDeps() {
  return {
    connectSse: vi.fn(),
    disconnectSse: vi.fn(),
    sseConnected: signal(false),
  }
}

beforeEach(() => {
  ;(window as CutoverWindow).__MASC_DASHBOARD_WS_ONLY__ = true
  dashboardWsReady.value = false
  dashboardWsLastError.value = null
  dashboardWsSseFallbackActive.value = false
  dashboardWsSseFallbackReason.value = null
  vi.stubGlobal('WebSocket', class MockWebSocket {})
})

afterEach(() => {
  delete (window as CutoverWindow).__MASC_DASHBOARD_WS_ONLY__
  vi.unstubAllGlobals()
})

describe('startDashboardTransportFallback', () => {
  it('starts authenticated SSE after a WS failure and stops it on recovery', () => {
    const deps = fallbackDeps()
    const cleanup = startDashboardTransportFallback(deps)
    expect(deps.connectSse).not.toHaveBeenCalled()

    dashboardWsLastError.value = 'dashboard websocket error'
    expect(deps.connectSse).toHaveBeenCalledTimes(1)
    expect(dashboardWsSseFallbackReason.value).toBe('dashboard websocket error')
    expect(dashboardWsSseFallbackActive.value).toBe(false)

    deps.sseConnected.value = true
    expect(dashboardWsSseFallbackActive.value).toBe(true)

    dashboardWsReady.value = true
    expect(deps.disconnectSse).toHaveBeenCalledTimes(1)
    expect(dashboardWsSseFallbackActive.value).toBe(false)
    expect(dashboardWsSseFallbackReason.value).toBeNull()
    cleanup()
  })

  it('covers a clean reconnect window after the WS was previously ready', () => {
    const deps = fallbackDeps()
    dashboardWsReady.value = true
    const cleanup = startDashboardTransportFallback(deps)

    dashboardWsReady.value = false
    expect(deps.connectSse).toHaveBeenCalledTimes(1)
    expect(dashboardWsSseFallbackReason.value).toBe('dashboard websocket reconnecting')
    cleanup()
    expect(deps.disconnectSse).toHaveBeenCalledTimes(1)
  })

  it('keeps SSE open in explicit parallel mode without labeling it fallback', () => {
    ;(window as CutoverWindow).__MASC_DASHBOARD_WS_ONLY__ = false
    const deps = fallbackDeps()
    const cleanup = startDashboardTransportFallback(deps)

    expect(deps.connectSse).toHaveBeenCalledTimes(1)
    deps.sseConnected.value = true
    expect(dashboardWsSseFallbackActive.value).toBe(false)
    expect(dashboardWsSseFallbackReason.value).toBeNull()
    cleanup()
    expect(deps.disconnectSse).toHaveBeenCalledTimes(1)
  })

  it('falls back when the browser has no WebSocket API and fully disposes', () => {
    vi.stubGlobal('WebSocket', undefined)
    const deps = fallbackDeps()
    const cleanup = startDashboardTransportFallback(deps)

    expect(deps.connectSse).toHaveBeenCalledTimes(1)
    expect(dashboardWsSseFallbackReason.value).toBe('WebSocket API unavailable')
    cleanup()
    dashboardWsLastError.value = 'late error'
    expect(deps.connectSse).toHaveBeenCalledTimes(1)
    expect(deps.disconnectSse).toHaveBeenCalledTimes(1)
  })
})
