import type { Transport, TransportEvent, TransportOptions } from './transport'
import {
  TRANSPORT_RETRY_BASE_MS,
  TRANSPORT_RETRY_JITTER_MS,
  TRANSPORT_RETRY_MAX_ATTEMPTS,
  TRANSPORT_RETRY_MAX_MS,
} from '../config/constants'

interface SseParserCallbacks {
  readonly onData: (data: unknown) => void
  readonly onId: (id: string) => void
  readonly onRetry: (retryMs: number) => void
}

/** Incremental WHATWG event-stream parser.
 *
 * Line endings may be CRLF, lone CR, or lone LF and may straddle decoded
 * chunks. `id` and `retry` update transport state even when an event block has
 * no data. EOF deliberately discards a pending, unterminated event. */
function createSseParser(callbacks: SseParserCallbacks) {
  let lineBuffer = ''
  let skipLfAfterCr = false
  let atStreamStart = true
  const dataLines: string[] = []

  const dispatch = () => {
    if (dataLines.length === 0) return
    const raw = dataLines.join('\n')
    dataLines.length = 0
    try {
      callbacks.onData(JSON.parse(raw))
    } catch {
      callbacks.onData(raw)
    }
  }

  const processLine = (line: string) => {
    if (line === '') {
      dispatch()
      return
    }
    if (line.startsWith(':')) return

    const separator = line.indexOf(':')
    const field = separator < 0 ? line : line.slice(0, separator)
    let value = separator < 0 ? '' : line.slice(separator + 1)
    if (value.startsWith(' ')) value = value.slice(1)

    if (field === 'data') {
      dataLines.push(value)
    } else if (field === 'id') {
      if (!value.includes('\0')) callbacks.onId(value)
    } else if (field === 'retry' && /^[0-9]+$/.test(value)) {
      const retryMs = Number(value)
      if (Number.isSafeInteger(retryMs)) callbacks.onRetry(retryMs)
    }
  }

  const push = (chunk: string) => {
    for (const character of chunk) {
      if (atStreamStart) {
        atStreamStart = false
        if (character === '\uFEFF') continue
      }
      if (skipLfAfterCr) {
        skipLfAfterCr = false
        if (character === '\n') continue
      }
      if (character === '\r') {
        processLine(lineBuffer)
        lineBuffer = ''
        skipLfAfterCr = true
      } else if (character === '\n') {
        processLine(lineBuffer)
        lineBuffer = ''
      } else {
        lineBuffer += character
      }
    }
  }

  const finish = () => {
    lineBuffer = ''
    dataLines.length = 0
    skipLfAfterCr = false
  }

  return { push, finish }
}

export function createSseTransport(url: string, opts: TransportOptions = {}): Transport {
  let source: EventSource | null = null
  let fetchController: AbortController | null = null
  let fetchReader: ReadableStreamDefaultReader<Uint8Array> | null = null
  let listeners: Array<(event: TransportEvent) => void> = []
  let retryMs = opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
  let serverRetryMs: number | null = null
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let connected = false
  let reconnectAttempts = 0
  let closeNotified = false
  let stopped = true
  let lastEventId: string | null = null
  const retryMaxAttempts = opts.retryMaxAttempts ?? TRANSPORT_RETRY_MAX_ATTEMPTS
  const retryJitterMs = opts.retryJitterMs ?? TRANSPORT_RETRY_JITTER_MS
  const useAuthenticatedFetch = Object.keys(opts.headers ?? {}).length > 0

  const notify = (event: TransportEvent) => {
    listeners.forEach((l) => l(event))
  }

  const scheduleReconnect = () => {
    if (stopped || reconnectTimer) return
    if (reconnectAttempts >= retryMaxAttempts && !closeNotified) {
      closeNotified = true
      notify({ type: 'close' })
    }
    reconnectAttempts += 1
    const maxMs = opts.retryMaxMs ?? TRANSPORT_RETRY_MAX_MS
    const backoff = Math.min(retryMs, maxMs)
    const jitter = Math.random() * retryJitterMs
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null
      connect()
    }, backoff + jitter)
    retryMs = Math.min(retryMs * 2, maxMs)
  }

  const connectWithFetch = () => {
    const controller = new AbortController()
    fetchController = controller
    void (async () => {
      let reader: ReadableStreamDefaultReader<Uint8Array> | null = null
      try {
        const headers: Record<string, string> = {
          Accept: 'text/event-stream',
          ...opts.headers,
        }
        if (lastEventId !== null) headers['Last-Event-ID'] = lastEventId
        const response = await fetch(url, {
          method: 'GET',
          headers,
          cache: 'no-store',
          signal: controller.signal,
        })
        if (stopped || controller.signal.aborted || fetchController !== controller) return
        if (!response.ok) {
          throw new Error(`SSE transport request failed (${response.status})`)
        }
        const contentType = response.headers.get('content-type') ?? ''
        if (!contentType.toLowerCase().includes('text/event-stream')) {
          throw new Error(`SSE transport returned unexpected content type: ${contentType || 'missing'}`)
        }
        if (!response.body) throw new Error('SSE transport response body unavailable')

        connected = true
        retryMs = serverRetryMs ?? opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
        reconnectAttempts = 0
        closeNotified = false
        notify({ type: 'open' })

        reader = response.body.getReader()
        fetchReader = reader
        const decoder = new TextDecoder()
        const parser = createSseParser({
          onData: (data) => notify({ type: 'message', data }),
          onId: (id) => {
            lastEventId = id
          },
          onRetry: (nextRetryMs) => {
            serverRetryMs = nextRetryMs
            retryMs = nextRetryMs
          },
        })
        for (;;) {
          const { done, value } = await reader.read()
          parser.push(decoder.decode(value ?? new Uint8Array(), { stream: !done }))
          if (done) {
            parser.finish()
            break
          }
        }
        if (!stopped && !controller.signal.aborted) {
          throw new Error('SSE transport stream closed')
        }
      } catch (err) {
        if (stopped || controller.signal.aborted || fetchController !== controller) return
        connected = false
        notify({ type: 'error', error: err instanceof Error ? err : new Error(String(err)) })
        scheduleReconnect()
      } finally {
        if (fetchReader === reader) fetchReader = null
        reader?.releaseLock()
        if (fetchController === controller) fetchController = null
      }
    })()
  }

  const connect = () => {
    if (source || fetchController) return
    stopped = false
    if (useAuthenticatedFetch) {
      connectWithFetch()
      return
    }
    try {
      source = new EventSource(url)
      source.onopen = () => {
        connected = true
        retryMs = serverRetryMs ?? opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
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
        if (stopped) return
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
    stopped = true
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
    connected = false
    retryMs = opts.retryBaseMs ?? TRANSPORT_RETRY_BASE_MS
    serverRetryMs = null
    reconnectAttempts = 0
    closeNotified = false
    source?.close()
    source = null
    const controller = fetchController
    fetchController = null
    controller?.abort()
    const reader = fetchReader
    fetchReader = null
    if (reader !== null) {
      void reader.cancel().catch((err: unknown) => {
        console.warn('[SSE transport] reader cancellation failed', err)
      })
    }
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
