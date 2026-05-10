import type { Transport, TransportEvent, TransportOptions } from './transport'

const DEFAULT_RETRY_BASE_MS = 1000
const DEFAULT_RETRY_MAX_MS = 30000
const DEFAULT_HEARTBEAT_MS = 30000

export function createWebSocketTransport(url: string, opts: TransportOptions = {}): Transport {
  let ws: WebSocket | null = null
  let listeners: Array<(event: TransportEvent) => void> = []
  let retryMs = opts.retryBaseMs ?? DEFAULT_RETRY_BASE_MS
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let heartbeatTimer: ReturnType<typeof setInterval> | null = null
  let connected = false

  const notify = (event: TransportEvent) => {
    listeners.forEach((l) => l(event))
  }

  const connect = () => {
    if (ws) return
    try {
      ws = new WebSocket(url)
      ws.onopen = () => {
        connected = true
        retryMs = opts.retryBaseMs ?? DEFAULT_RETRY_BASE_MS
        notify({ type: 'open' })
        const heartbeat = opts.heartbeatIntervalMs ?? DEFAULT_HEARTBEAT_MS
        if (heartbeat > 0) {
          heartbeatTimer = setInterval(() => {
            if (ws?.readyState === WebSocket.OPEN) {
              ws.send(JSON.stringify({ type: 'ping' }))
            }
          }, heartbeat)
        }
      }
      ws.onmessage = (ev) => {
        try {
          const data = JSON.parse(ev.data)
          notify({ type: 'message', data })
        } catch {
          notify({ type: 'message', data: ev.data })
        }
      }
      ws.onerror = () => {
        connected = false
        notify({ type: 'error', error: new Error('WebSocket transport error') })
      }
      ws.onclose = () => {
        connected = false
        if (heartbeatTimer) {
          clearInterval(heartbeatTimer)
          heartbeatTimer = null
        }
        ws = null
        notify({ type: 'close' })
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
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer)
      heartbeatTimer = null
    }
    connected = false
    ws?.close()
    ws = null
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
