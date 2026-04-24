import type { RouteState, SSEEvent } from './types'
import { parseSSEMessage } from './schemas/sse'
import { hydrateDashboardSlice, routeServerPushEvent } from './sse-store'
import {
  dashboardWsConnected,
  dashboardWsLastError,
  dashboardWsLastSeq,
  dashboardWsReady,
} from './dashboard-ws-state'

type JsonObject = Record<string, unknown>
type PendingRpc = {
  resolve: (value: unknown) => void
  reject: (err: Error) => void
}
type DashboardRouteState = Pick<RouteState, 'tab' | 'params'>

interface DashboardWsDiscovery {
  enabled?: boolean
  listening?: boolean
  ws_url?: string
}

let socket: WebSocket | null = null
let rpcId = 0
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let reconnectAttempts = 0
let lastSubscribeKey = ''
let desiredRouteState: DashboardRouteState | null = null
let shouldReconnect = true
let connectGeneration = 0
const pending = new Map<number, PendingRpc>()

function rememberRouteState(routeState: DashboardRouteState): DashboardRouteState {
  desiredRouteState = {
    tab: routeState.tab,
    params: { ...routeState.params },
  }
  return desiredRouteState
}

function routeKey(routeState: DashboardRouteState): string {
  const params = routeState.params
  return [
    routeState.tab,
    params.section ?? '',
    params.view ?? '',
    params.q ?? '',
  ].join(':')
}

export function dashboardSlicesForRoute(routeState: DashboardRouteState): string[] {
  const slices = new Set(['shell', 'namespace', 'transport'])

  if (routeState.tab === 'workspace' && routeState.params.section === 'planning') {
    slices.add('execution')
    slices.add('goals')
  }
  if (routeState.tab === 'workspace' && routeState.params.section === 'board') {
    slices.add('board')
  }
  if (routeState.tab === 'monitoring') {
    const section = routeState.params.section
    if (section === 'observatory' || section === 'journey' || section === 'agents') {
      slices.add('execution')
    }
    if (section === 'agents') {
      slices.add('composite')
    }
    if (section === 'fleet-health' && routeState.params.view === 'comparison') {
      slices.add('execution')
      slices.add('transport')
    }
  }
  if (routeState.tab === 'command' && routeState.params.view !== 'inspector') {
    slices.add('operator')
  }

  return Array.from(slices).sort()
}

function clearReconnectTimer(): void {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
}

function scheduleReconnect(): void {
  if (!shouldReconnect) return
  if (reconnectTimer) return
  reconnectAttempts += 1
  const delay = Math.min(15_000, 500 * Math.pow(2, Math.min(reconnectAttempts, 5)))
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    void connectDashboardWS()
  }, delay)
}

function closeSocket(): void {
  if (socket) {
    socket.onopen = null
    socket.onclose = null
    socket.onerror = null
    socket.onmessage = null
    socket.close()
    socket = null
  }
  for (const { reject } of pending.values()) {
    reject(new Error('dashboard websocket closed'))
  }
  pending.clear()
}

async function discoverWsUrl(): Promise<string | null> {
  const response = await fetch('/ws', { credentials: 'same-origin' })
  if (!response.ok) return null
  const data = await response.json() as DashboardWsDiscovery
  if (data.enabled !== true || data.listening !== true || typeof data.ws_url !== 'string') {
    return null
  }
  return data.ws_url
}

function sendRpc(method: string, params: JsonObject): Promise<unknown> {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return Promise.reject(new Error('dashboard websocket is not open'))
  }
  const currentSocket = socket
  const id = ++rpcId
  const payload = { jsonrpc: '2.0', id, method, params }
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject })
    try {
      currentSocket.send(JSON.stringify(payload))
    } catch (err) {
      pending.delete(id)
      reject(err instanceof Error ? err : new Error(String(err)))
    }
  })
}

function handleRpcResponse(raw: JsonObject): boolean {
  if (typeof raw.id !== 'number') return false
  const pendingRpc = pending.get(raw.id)
  if (!pendingRpc) return true
  pending.delete(raw.id)
  const error = raw.error as { message?: unknown } | undefined
  if (error) {
    pendingRpc.reject(new Error(typeof error.message === 'string' ? error.message : 'dashboard websocket rpc failed'))
  } else {
    pendingRpc.resolve(raw.result)
  }
  return true
}

function applySnapshot(raw: unknown): void {
  const snapshot = raw as { slices?: unknown; seq?: unknown }
  if (typeof snapshot.seq === 'number') {
    dashboardWsLastSeq.value = snapshot.seq
  }
  const slices = snapshot.slices as Record<string, unknown> | undefined
  if (!slices || typeof slices !== 'object') return
  for (const [slice, payload] of Object.entries(slices)) {
    hydrateDashboardSlice(slice, payload)
  }
}

function applySubscribeResult(raw: unknown): void {
  const result = raw as { snapshot?: unknown }
  if (result.snapshot) applySnapshot(result.snapshot)
}

function applyDelta(raw: unknown): void {
  const delta = raw as {
    seq?: unknown
    slice?: unknown
    event_type?: unknown
    payload?: unknown
  }
  if (typeof delta.seq === 'number') {
    dashboardWsLastSeq.value = delta.seq
    void sendRpc('dashboard/ack', {
      seq: delta.seq,
      bufferedAmount: socket?.bufferedAmount ?? 0,
    }).catch(() => {})
  }
  if (typeof delta.slice !== 'string') return
  hydrateDashboardSlice(
    delta.slice,
    delta.payload,
    typeof delta.event_type === 'string' ? delta.event_type : undefined,
  )
}

function handleNotification(raw: JsonObject): boolean {
  if (raw.method === 'dashboard/delta') {
    applyDelta(raw.params)
    return true
  }
  if (raw.method === 'dashboard/snapshot') {
    applySnapshot(raw.params)
    return true
  }
  return false
}

function unwrapSseCandidate(raw: JsonObject): unknown {
  const params = raw.params as { type?: unknown } | undefined
  if (raw.jsonrpc && params?.type) return params
  return raw
}

function handleRawPush(raw: unknown): void {
  if (!raw || typeof raw !== 'object') return
  const candidate = unwrapSseCandidate(raw as JsonObject)
  const parsed = parseSSEMessage(candidate)
  if (!parsed) return
  routeServerPushEvent(parsed as unknown as SSEEvent)
}

export function parseWebSocketSseFrames(data: string): unknown[] {
  const payloads: unknown[] = []
  const frames = data.split(/\r?\n\r?\n/)
  for (const frame of frames) {
    const dataLines: string[] = []
    for (const line of frame.split(/\r?\n/)) {
      if (!line.startsWith('data:')) continue
      const value = line.slice('data:'.length)
      dataLines.push(value.startsWith(' ') ? value.slice(1) : value)
    }
    if (dataLines.length === 0) continue
    const body = dataLines.join('\n').trim()
    if (!body || body === '[DONE]') continue
    try {
      payloads.push(JSON.parse(body))
    } catch {
      // Non-JSON SSE frames are ignored; dashboard pushes are JSON.
    }
  }
  return payloads
}

function handleMessage(data: unknown): void {
  if (typeof data !== 'string') return
  let raw: unknown
  try {
    raw = JSON.parse(data)
  } catch {
    for (const payload of parseWebSocketSseFrames(data)) {
      handleRawPush(payload)
    }
    return
  }
  if (!raw || typeof raw !== 'object') return
  const record = raw as JsonObject
  if (handleRpcResponse(record)) return
  if (handleNotification(record)) return
  handleRawPush(record)
}

export async function subscribeDashboardRoute(routeState: DashboardRouteState): Promise<void> {
  const desired = rememberRouteState(routeState)
  if (!dashboardWsReady.value) return
  const slices = dashboardSlicesForRoute(desired)
  const key = `${routeKey(desired)}|${slices.join(',')}`
  if (key === lastSubscribeKey) return
  lastSubscribeKey = key
  try {
    const result = await sendRpc('dashboard/subscribe', {
      route: routeKey(desired),
      slices,
    })
    if (lastSubscribeKey !== key) return
    applySubscribeResult(result)
  } catch (err) {
    if (lastSubscribeKey === key) lastSubscribeKey = ''
    throw err
  }
}

export async function connectDashboardWS(routeState?: DashboardRouteState): Promise<void> {
  if (routeState) rememberRouteState(routeState)
  if (typeof WebSocket === 'undefined') return
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return
  }

  shouldReconnect = true
  clearReconnectTimer()
  const generation = ++connectGeneration
  let wsUrl: string | null
  try {
    wsUrl = await discoverWsUrl()
  } catch (err) {
    if (generation === connectGeneration && shouldReconnect) {
      dashboardWsLastError.value = err instanceof Error ? err.message : String(err)
    }
    return
  }
  if (!wsUrl || !shouldReconnect || generation !== connectGeneration) return

  closeSocket()
  const ws = new WebSocket(wsUrl)
  socket = ws
  ws.onopen = () => {
    if (socket !== ws) return
    dashboardWsConnected.value = true
    reconnectAttempts = 0
    const token = sessionStorage.getItem('masc_bearer_token')
    void sendRpc('dashboard/hello', {
      protocol: 'dashboard-ws.v1',
      token: token ?? undefined,
      features: ['snapshot', 'delta', 'mode_snapshot'],
    })
      .then(() => {
        dashboardWsReady.value = true
        dashboardWsLastError.value = null
        if (desiredRouteState) {
          void subscribeDashboardRoute(desiredRouteState)
        }
      })
      .catch(err => {
        dashboardWsReady.value = false
        dashboardWsLastError.value = err instanceof Error ? err.message : String(err)
      })
  }
  ws.onmessage = (event) => {
    if (socket !== ws) return
    handleMessage(event.data)
  }
  ws.onerror = () => {
    if (socket !== ws) return
    dashboardWsLastError.value = 'dashboard websocket error'
  }
  ws.onclose = () => {
    if (socket !== ws) return
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    lastSubscribeKey = ''
    socket = null
    scheduleReconnect()
  }
}

export function disconnectDashboardWS(): void {
  shouldReconnect = false
  connectGeneration += 1
  clearReconnectTimer()
  dashboardWsConnected.value = false
  dashboardWsReady.value = false
  lastSubscribeKey = ''
  desiredRouteState = null
  closeSocket()
}
