import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  connectDashboardWS,
  dashboardSlicesForRoute,
  disconnectDashboardWS,
  parseWebSocketSseFrames,
  subscribeDashboardRoute,
} from './dashboard-ws'
import {
  dashboardWsConnected,
  dashboardWsLastError,
  dashboardWsLastSeq,
  dashboardWsReady,
} from './dashboard-ws-state'

interface JsonRpcRequest {
  id: number
  method: string
  params: Record<string, unknown>
}

const mockSockets: MockWebSocket[] = []

class MockWebSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3

  readyState = MockWebSocket.CONNECTING
  bufferedAmount = 0
  sent: string[] = []
  onopen: ((event: Event) => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: Event) => void) | null = null
  onclose: ((event: CloseEvent) => void) | null = null

  constructor(readonly url: string) {
    mockSockets.push(this)
  }

  send(data: string): void {
    this.sent.push(data)
  }

  close(): void {
    this.readyState = MockWebSocket.CLOSED
    this.onclose?.(new CloseEvent('close'))
  }

  open(): void {
    this.readyState = MockWebSocket.OPEN
    this.onopen?.(new Event('open'))
  }

  receive(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) } as MessageEvent)
  }
}

function installWebSocketMocks(): void {
  mockSockets.length = 0
  vi.stubGlobal('WebSocket', MockWebSocket)
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
    enabled: true,
    listening: true,
    ws_url: 'ws://127.0.0.1:8937/',
  }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })))
}

function installControlledDiscovery(): Array<(response: Response) => void> {
  mockSockets.length = 0
  const resolvers: Array<(response: Response) => void> = []
  vi.stubGlobal('WebSocket', MockWebSocket)
  vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>((resolve) => {
    resolvers.push(resolve)
  })))
  return resolvers
}

function wsDiscoveryResponse(wsUrl = 'ws://127.0.0.1:8937/'): Response {
  return new Response(JSON.stringify({
    enabled: true,
    listening: true,
    ws_url: wsUrl,
  }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

function parseRpc(socket: MockWebSocket, index: number): JsonRpcRequest {
  return JSON.parse(socket.sent[index] ?? '{}') as JsonRpcRequest
}

async function flushPromises(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

afterEach(() => {
  disconnectDashboardWS()
  dashboardWsConnected.value = false
  dashboardWsLastError.value = null
  dashboardWsLastSeq.value = 0
  dashboardWsReady.value = false
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('dashboardSlicesForRoute', () => {
  it('keeps global shell namespace and transport slices on every route', () => {
    expect(dashboardSlicesForRoute({ tab: 'overview', params: {} })).toEqual([
      'namespace',
      'shell',
      'transport',
    ])
  })

  it('subscribes execution for execution-heavy monitoring and planning routes', () => {
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'planning' } }))
      .toContain('execution')
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'observatory' } }))
      .toContain('execution')
    expect(dashboardSlicesForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'comparison' },
    })).toContain('execution')
  })

  it('subscribes route-local dashboard slices for board, goals, and fleet FSM routes', () => {
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'board' } }))
      .toContain('board')
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'planning' } }))
      .toContain('goals')
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'agents' } }))
      .toContain('composite')
  })

  it('subscribes operator only for the active command surface', () => {
    expect(dashboardSlicesForRoute({ tab: 'command', params: {} })).toContain('operator')
    expect(dashboardSlicesForRoute({ tab: 'command', params: { view: 'inspector' } }))
      .not.toContain('operator')
  })
})

describe('parseWebSocketSseFrames', () => {
  it('extracts JSON payloads from raw SSE frames forwarded over websocket', () => {
    expect(parseWebSocketSseFrames([
      'id: 1',
      'data: {"type":"post_created","post_id":"p1"}',
      '',
      'id: 2',
      'event: message',
      'data: {"type":"keeper_composite_changed","name":"qa-king"}',
      '',
      '',
    ].join('\n'))).toEqual([
      { type: 'post_created', post_id: 'p1' },
      { type: 'keeper_composite_changed', name: 'qa-king' },
    ])
  })
})

describe('dashboard websocket route subscriptions', () => {
  it('does not open a socket when discovery resolves after disconnect', async () => {
    const discoveries = installControlledDiscovery()

    const connect = connectDashboardWS({ tab: 'overview', params: {} })
    expect(discoveries).toHaveLength(1)

    disconnectDashboardWS()
    discoveries[0]!(wsDiscoveryResponse())
    await connect
    await flushPromises()

    expect(mockSockets).toHaveLength(0)
  })

  it('ignores stale discovery responses after a newer connect starts', async () => {
    const discoveries = installControlledDiscovery()

    const staleConnect = connectDashboardWS({ tab: 'overview', params: {} })
    const latestConnect = connectDashboardWS({ tab: 'workspace', params: { section: 'board' } })
    expect(discoveries).toHaveLength(2)

    discoveries[1]!(wsDiscoveryResponse('ws://127.0.0.1:8937/latest'))
    await latestConnect
    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.url).toBe('ws://127.0.0.1:8937/latest')

    discoveries[0]!(wsDiscoveryResponse('ws://127.0.0.1:8937/stale'))
    await staleConnect
    await flushPromises()

    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.readyState).toBe(MockWebSocket.CONNECTING)
  })

  it('retries discovery when the websocket endpoint is enabled but not listening yet', async () => {
    vi.useFakeTimers()
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        enabled: true,
        listening: false,
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(wsDiscoveryResponse())
    vi.stubGlobal('fetch', fetchMock)

    await connectDashboardWS({ tab: 'overview', params: {} })
    expect(mockSockets).toHaveLength(0)

    await vi.advanceTimersByTimeAsync(1_000)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(mockSockets).toHaveLength(1)
  })

  it('subscribes the latest route captured while hello is still in flight', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    await subscribeDashboardRoute({ tab: 'workspace', params: { section: 'board' } })

    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    expect(hello.method).toBe('dashboard/hello')

    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    expect(subscribe.method).toBe('dashboard/subscribe')
    expect(subscribe.params.route).toBe('workspace:board::')
    expect(subscribe.params.slices).toEqual(expect.arrayContaining(['board']))

    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 7, slices: {} } },
    })
    await flushPromises()
  })

  it('reconnects when the hello handshake never responds', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'workspace', params: { section: 'board' } })
    const firstSocket = mockSockets[0]!
    firstSocket.open()
    const hello = parseRpc(firstSocket, 0)
    expect(hello.method).toBe('dashboard/hello')
    expect(dashboardWsConnected.value).toBe(true)

    await vi.advanceTimersByTimeAsync(15_000)
    await flushPromises()

    expect(firstSocket.readyState).toBe(MockWebSocket.CLOSED)
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(dashboardWsLastError.value).toBe('dashboard websocket rpc timed out: dashboard/hello')

    await vi.advanceTimersByTimeAsync(1_000)
    await flushPromises()

    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.readyState).toBe(MockWebSocket.CONNECTING)
  })

  it('ignores stale subscribe snapshots that arrive after a newer route subscription', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const initialSubscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: initialSubscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    dashboardWsLastSeq.value = 0

    const stalePromise = subscribeDashboardRoute({
      tab: 'workspace',
      params: { section: 'board' },
    })
    const staleSubscribe = parseRpc(socket, 2)

    const latestPromise = subscribeDashboardRoute({
      tab: 'workspace',
      params: { section: 'planning' },
    })
    const latestSubscribe = parseRpc(socket, 3)

    socket.receive({
      jsonrpc: '2.0',
      id: staleSubscribe.id,
      result: { snapshot: { seq: 11, slices: {} } },
    })
    await stalePromise
    expect(dashboardWsLastSeq.value).toBe(0)

    socket.receive({
      jsonrpc: '2.0',
      id: latestSubscribe.id,
      result: { snapshot: { seq: 22, slices: {} } },
    })
    await latestPromise
    expect(dashboardWsLastSeq.value).toBe(22)
  })

  it('rejects in-flight subscribe RPCs when the socket closes', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const initialSubscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: initialSubscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()

    const subscribePromise = subscribeDashboardRoute({
      tab: 'workspace',
      params: { section: 'planning' },
    })
    const subscribe = parseRpc(socket, 2)
    expect(subscribe.method).toBe('dashboard/subscribe')

    socket.close()

    await expect(subscribePromise).rejects.toThrow('dashboard websocket closed')
  })

  it('rejects in-flight subscribe RPCs when the server never responds', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const initialSubscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: initialSubscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()

    const subscribePromise = subscribeDashboardRoute({
      tab: 'workspace',
      params: { section: 'planning' },
    })
    const subscribe = parseRpc(socket, 2)
    expect(subscribe.method).toBe('dashboard/subscribe')

    const rejection = expect(subscribePromise).rejects.toThrow(
      'dashboard websocket rpc timed out: dashboard/subscribe',
    )
    await vi.advanceTimersByTimeAsync(15_000)
    await rejection

    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 99, slices: {} } },
    })
    await flushPromises()

    expect(dashboardWsLastSeq.value).toBe(1)
  })
})
