import type { Transport, TransportEvent, TransportOptions } from './transport'

const DEFAULT_RETRY_BASE_MS = 1000
const DEFAULT_RETRY_MAX_MS = 30000

export function createSseTransport(url: string, opts: TransportOptions = {}): Transport {
  let source: EventSource | null = null
  let listeners: Array<(event: TransportEvent) => void> = []
  let retryMs = opts.retryBaseMs ?? DEFAULT_RETRY_BASE_MS
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let connected = false

  const notify = (event: TransportEvent) => {
    listeners.forEach((l) => l(event))
  }

  const connect = () => {
    if (source) return
    try {
      source = new EventSource(url)
      source.onopen = () => {
        connected = true
        retryMs = opts.retryBaseMs ?? DEFAULT_RETRY_BASE_MS
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
        const maxMs = opts.retryMaxMs ?? DEFAULT_RETRY_MAX_MS
        reconnectTimer = setTimeout(connect, Math.min(retryMs, maxMs))
        retryMs = Math.min(retryMs * 2, maxMs)
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
