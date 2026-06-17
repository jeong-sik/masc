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

  it('stops reconnecting after retryMaxAttempts and emits close', () => {
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

    vi.advanceTimersByTime(1_000)
    expect(instances).toHaveLength(3)
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
