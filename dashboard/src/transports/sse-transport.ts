import type { Transport, TransportEvent, TransportOptions } from './transport'
import {
  TRANSPORT_RETRY_BASE_MS,
  TRANSPORT_RETRY_JITTER_MS,
  TRANSPORT_RETRY_MAX_ATTEMPTS,
  TRANSPORT_RETRY_MAX_MS,
} from '../config/constants'

export function createSseTransport(url: string, opts: TransportOptions = {}): Transport {
  let source: EventSource | null = null
  let listeners: Array<(event: TransportEvent) => void> = []
  let retryMs = opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let connected = false
  let reconnectAttempts = 0
  let closeNotified = false
  const retryMaxAttempts = opts.retryMaxAttempts ?? TRANSPORT_RETRY_MAX_ATTEMPTS
  const retryJitterMs = opts.retryJitterMs ?? TRANSPORT_RETRY_JITTER_MS

  const notify = (event: TransportEvent) => {
    listeners.forEach((l) => l(event))
  }

  const scheduleReconnect = () => {
    if (reconnectAttempts >= retryMaxAttempts && !closeNotified) {
      closeNotified = true
      notify({ type: 'close' })
    }
    reconnectAttempts += 1
    const maxMs = opts.retryMaxMs ?? TRANSPORT_RETRY_MAX_MS
    const backoff = Math.min(retryMs, maxMs)
    const jitter = Math.random() * retryJitterMs
    reconnectTimer = setTimeout(connect, backoff + jitter)
    retryMs = Math.min(retryMs * 2, maxMs)
  }

  const connect = () => {
    if (source) return
    try {
      source = new EventSource(url)
      source.onopen = () => {
        connected = true
        retryMs = opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
        reconnectAttempts = 0
        closeNotified = false
        notify({ type: 'open' })
      }
      source.onmessage = (ev) => {
        try {
          const data = JSON.parse(ev.data)
          notify({ type: 'message', data })
        } catch {
          notify({ type: 'message', data: ev.data })
        }
      }
      source.onerror = () => {
        connected = false
        notify({ type: 'error', error: new Error('SSE transport error') })
        source?.close()
        source = null
        scheduleReconnect()
      }
    } catch (err) {
      notify({ type: 'error', error: err instanceof Error ? err : new Error(String(err)) })
    }
  }

  const disconnect = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
    connected = false
    retryMs = opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
    reconnectAttempts = 0
    closeNotified = false
    source?.close()
    source = null
    notify({ type: 'close' })
  }

  const subscribe = (listener: (event: TransportEvent) => void) => {
    listeners = [...listeners, listener]
    return () => {
      listeners = listeners.filter((l) => l !== listener)
    }
  }

  return {
    url,
    connect,
    disconnect,
    subscribe,
    isConnected: () => connected,
  }
}
