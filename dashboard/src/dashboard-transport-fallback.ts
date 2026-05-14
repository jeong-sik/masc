import { batch, effect } from '@preact/signals'
import {
  dashboardWsConnected,
  dashboardWsLastError,
  dashboardWsReady,
  dashboardWsSseFallbackActive,
  dashboardWsSseFallbackReason,
} from './dashboard-ws-state'
import { connectSSE, disconnectSSE } from './sse'

interface DashboardSseFallbackOptions {
  wsOnly: boolean
  connect?: () => void
  disconnect?: () => void
  warn?: (message: string, reason: string) => void
}

export function startDashboardSseFallback(options: DashboardSseFallbackOptions): () => void {
  const connect = options.connect ?? connectSSE
  const disconnect = options.disconnect ?? disconnectSSE
  const warn = options.warn ?? ((message, reason) => console.warn(message, reason))
  let active = false

  const clearFallbackState = () => {
    batch(() => {
      dashboardWsSseFallbackActive.value = false
      dashboardWsSseFallbackReason.value = null
    })
  }

  if (!options.wsOnly) {
    clearFallbackState()
    return () => {}
  }

  const enable = (reason: string) => {
    if (active) {
      dashboardWsSseFallbackReason.value = reason
      return
    }
    active = true
    batch(() => {
      dashboardWsSseFallbackActive.value = true
      dashboardWsSseFallbackReason.value = reason
    })
    warn('[dashboard] client WS degraded; enabling SSE fallback', reason)
    connect()
  }

  const disable = () => {
    if (!active) return
    active = false
    disconnect()
    clearFallbackState()
  }

  const dispose = effect(() => {
    if (dashboardWsConnected.value && dashboardWsReady.value) {
      disable()
      return
    }
    const reason = dashboardWsLastError.value
    if (reason) {
      enable(reason)
    }
  })

  return () => {
    dispose()
    disable()
    clearFallbackState()
  }
}
