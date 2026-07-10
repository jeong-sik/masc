import { batch, effect, type ReadonlySignal } from '@preact/signals'
import { dashboardWsOnlyEnabled } from './dashboard-ws-cutover'
import {
  dashboardWsLastError,
  dashboardWsReady,
  dashboardWsSseFallbackActive,
  dashboardWsSseFallbackReason,
} from './dashboard-ws-state'
import { connectSSE, connected as sseConnected, disconnectSSE } from './sse'

interface DashboardTransportFallbackDeps {
  readonly connectSse: () => void
  readonly disconnectSse: () => void
  readonly sseConnected: ReadonlySignal<boolean>
}

const defaultDeps: DashboardTransportFallbackDeps = {
  connectSse: connectSSE,
  disconnectSse: disconnectSSE,
  sseConnected,
}

/** Own the dashboard's mutually exclusive WS-primary/SSE-fallback lifecycle.
 *
 * WS-only mode opens SSE only after a concrete WS failure or after a formerly
 * ready socket enters a reconnect window. Parallel mode keeps SSE open by
 * explicit operator choice. Returning the disposer tears down both the signal
 * effect and any live SSE transport. */
export function startDashboardTransportFallback(
  deps: DashboardTransportFallbackDeps = defaultDeps,
): () => void {
  const wsOnly = dashboardWsOnlyEnabled()
  const webSocketUnavailable = typeof WebSocket === 'undefined'
  let disposed = false
  let sseStarted = false
  let wsWasReady = false

  const ensureSse = () => {
    if (disposed || sseStarted) return
    sseStarted = true
    deps.connectSse()
  }

  const stopSse = () => {
    if (!sseStarted) return
    sseStarted = false
    deps.disconnectSse()
  }

  const disposeEffect = effect(() => {
    const wsReady = dashboardWsReady.value
    const wsError = dashboardWsLastError.value
    const fallbackConnected = deps.sseConnected.value
    if (wsReady) wsWasReady = true

    if (!wsOnly) {
      ensureSse()
      batch(() => {
        dashboardWsSseFallbackActive.value = false
        dashboardWsSseFallbackReason.value = null
      })
      return
    }

    if (wsReady) {
      stopSse()
      batch(() => {
        dashboardWsSseFallbackActive.value = false
        dashboardWsSseFallbackReason.value = null
      })
      return
    }

    const fallbackReason = wsError
      ?? (webSocketUnavailable
        ? 'WebSocket API unavailable'
        : wsWasReady
          ? 'dashboard websocket reconnecting'
          : null)
    if (fallbackReason !== null) {
      ensureSse()
      batch(() => {
        dashboardWsSseFallbackActive.value = sseStarted && fallbackConnected
        dashboardWsSseFallbackReason.value = fallbackReason
      })
      return
    }

    stopSse()
    batch(() => {
      dashboardWsSseFallbackActive.value = false
      dashboardWsSseFallbackReason.value = null
    })
  })

  return () => {
    if (disposed) return
    disposed = true
    disposeEffect()
    stopSse()
    batch(() => {
      dashboardWsSseFallbackActive.value = false
      dashboardWsSseFallbackReason.value = null
    })
  }
}
