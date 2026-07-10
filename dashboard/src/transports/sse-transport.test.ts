import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { createSseTransport } from './sse-transport'

class MockEventSource {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSED = 2

  onopen: ((event: Event) => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: Event) => void) | null = null
  readyState = MockEventSource.CONNECTING
  readonly url: string
  close = vi.fn(() => {
    this.readyState = MockEventSource.CLOSED
  })

  constructor(url: string) {
    this.url = url
    instances.push(this)
  }

  simulateOpen(): void {
    this.readyState = MockEventSource.OPEN
    this.onopen?.(new Event('open'))
  }

  simulateError(): void {
    this.readyState = MockEventSource.CLOSED
    this.onerror?.(new Event('error'))
  }

  simulateMessage(data: string): void {
    this.onmessage?.(new MessageEvent('message', { data }))
  }
}

let instances: MockEventSource[] = []

function installMock(): void {
  instances = []
  vi.stubGlobal('EventSource', MockEventSource)
}

function controlledEventStream(): {
  readonly response: Response
  readonly controller: ReadableStreamDefaultController<Uint8Array>
} {
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined
  const stream = new ReadableStream<Uint8Array>({
    start(nextController) {
      controller = nextController
    },
  })
  if (controller === undefined) throw new Error('stream controller was not initialized')
  return {
    response: new Response(stream, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    }),
    controller,
  }
}

describe('createSseTransport', () => {
  beforeEach(() => {
    installMock()
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('opens and emits an open event', () => {
    const events: { type: string; data?: unknown; error?: Error }[] = []
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 100,
      retryJitterMs: 0,
    })
    transport.subscribe((event) => {
      events.push({
        type: event.type,
        ...(event.type === 'message' ? { data: event.data } : {}),
        ...(event.type === 'error' ? { error: event.error } : {}),
      })
    })
    transport.connect()
    expect(instances).toHaveLength(1)
    instances[0]!.simulateOpen()
    expect(events).toContainEqual({ type: 'open' })
    expect(transport.isConnected()).toBe(true)
  })

  it('parses JSON messages and falls back to raw strings', () => {
    const events: { type: string; data?: unknown }[] = []
    const transport = createSseTransport('/mcp', { retryJitterMs: 0 })
    transport.subscribe((event) => {
      if (event.type === 'message') events.push({ type: event.type, data: event.data })
    })
    transport.connect()
    instances[0]!.simulateOpen()
    instances[0]!.simulateMessage(JSON.stringify({ kind: 'ping' }))
    instances[0]!.simulateMessage('plain heartbeat')
    expect(events).toEqual([
      { type: 'message', data: { kind: 'ping' } },
      { type: 'message', data: 'plain heartbeat' },
    ])
  })

  it('uses an Authorization header and ReadableStream without a query bearer', async () => {
    vi.useRealTimers()
    const streamState: {
      controller?: ReadableStreamDefaultController<Uint8Array>
    } = {}
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        streamState.controller = controller
      },
    })
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(stream, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)
    const events: Array<{ type: string; data?: unknown }> = []
    const transport = createSseTransport('/mcp?session_id=dash_test', {
      headers: { Authorization: 'Bearer secret-token' },
      retryJitterMs: 0,
    })
    transport.subscribe((event) => {
      events.push({
        type: event.type,
        ...(event.type === 'message' ? { data: event.data } : {}),
      })
    })

    transport.connect()

    await vi.waitFor(() => expect(events).toContainEqual({ type: 'open' }))
    expect(fetchMock).toHaveBeenCalledWith(
      '/mcp?session_id=dash_test',
      expect.objectContaining({
        cache: 'no-store',
        headers: expect.objectContaining({
          Accept: 'text/event-stream',
          Authorization: 'Bearer secret-token',
        }),
      }),
    )
    expect(String(fetchMock.mock.calls[0]?.[0])).not.toContain('secret-token')

    const controller = streamState.controller
    if (controller === undefined) throw new Error('stream controller was not initialized')
    controller.enqueue(
      new TextEncoder().encode('id: evt-42\ndata: {"kind":"authenticated"}\n\n'),
    )
    await vi.waitFor(() => {
      expect(events).toContainEqual({
        type: 'message',
        data: { kind: 'authenticated' },
      })
    })

    transport.disconnect()
    expect(transport.isConnected()).toBe(false)
  })

  it('applies an id-only server prime and retry value to the next request', async () => {
    const first = controlledEventStream()
    const second = controlledEventStream()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(first.response)
      .mockResolvedValueOnce(second.response)
    vi.stubGlobal('fetch', fetchMock)
    const transport = createSseTransport('/mcp?session_id=dash_test', {
      headers: { Authorization: 'Bearer secret-token' },
      retryBaseMs: 100,
      retryJitterMs: 0,
    })

    transport.connect()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetchMock).toHaveBeenCalledTimes(1)

    first.controller.enqueue(
      new TextEncoder().encode(
        'retry: 3000\nid: evt-42\n\nretry: invalid\nid: bad\0id\n\n',
      ),
    )
    first.controller.close()
    await vi.advanceTimersByTimeAsync(0)

    await vi.advanceTimersByTimeAsync(2_999)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchMock.mock.calls[1]?.[1]).toEqual(
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: 'Bearer secret-token',
          'Last-Event-ID': 'evt-42',
        }),
      }),
    )

    transport.disconnect()
  })

  it('parses CRLF, lone CR, lone LF, and chunk-split multi-line data', async () => {
    vi.useRealTimers()
    const controlled = controlledEventStream()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(controlled.response))
    const messages: unknown[] = []
    const transport = createSseTransport('/mcp', {
      headers: { Authorization: 'Bearer secret-token' },
      retryJitterMs: 0,
    })
    transport.subscribe((event) => {
      if (event.type === 'message') messages.push(event.data)
    })

    transport.connect()
    controlled.controller.enqueue(new TextEncoder().encode('\uFEFF: comment\r\nid: evt-'))
    controlled.controller.enqueue(new TextEncoder().encode('7\r'))
    controlled.controller.enqueue(
      new TextEncoder().encode('\ndata:  leading\rdata: second\r\r'),
    )
    controlled.controller.enqueue(
      new TextEncoder().encode('data: {"answer":\ndata: 42}\n\n'),
    )

    await vi.waitFor(() => {
      expect(messages).toEqual([
        ' leading\nsecond',
        { answer: 42 },
      ])
    })
    transport.disconnect()
  })

  it('discards an unterminated event when the fetch stream reaches EOF', async () => {
    vi.useRealTimers()
    const controlled = controlledEventStream()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(controlled.response))
    const eventTypes: string[] = []
    const transport = createSseTransport('/mcp', {
      headers: { Authorization: 'Bearer secret-token' },
      retryBaseMs: 60_000,
      retryJitterMs: 0,
    })
    transport.subscribe((event) => eventTypes.push(event.type))

    transport.connect()
    controlled.controller.enqueue(new TextEncoder().encode('data: incomplete'))
    controlled.controller.close()

    await vi.waitFor(() => expect(eventTypes).toContain('error'))
    expect(eventTypes).not.toContain('message')
    transport.disconnect()
  })

  it('reconnects with exponential backoff capped by retryMaxMs', () => {
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 100,
      retryMaxMs: 400,
      retryJitterMs: 0,
      retryMaxAttempts: 10,
    })
    transport.connect()
    instances[0]!.simulateOpen()

    instances[0]!.simulateError()
    vi.advanceTimersByTime(100)
    expect(instances).toHaveLength(2)

    instances[1]!.simulateError()
    vi.advanceTimersByTime(200)
    expect(instances).toHaveLength(3)

    instances[2]!.simulateError()
    vi.advanceTimersByTime(400)
    expect(instances).toHaveLength(4)

    instances[3]!.simulateError()
    vi.advanceTimersByTime(400)
    expect(instances).toHaveLength(5)
  })

  it('adds random jitter up to retryJitterMs', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5)
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 100,
      retryJitterMs: 40,
      retryMaxAttempts: 10,
    })
    transport.connect()
    instances[0]!.simulateOpen()
    instances[0]!.simulateError()

    vi.advanceTimersByTime(119)
    expect(instances).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(instances).toHaveLength(2)
  })

  it('coalesces duplicate error events into one pending reconnect', () => {
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 100,
      retryJitterMs: 0,
      retryMaxAttempts: 10,
    })
    transport.connect()
    instances[0]!.simulateOpen()

    instances[0]!.simulateError()
    instances[0]!.simulateError()
    vi.advanceTimersByTime(100)

    expect(instances).toHaveLength(2)
  })

  it('keeps reconnecting after retryMaxAttempts and emits close once', () => {
    const events: { type: string }[] = []
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 10,
      retryMaxMs: 10,
      retryJitterMs: 0,
      retryMaxAttempts: 2,
    })
    transport.subscribe((event) => events.push({ type: event.type }))
    transport.connect()

    instances[0]!.simulateError()
    vi.advanceTimersByTime(10)
    expect(instances).toHaveLength(2)

    instances[1]!.simulateError()
    vi.advanceTimersByTime(10)
    expect(instances).toHaveLength(3)

    instances[2]!.simulateError()
    expect(transport.isConnected()).toBe(false)
    expect(events.filter((e) => e.type === 'close')).toHaveLength(1)

    vi.advanceTimersByTime(10)
    expect(instances).toHaveLength(4)
  })

  it('resets backoff after a successful reconnect', () => {
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 100,
      retryMaxMs: 400,
      retryJitterMs: 0,
      retryMaxAttempts: 10,
    })
    transport.connect()
    instances[0]!.simulateOpen()
    instances[0]!.simulateError()
    vi.advanceTimersByTime(100)
    instances[1]!.simulateOpen()
    instances[1]!.simulateError()
    vi.advanceTimersByTime(100)
    expect(instances).toHaveLength(3)
  })

  it('disconnect clears timers and emits close', () => {
    const events: { type: string }[] = []
    const transport = createSseTransport('/mcp', {
      retryBaseMs: 100,
      retryJitterMs: 0,
      retryMaxAttempts: 10,
    })
    transport.subscribe((event) => events.push({ type: event.type }))
    transport.connect()
    instances[0]!.simulateOpen()
    instances[0]!.simulateError()
    transport.disconnect()
    vi.advanceTimersByTime(1_000)
    expect(instances).toHaveLength(1)
    expect(instances[0]!.close).toHaveBeenCalled()
    expect(events.filter((e) => e.type === 'close')).toHaveLength(1)
    expect(transport.isConnected()).toBe(false)
  })
})
