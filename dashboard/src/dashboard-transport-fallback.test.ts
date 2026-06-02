import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  dashboardWsConnected,
  dashboardWsLastError,
  dashboardWsReady,
  dashboardWsSseFallbackActive,
  dashboardWsSseFallbackReason,
  _resetDashboardWsCounterForTests,
} from './dashboard-ws-state'
import { startDashboardSseFallback } from './dashboard-transport-fallback'

describe('startDashboardSseFallback', () => {
  beforeEach(() => {
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    dashboardWsLastError.value = null
    _resetDashboardWsCounterForTests()
  })

  afterEach(() => {
    dashboardWsLastError.value = null
    _resetDashboardWsCounterForTests()
  })

  it('connects SSE when WS-only mode observes a websocket error', () => {
    const connect = vi.fn()
    const disconnect = vi.fn()
    const dispose = startDashboardSseFallback({
      wsOnly: true,
      connect,
      disconnect,
      warn: vi.fn(),
    })

    dashboardWsLastError.value = 'dashboard websocket rpc timed out: dashboard/ping'

    expect(connect).toHaveBeenCalledTimes(1)
    expect(disconnect).not.toHaveBeenCalled()
    expect(dashboardWsSseFallbackActive.value).toBe(true)
    expect(dashboardWsSseFallbackReason.value).toContain('dashboard/ping')

    dispose()
    expect(disconnect).toHaveBeenCalledTimes(1)
    expect(dashboardWsSseFallbackActive.value).toBe(false)
  })

  it('disconnects fallback SSE when the WS channel becomes ready again', () => {
    const connect = vi.fn()
    const disconnect = vi.fn()
    const dispose = startDashboardSseFallback({
      wsOnly: true,
      connect,
      disconnect,
      warn: vi.fn(),
    })

    dashboardWsLastError.value = 'dashboard websocket closed'
    dashboardWsConnected.value = true
    dashboardWsReady.value = true

    expect(connect).toHaveBeenCalledTimes(1)
    expect(disconnect).toHaveBeenCalledTimes(1)
    expect(dashboardWsSseFallbackActive.value).toBe(false)
    expect(dashboardWsSseFallbackReason.value).toBe(null)

    dispose()
    expect(disconnect).toHaveBeenCalledTimes(1)
  })

  it('does nothing when the dashboard is already in parallel transport mode', () => {
    const connect = vi.fn()
    const disconnect = vi.fn()
    const dispose = startDashboardSseFallback({
      wsOnly: false,
      connect,
      disconnect,
      warn: vi.fn(),
    })

    dashboardWsLastError.value = 'dashboard websocket closed'

    expect(connect).not.toHaveBeenCalled()
    expect(disconnect).not.toHaveBeenCalled()
    expect(dashboardWsSseFallbackActive.value).toBe(false)

    dispose()
  })
})
