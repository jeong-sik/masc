import type { Transport, TransportEvent, TransportOptions } from './transport'

const DEFAULT_RETRY_BASE_MS = 1000
const DEFAULT_RETRY_MAX_MS = 30000

export function createHttpStreamableTransport(url: string, opts: TransportOptions = {}): Transport {
  let abortController: AbortController | null = null
  let listeners: Array<(event: TransportEvent) => void> = []
  let retryMs = opts.retryBaseMs ?? DEFAULT_RETRY_BASE_MS
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let connected = false

  const notify = (event: TransportEvent) => {
    listeners.forEach((l) => l(event))
  }

  const connect = () => {
    if (abortController) return
    abortController = new AbortController()
    const { signal } = abortController

    fetch(url, {
      method: 'GET',
      headers: {
        Accept: 'application/x-ndjson',
        ...(opts.headers ?? {}),
      },
      signal,
    })
      .then(async (res) => {
        if (!res.ok || !res.body) {
          throw new Error(`HTTP ${res.status}`)
        }
        connected = true
        retryMs = opts.retryBaseMs ?? DEFAULT_RETRY_BASE_MS
        notify({ type: 'open' })
        const reader = res.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''
        while (!signal.aborted) {
          const { done, value } = await reader.read()
          if (done) break
          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split('\n')
          buffer = lines.pop() ?? ''
          for (const line of lines) {
            if (!line.trim()) continue
            try {
              notify({ type: 'message', data: JSON.parse(line) })
            } catch {
              notify({ type: 'message', data: line })
            }
          }
        }
      })
      .catch((err) => {
        if (signal.aborted) return
        connected = false
        notify({ type: 'error', error: err instanceof Error ? err : new Error(String(err)) })
      })
      .finally(() => {
        abortController = null
        if (!signal.aborted) {
          const maxMs = opts.retryMaxMs ?? DEFAULT_RETRY_MAX_MS
          reconnectTimer = setTimeout(connect, Math.min(retryMs, maxMs))
          retryMs = Math.min(retryMs * 2, maxMs)
        }
      })
  }

  const disconnect = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
    connected = false
    abortController?.abort()
    abortController = null
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
