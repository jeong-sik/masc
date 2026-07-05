import { afterEach, describe, expect, it, vi } from 'vitest'

const sseStoreMocks = vi.hoisted(() => ({
  hydrateDashboardSlice: vi.fn(),
  routeServerPushEvent: vi.fn(),
}))

vi.mock('./sse-store', () => sseStoreMocks)

import {
  clearDashboardWsDiscoveryCacheForTests,
  connectDashboardWS,
  dashboardSlicesForRoute,
  disconnectDashboardWS,
  flushPendingInbound,
  subscribeDashboardRoute,
} from './dashboard-ws'
import { parseWebSocketSseFrames } from './dashboard-ws-parse'
import { clearStoredToken, setStoredToken } from './api/core'
import {
  DASHBOARD_WS_HEARTBEAT_INTERVAL_MS,
  DASHBOARD_WS_HEARTBEAT_RPC_TIMEOUT_MS,
  DASHBOARD_WS_RPC_TIMEOUT_MS,
} from './config/constants'
import { DASHBOARD_PUSH_SLICES } from './dashboard-slices'
import {
  _resetDashboardWsCounterForTests,
  dashboardWsConnected,
  dashboardWsEventCount60s,
  dashboardWsLastError,
  dashboardWsLastPingAt,
  dashboardWsLastPongAt,
  dashboardWsLastPongLatencyMs,
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

  close(event: Partial<Pick<CloseEvent, 'code' | 'reason' | 'wasClean'>> = {}): void {
    this.readyState = MockWebSocket.CLOSED
    this.onclose?.({
      code: event.code ?? 1000,
      reason: event.reason ?? '',
      wasClean: event.wasClean ?? true,
    } as CloseEvent)
  }

  open(): void {
    this.readyState = MockWebSocket.OPEN
    this.onopen?.(new Event('open'))
  }

  receive(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) } as MessageEvent)
    flushPendingInbound()
  }
}

class MockParseWorker {
  static holdResponses = false
  static instances: MockParseWorker[] = []

  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: ErrorEvent) => void) | null = null
  onmessageerror: ((event: MessageEvent) => void) | null = null
  terminated = false
  heldMessages: Array<{ id: number; data: string }> = []

  constructor(readonly url: URL) {
    MockParseWorker.instances.push(this)
  }

  postMessage(message: { id: number; data: string }): void {
    if (MockParseWorker.holdResponses) {
      this.heldMessages.push(message)
      return
    }
    this.onmessage?.({
      data: {
        id: message.id,
        payloads: [JSON.parse(message.data) as unknown],
      },
    } as MessageEvent)
  }

  releaseHeldResponses(): void {
    const messages = this.heldMessages.splice(0)
    for (const message of messages) {
      this.onmessage?.({
        data: {
          id: message.id,
          payloads: [JSON.parse(message.data) as unknown],
        },
      } as MessageEvent)
    }
  }

  terminate(): void {
    this.terminated = true
  }

  static reset(): void {
    MockParseWorker.holdResponses = false
    MockParseWorker.instances = []
  }
}

function installWebSocketMocks(): void {
  mockSockets.length = 0
  vi.stubGlobal('WebSocket', MockWebSocket)
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
    enabled: true,
    listening: true,
    ws_url: 'ws://localhost:3000/ws',
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

function wsDiscoveryResponse(
  wsUrl: string | null = 'ws://localhost:3000/ws',
  overrides: Record<string, unknown> = {},
): Response {
  return new Response(JSON.stringify({
    enabled: true,
    listening: true,
    ws_url: wsUrl,
    ...overrides,
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

async function connectReadyDashboard(): Promise<MockWebSocket> {
  await connectDashboardWS({ tab: 'overview', params: {} })
  const socket = mockSockets[0]!
  socket.open()
  const hello = parseRpc(socket, 0)
  socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
  await flushPromises()

  const subscribe = parseRpc(socket, 1)
  socket.receive({
    jsonrpc: '2.0',
    id: subscribe.id,
    result: { snapshot: { seq: 1, slices: {} } },
  })
  await flushPromises()
  return socket
}

beforeEach(() => {
  // Make requestAnimationFrame synchronous so the rAF accumulator
  // flushes immediately inside the same task.  Tests remain
  // unchanged and do not need to await microtasks.
  vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
    cb(0)
    return 0
  })
  vi.stubGlobal('cancelAnimationFrame', vi.fn())
  // Deterministic reconnect-jitter so timer-advance assertions are stable.
  vi.spyOn(Math, 'random').mockReturnValue(0)
})

afterEach(() => {
  disconnectDashboardWS()
  MockParseWorker.reset()
  clearDashboardWsDiscoveryCacheForTests()
  dashboardWsConnected.value = false
  dashboardWsLastError.value = null
  dashboardWsLastPingAt.value = 0
  dashboardWsLastPongAt.value = 0
  dashboardWsLastPongLatencyMs.value = null
  dashboardWsLastSeq.value = 0
  dashboardWsReady.value = false
  _resetDashboardWsCounterForTests()
  clearStoredToken()
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  sseStoreMocks.hydrateDashboardSlice.mockClear()
  sseStoreMocks.routeServerPushEvent.mockClear()
})

describe('dashboardSlicesForRoute', () => {
  it('only subscribes slices from the shared push vocabulary', () => {
    const routes = [
      { tab: 'overview', params: {} },
      { tab: 'board', params: {} },
      { tab: 'workspace', params: { section: 'planning' } },
      { tab: 'workspace', params: { section: 'board' } },
      { tab: 'monitoring', params: { section: 'agents' } },
      { tab: 'keepers', params: { keeper: 'sangsu' } },
      { tab: 'monitoring', params: { section: 'cognition' } },
      { tab: 'monitoring', params: { section: 'fleet-health', view: 'comparison' } },
      { tab: 'command', params: {} },
    ] as const

    for (const route of routes) {
      for (const slice of dashboardSlicesForRoute(route)) {
        expect(DASHBOARD_PUSH_SLICES).toContain(slice)
      }
    }
  })

  it('keeps global shell namespace and transport slices on every route', () => {
    expect(dashboardSlicesForRoute({ tab: 'overview', params: {} })).toEqual([
      'execution',
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
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'cognition' } }))
      .toContain('execution')
    expect(dashboardSlicesForRoute({
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'comparison' },
    })).toContain('execution')
  })

  it('keeps board route snapshots HTTP-owned while subscribing goals and fleet FSM slices', () => {
    expect(dashboardSlicesForRoute({ tab: 'board', params: {} }))
      .toEqual([
        'namespace',
        'shell',
        'transport',
      ])
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'board' } }))
      .toEqual([
        'namespace',
        'shell',
        'transport',
      ])
    expect(dashboardSlicesForRoute({ tab: 'workspace', params: { section: 'planning' } }))
      .toContain('goals')
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'agents' } }))
      .toContain('composite')
    expect(dashboardSlicesForRoute({ tab: 'keepers', params: { keeper: 'sangsu' } }))
      .toEqual([
        'composite',
        'execution',
        'namespace',
        'shell',
        'transport',
      ])
    expect(dashboardSlicesForRoute({ tab: 'monitoring', params: { section: 'cognition' } }))
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
  it('sends hello token from the shared dashboard auth reader', async () => {
    installWebSocketMocks()
    setStoredToken('  ws-token  ')

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()

    const hello = parseRpc(socket, 0)
    expect(hello.method).toBe('dashboard/hello')
    expect(hello.params.token).toBe('ws-token')
  })

  it('omits blank raw stored tokens from websocket hello', async () => {
    installWebSocketMocks()
    sessionStorage.setItem('masc_bearer_token', '   ')

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()

    const hello = parseRpc(socket, 0)
    expect(hello.method).toBe('dashboard/hello')
    expect(hello.params).not.toHaveProperty('token')
  })

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

    discoveries[1]!(wsDiscoveryResponse('ws://localhost:3000/ws?latest'))
    await latestConnect
    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.url).toBe('ws://localhost:3000/ws?latest')

    discoveries[0]!(wsDiscoveryResponse('ws://localhost:3000/ws?stale'))
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
    expect(dashboardWsLastError.value).toBe('dashboard websocket unavailable: not listening')

    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(mockSockets).toHaveLength(1)
  })

  it('surfaces disabled discovery reasons without scheduling reconnect', async () => {
    vi.useFakeTimers()
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        enabled: false,
        listening: false,
        unavailable_reason: 'disabled_by_config',
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
    vi.stubGlobal('fetch', fetchMock)

    await connectDashboardWS({ tab: 'overview', params: {} })
    expect(mockSockets).toHaveLength(0)
    expect(dashboardWsLastError.value).toBe(
      'dashboard websocket unavailable: disabled_by_config',
    )

    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(mockSockets).toHaveLength(0)
  })

  it('treats blank websocket discovery URLs as unavailable', async () => {
    vi.useFakeTimers()
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        enabled: true,
        listening: true,
        ws_url: '   ',
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(wsDiscoveryResponse())
    vi.stubGlobal('fetch', fetchMock)

    await connectDashboardWS({ tab: 'overview', params: {} })
    expect(mockSockets).toHaveLength(0)
    expect(dashboardWsLastError.value).toBe(
      'dashboard websocket unavailable: websocket URL unavailable',
    )

    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(mockSockets).toHaveLength(1)
  })

  it('prefers the current page origin when same-origin upgrade is advertised', async () => {
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    vi.stubGlobal('fetch', vi.fn(async () => wsDiscoveryResponse('ws://127.0.0.1:5173/ws', {
      same_origin_upgrade_enabled: true,
      same_origin_upgrade_path: '/ws',
      same_origin_ws_url: 'ws://127.0.0.1:5173/ws',
    })))

    await connectDashboardWS({ tab: 'overview', params: {} })

    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.url).toBe('ws://localhost:3000/ws')
  })

  it('derives the current-origin upgrade URL from same_origin_ws_url when the path is omitted', async () => {
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    vi.stubGlobal('fetch', vi.fn(async () => wsDiscoveryResponse('ws://127.0.0.1:5173/ws', {
      same_origin_upgrade_enabled: true,
      same_origin_ws_url: 'ws://127.0.0.1:5173/ws?transport=dashboard',
    })))

    await connectDashboardWS({ tab: 'overview', params: {} })

    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.url).toBe('ws://localhost:3000/ws?transport=dashboard')
  })

  it('falls back to the advertised websocket URL when same-origin upgrade is disabled', async () => {
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    vi.stubGlobal('fetch', vi.fn(async () => wsDiscoveryResponse('ws://127.0.0.1:8937/', {
      same_origin_upgrade_enabled: false,
      same_origin_ws_url: 'ws://localhost:3000/ws',
    })))

    await connectDashboardWS({ tab: 'overview', params: {} })

    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.url).toBe('ws://127.0.0.1:8937/')
  })

  it('retries discovery when the server withholds ws_url for this host', async () => {
    vi.useFakeTimers()
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({
        enabled: true,
        listening: true,
        ws_url: null,
        unavailable_reason: 'standalone_ws_loopback_only',
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(wsDiscoveryResponse())
    vi.stubGlobal('fetch', fetchMock)

    await connectDashboardWS({ tab: 'overview', params: {} })
    expect(mockSockets).toHaveLength(0)
    expect(dashboardWsLastError.value).toBe(
      'dashboard websocket unavailable: standalone_ws_loopback_only',
    )

    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(mockSockets).toHaveLength(1)
  })

  it('reuses cached websocket discovery across reconnects after a ready socket closes', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    const fetchMock = fetch as unknown as ReturnType<typeof vi.fn>

    await connectDashboardWS({ tab: 'overview', params: {} })
    const firstSocket = mockSockets[0]!
    firstSocket.open()
    const hello = parseRpc(firstSocket, 0)
    firstSocket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(firstSocket, 1)
    firstSocket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)

    firstSocket.close({ code: 1001, reason: 'server restart', wasClean: true })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.url).toBe('ws://localhost:3000/ws')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('clears lastError on a clean close so the SSE fallback does not engage', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    const subscribe = parseRpc(socket, 1)
    socket.receive({ jsonrpc: '2.0', id: subscribe.id, result: { snapshot: { seq: 1, slices: {} } } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    // Server-initiated clean close (wasClean=true) is not a degraded-WS error:
    // lastError stays null so the SSE fallback (dashboard-transport-fallback.ts)
    // does not fire. reconnect still runs.
    socket.close({ code: 1001, reason: 'server restart', wasClean: true })
    expect(dashboardWsLastError.value).toBe(null)
    expect(dashboardWsReady.value).toBe(false)
  })

  it('sets lastError on an abnormal close so the SSE fallback can engage', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    const subscribe = parseRpc(socket, 1)
    socket.receive({ jsonrpc: '2.0', id: subscribe.id, result: { snapshot: { seq: 1, slices: {} } } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    socket.close({ code: 1006, reason: 'connect failed', wasClean: false })
    expect(dashboardWsLastError.value).not.toBe(null)
    expect(dashboardWsLastError.value).toContain('code=1006')
  })

  it('drops cached websocket discovery from a different origin', async () => {
    installWebSocketMocks()
    const fetchMock = fetch as unknown as ReturnType<typeof vi.fn>
    sessionStorage.setItem('masc.dashboard.ws.discovery.v1', JSON.stringify({
      ws_url: 'ws://127.0.0.1:8937/',
    }))

    await connectDashboardWS({ tab: 'overview', params: {} })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(mockSockets).toHaveLength(1)
    expect(mockSockets[0]!.url).toBe('ws://localhost:3000/ws')
  })

  it('does not cache websocket discovery before hello succeeds', async () => {
    vi.useFakeTimers()
    mockSockets.length = 0
    vi.stubGlobal('WebSocket', MockWebSocket)
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(wsDiscoveryResponse('ws://localhost:3000/ws?stale'))
      .mockResolvedValueOnce(wsDiscoveryResponse('ws://localhost:3000/ws?fresh'))
    vi.stubGlobal('fetch', fetchMock)

    await connectDashboardWS({ tab: 'overview', params: {} })
    const staleSocket = mockSockets[0]!
    expect(staleSocket.url).toBe('ws://localhost:3000/ws?stale')
    expect(fetchMock).toHaveBeenCalledTimes(1)

    staleSocket.close({ code: 1006, reason: 'connect failed', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.url).toBe('ws://localhost:3000/ws?fresh')
  })

  it('stops reconnecting after a fatal policy violation close', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    const subscribe = parseRpc(socket, 1)
    socket.receive({ jsonrpc: '2.0', id: subscribe.id, result: { snapshot: { seq: 1, slices: {} } } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    socket.close({ code: 1008, reason: 'policy violation', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(mockSockets).toHaveLength(1)
  })

  it('reconnects after a transient 1011 server error close', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    const subscribe = parseRpc(socket, 1)
    socket.receive({ jsonrpc: '2.0', id: subscribe.id, result: { snapshot: { seq: 1, slices: {} } } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    socket.close({ code: 1011, reason: 'server error', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.url).toBe('ws://localhost:3000/ws')
  })

  it('stops reconnecting after a fatal 1002 protocol error close', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    const subscribe = parseRpc(socket, 1)
    socket.receive({ jsonrpc: '2.0', id: subscribe.id, result: { snapshot: { seq: 1, slices: {} } } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    socket.close({ code: 1002, reason: 'protocol error', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(mockSockets).toHaveLength(1)
  })

  it('stops reconnecting after a fatal 1003 unsupported data close', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    const subscribe = parseRpc(socket, 1)
    socket.receive({ jsonrpc: '2.0', id: subscribe.id, result: { snapshot: { seq: 1, slices: {} } } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    socket.close({ code: 1003, reason: 'unsupported data', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(mockSockets).toHaveLength(1)
  })

  it('stops reconnecting after an abnormal close after hello is rejected', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, error: { message: 'auth rejected' } })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(false)

    socket.close({ code: 1006, reason: 'abnormal', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(mockSockets).toHaveLength(1)
  })

  it('reconnects with a fresh token after hello auth rejection', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    setStoredToken('stale-token', { source: 'dev', actor: 'dashboard' })

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    expect(hello.params.token).toBe('stale-token')

    socket.receive({ jsonrpc: '2.0', id: hello.id, error: { message: 'auth rejected' } })
    await flushPromises()
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)

    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()
    expect(mockSockets).toHaveLength(1)

    setStoredToken('fresh-token', { source: 'dev', actor: 'dashboard' })
    await flushPromises()
    await flushPromises()

    expect(mockSockets).toHaveLength(2)
    const retry = mockSockets[1]!
    retry.open()
    const retryHello = parseRpc(retry, 0)
    expect(retryHello.method).toBe('dashboard/hello')
    expect(retryHello.params.token).toBe('fresh-token')
  })

  it('keeps reconnecting after a token change cancels an in-flight hello', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    setStoredToken('stale-token', { source: 'manual' })

    await connectDashboardWS({ tab: 'overview', params: {} })
    const staleSocket = mockSockets[0]!
    staleSocket.open()
    const staleHello = parseRpc(staleSocket, 0)
    expect(staleHello.params.token).toBe('stale-token')

    setStoredToken('fresh-token', { source: 'manual' })
    await flushPromises()
    await flushPromises()

    expect(staleSocket.readyState).toBe(MockWebSocket.CLOSED)
    expect(mockSockets).toHaveLength(2)

    const freshSocket = mockSockets[1]!
    freshSocket.open()
    const freshHello = parseRpc(freshSocket, 0)
    expect(freshHello.method).toBe('dashboard/hello')
    expect(freshHello.params.token).toBe('fresh-token')
    freshSocket.receive({ jsonrpc: '2.0', id: freshHello.id, result: {} })
    await flushPromises()
    const subscribe = parseRpc(freshSocket, 1)
    freshSocket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    expect(dashboardWsReady.value).toBe(true)

    freshSocket.close({ code: 1006, reason: 'abnormal', wasClean: false })
    await vi.advanceTimersByTimeAsync(60_000)
    await flushPromises()

    expect(mockSockets).toHaveLength(3)
    expect(mockSockets[2]!.readyState).toBe(MockWebSocket.CONNECTING)
  })

  it('closes an authenticated socket when the stored token is cleared', async () => {
    installWebSocketMocks()
    setStoredToken('active-token', { source: 'manual' })

    const socket = await connectReadyDashboard()
    expect(dashboardWsReady.value).toBe(true)

    clearStoredToken()
    await flushPromises()

    expect(socket.readyState).toBe(MockWebSocket.CLOSED)
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(mockSockets).toHaveLength(2)

    const retry = mockSockets[1]!
    retry.open()
    const retryHello = parseRpc(retry, 0)
    expect(retryHello.method).toBe('dashboard/hello')
    expect(retryHello.params).not.toHaveProperty('token')
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
    expect(subscribe.params.slices).toEqual([
      'namespace',
      'shell',
      'transport',
    ])

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

    await vi.advanceTimersByTimeAsync(DASHBOARD_WS_RPC_TIMEOUT_MS)
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

  it('reconnects when the initial route subscription never responds', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'workspace', params: { section: 'board' } })
    const firstSocket = mockSockets[0]!
    firstSocket.open()
    const hello = parseRpc(firstSocket, 0)
    firstSocket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(firstSocket, 1)
    expect(subscribe.method).toBe('dashboard/subscribe')
    expect(dashboardWsReady.value).toBe(true)

    await vi.advanceTimersByTimeAsync(DASHBOARD_WS_RPC_TIMEOUT_MS)
    await flushPromises()

    expect(firstSocket.readyState).toBe(MockWebSocket.CLOSED)
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(dashboardWsLastError.value).toBe(
      'dashboard websocket rpc timed out: dashboard/subscribe',
    )

    await vi.advanceTimersByTimeAsync(1_000)
    await flushPromises()

    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.readyState).toBe(MockWebSocket.CONNECTING)
  })

  it('sends dashboard heartbeat pings after a route subscription is ready', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    const socket = await connectReadyDashboard()
    expect(dashboardWsReady.value).toBe(true)
    expect(socket.sent).toHaveLength(2)

    await vi.advanceTimersByTimeAsync(DASHBOARD_WS_HEARTBEAT_INTERVAL_MS)
    await flushPromises()

    const ping = parseRpc(socket, 2)
    expect(ping.method).toBe('dashboard/ping')
    expect(ping.params).toEqual({})

    socket.receive({ jsonrpc: '2.0', id: ping.id, result: { ok: true } })
    await flushPromises()

    expect(dashboardWsConnected.value).toBe(true)
    expect(dashboardWsReady.value).toBe(true)
    expect(dashboardWsLastError.value).toBe(null)
    expect(dashboardWsLastPingAt.value).toBeGreaterThan(0)
    expect(dashboardWsLastPongAt.value).toBeGreaterThanOrEqual(dashboardWsLastPingAt.value)
    expect(dashboardWsLastPongLatencyMs.value).not.toBeNull()
  })

  it('reconnects when a dashboard heartbeat ping never responds', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    const socket = await connectReadyDashboard()
    expect(dashboardWsReady.value).toBe(true)

    await vi.advanceTimersByTimeAsync(DASHBOARD_WS_HEARTBEAT_INTERVAL_MS)
    await flushPromises()

    const ping = parseRpc(socket, 2)
    expect(ping.method).toBe('dashboard/ping')

    await vi.advanceTimersByTimeAsync(DASHBOARD_WS_HEARTBEAT_RPC_TIMEOUT_MS)
    await flushPromises()

    expect(socket.readyState).toBe(MockWebSocket.CLOSED)
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(dashboardWsLastError.value).toBe('dashboard websocket rpc timed out: dashboard/ping')

    await vi.advanceTimersByTimeAsync(1_000)
    await flushPromises()

    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.readyState).toBe(MockWebSocket.CONNECTING)
  })

  it('acknowledges dashboard deltas as notifications without response tracking', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 42 },
    })

    const ack = JSON.parse(socket.sent[2] ?? '{}') as Record<string, unknown>
    expect(ack).toMatchObject({
      jsonrpc: '2.0',
      method: 'dashboard/ack',
      params: { seq: 42, bufferedAmount: 0 },
    })
    expect(ack).not.toHaveProperty('id')
    expect(dashboardWsLastSeq.value).toBe(42)
    expect(dashboardWsEventCount60s.value).toBe(0)
  })

  it('hydrates payload-only dashboard deltas without acking', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    sseStoreMocks.hydrateDashboardSlice.mockClear()
    const sentBeforeDelta = socket.sent.length

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: {
        slice: 'execution',
        event_type: 'execution_snapshot',
        payload: { agents: [] },
      },
    })

    expect(dashboardWsLastSeq.value).toBe(1)
    expect(dashboardWsEventCount60s.value).toBe(1)
    expect(socket.sent).toHaveLength(sentBeforeDelta)
    expect(sseStoreMocks.hydrateDashboardSlice).toHaveBeenCalledWith(
      'execution',
      { agents: [] },
      'execution_snapshot',
    )
  })

  it('parses inbound deltas inline on the main thread', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 43, slice: 'execution', payload: { agents: [] } },
    })

    expect(dashboardWsLastSeq.value).toBe(43)
    expect(sseStoreMocks.hydrateDashboardSlice).toHaveBeenCalledWith(
      'execution',
      { agents: [] },
      undefined,
    )
  })

  it('offloads inbound frame parsing to a Web Worker when available', async () => {
    installWebSocketMocks()
    vi.stubGlobal('Worker', MockParseWorker)

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 43, slice: 'execution', payload: { agents: [] } },
    })

    expect(dashboardWsLastSeq.value).toBe(43)
    expect(sseStoreMocks.hydrateDashboardSlice).toHaveBeenCalledWith(
      'execution',
      { agents: [] },
      undefined,
    )
  })

  it('falls back to main-thread parsing when the parse worker stops responding', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    vi.stubGlobal('Worker', MockParseWorker)

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    MockParseWorker.holdResponses = true
    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 43, slice: 'execution', payload: { agents: [] } },
    })
    expect(sseStoreMocks.hydrateDashboardSlice).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(5_000)
    flushPendingInbound()

    expect(dashboardWsLastSeq.value).toBe(43)
    expect(sseStoreMocks.hydrateDashboardSlice).toHaveBeenCalledWith(
      'execution',
      { agents: [] },
      undefined,
    )
  })

  it('drops held parse worker replies after socket teardown', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()
    vi.stubGlobal('Worker', MockParseWorker)

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()
    dashboardWsLastSeq.value = 0
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    MockParseWorker.holdResponses = true
    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 43, slice: 'execution', payload: { agents: [] } },
    })
    expect(sseStoreMocks.hydrateDashboardSlice).not.toHaveBeenCalled()
    const sentBeforeTeardown = socket.sent.length
    const worker = MockParseWorker.instances[0]!

    disconnectDashboardWS()
    worker.releaseHeldResponses()
    await vi.advanceTimersByTimeAsync(5_000)
    flushPendingInbound()

    expect(worker.terminated).toBe(true)
    expect(dashboardWsLastSeq.value).toBe(0)
    expect(sseStoreMocks.hydrateDashboardSlice).not.toHaveBeenCalled()
    expect(socket.sent).toHaveLength(sentBeforeTeardown)
  })

  it('reconnects when sending a delta ack notification throws', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'overview', params: {} })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const subscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 1, slices: {} } },
    })
    await flushPromises()

    socket.send = () => {
      throw new Error('send exploded')
    }

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 44, slice: 'execution', payload: { agents: [] } },
    })

    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(dashboardWsLastError.value).toContain('send exploded')

    await vi.advanceTimersByTimeAsync(1_000)
    await flushPromises()

    expect(mockSockets).toHaveLength(2)
    expect(mockSockets[1]!.readyState).toBe(MockWebSocket.CONNECTING)
  })

  it('reconnects when a delta ack notification sees a non-open socket', async () => {
    vi.useFakeTimers()
    installWebSocketMocks()

    const socket = await connectReadyDashboard()
    expect(dashboardWsReady.value).toBe(true)
    const sentBeforeDelta = socket.sent.length
    socket.readyState = MockWebSocket.CLOSING

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 45, slice: 'execution', payload: { agents: [] } },
    })

    expect(socket.sent).toHaveLength(sentBeforeDelta)
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(dashboardWsLastError.value).toContain('state=CLOSING')

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

  it('surfaces close code and reason when the socket closes', async () => {
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
    expect(parseRpc(socket, 2).method).toBe('dashboard/subscribe')

    socket.close({ code: 4001, reason: 'auth rejected', wasClean: false })

    const closeMessage = 'dashboard websocket closed (code=4001, reason=auth rejected, wasClean=false)'
    expect(dashboardWsConnected.value).toBe(false)
    expect(dashboardWsReady.value).toBe(false)
    expect(dashboardWsLastError.value).toBe(closeMessage)
    await expect(subscribePromise).rejects.toThrow(closeMessage)
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
    await vi.advanceTimersByTimeAsync(DASHBOARD_WS_RPC_TIMEOUT_MS)
    await rejection

    socket.receive({
      jsonrpc: '2.0',
      id: subscribe.id,
      result: { snapshot: { seq: 99, slices: {} } },
    })
    await flushPromises()

    expect(dashboardWsLastSeq.value).toBe(1)
  })

  it('ignores board slice snapshots and deltas because the board list is HTTP-owned', async () => {
    installWebSocketMocks()

    await connectDashboardWS({ tab: 'workspace', params: { section: 'board' } })
    const socket = mockSockets[0]!
    socket.open()
    const hello = parseRpc(socket, 0)
    socket.receive({ jsonrpc: '2.0', id: hello.id, result: {} })
    await flushPromises()

    const initialSubscribe = parseRpc(socket, 1)
    socket.receive({
      jsonrpc: '2.0',
      id: initialSubscribe.id,
      result: { snapshot: { seq: 1, slices: { board: { posts: [] } } } },
    })
    await flushPromises()
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 2, slice: 'board', payload: { posts: [] } },
    })
    expect(sseStoreMocks.hydrateDashboardSlice).not.toHaveBeenCalled()
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    const switchPromise = subscribeDashboardRoute({
      tab: 'monitoring',
      params: { section: 'observatory' },
    })
    const routeSubscribe = parseRpc(socket, socket.sent.length - 1)
    socket.receive({
      jsonrpc: '2.0',
      id: routeSubscribe.id,
      result: { snapshot: { seq: 3, slices: { execution: { agents: [] } } } },
    })
    await switchPromise
    sseStoreMocks.hydrateDashboardSlice.mockClear()

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 4, slice: 'board', payload: { posts: [] } },
    })
    expect(sseStoreMocks.hydrateDashboardSlice).not.toHaveBeenCalled()

    socket.receive({
      jsonrpc: '2.0',
      method: 'dashboard/delta',
      params: { seq: 5, slice: 'execution', payload: { agents: [] } },
    })
    expect(sseStoreMocks.hydrateDashboardSlice).toHaveBeenCalledWith(
      'execution',
      { agents: [] },
      undefined,
    )
  })
})
