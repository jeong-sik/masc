import type { RouteState, SSEEvent } from './types'
import { parseSSEMessage } from './schemas/sse'
import { hydrateDashboardSlice, routeServerPushEvent } from './sse-store'
import { batch } from '@preact/signals'
import { parseWebSocketSseFrames as parseWebSocketSseFramesImpl } from './dashboard-ws-parse'
import {
  DASHBOARD_WS_RPC_TIMEOUT_MS,
  RECONNECT_JITTER_MS,
  RECONNECT_MAX_MS,
} from './config/constants'

// Re-export for test consumers that assert on frame parsing.
export const parseWebSocketSseFrames = parseWebSocketSseFramesImpl
import {
  dashboardWsConnected,
  dashboardWsLastError,
  dashboardWsLastSeq,
  dashboardWsReady,
  noteDashboardWsEvent,
} from './dashboard-ws-state'

type JsonObject = Record<string, unknown>
type PendingRpc = {
  resolve: (value: unknown) => void
  reject: (err: Error) => void
  timeout: ReturnType<typeof setTimeout>
}
type ParseWorkerJob = {
  data: string
  timeout: ReturnType<typeof setTimeout>
}
type DashboardRouteState = Pick<RouteState, 'tab' | 'params'>

interface DashboardWsDiscovery {
  enabled?: boolean
  listening?: boolean
  ws_url?: string
}

interface DashboardWsDiscoveryResult {
  wsUrl: string | null
  retry: boolean
}

const DASHBOARD_WS_PARSE_TIMEOUT_MS = 5_000

let socket: WebSocket | null = null
let rpcId = 0
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let reconnectAttempts = 0
let lastSubscribeKey = ''
let desiredRouteState: DashboardRouteState | null = null
let shouldReconnect = true
let connectGeneration = 0
const pending = new Map<number, PendingRpc>()

// Phase 2 (PR-4.6): rAF accumulator for inbound WS messages.
// Instead of processing every WS frame immediately (which can trigger
// multiple signal writes / renders), we buffer them and flush on the
// next animation frame.  This bounds update frequency to 60 Hz and
// lets batch() coalesce all signal mutations in a single frame.
const pendingInbound: Array<string | unknown> = []
let flushHandle = 0

// Phase 2 (PR-4.5): Offload JSON/SSE parsing to a Web Worker so the
// main thread never blocks on large payloads.
let parseWorker: Worker | null = null
let workerJobId = 0
const workerJobs = new Map<number, ParseWorkerJob>()

function deliverParsedPayloads(payloads: unknown[]): void {
  for (const payload of payloads) {
    pendingInbound.push(payload)
  }
  scheduleFlush()
}

function fallbackParseWorkerJob(id: number): void {
  const job = workerJobs.get(id)
  if (!job) return
  workerJobs.delete(id)
  clearTimeout(job.timeout)
  pendingInbound.push(job.data)
  scheduleFlush()
}

function fallbackAllParseWorkerJobs(): void {
  for (const id of Array.from(workerJobs.keys())) {
    fallbackParseWorkerJob(id)
  }
  parseWorker?.terminate()
  parseWorker = null
}

function initParseWorker(): Worker | null {
  if (parseWorker) return parseWorker
  if (typeof Worker === 'undefined') return null
  try {
    parseWorker = new Worker(
      new URL('./workers/dashboard-ws.worker.ts', import.meta.url),
    )
    parseWorker.onmessage = (event) => {
      const { id, payloads } = event.data as {
        id: number
        payloads: unknown[]
      }
      const job = workerJobs.get(id)
      if (!job) return
      workerJobs.delete(id)
      clearTimeout(job.timeout)
      deliverParsedPayloads(Array.isArray(payloads) ? payloads : [])
    }
    parseWorker.onerror = fallbackAllParseWorkerJobs
    parseWorker.onmessageerror = fallbackAllParseWorkerJobs
    return parseWorker
  } catch {
    return null
  }
}

function scheduleFlush(): void {
  if (flushHandle) return
  if (typeof requestAnimationFrame === 'undefined') {
    // Fallback for non-browser environments (e.g. vitest with happy-dom).
    flushHandle = setTimeout(() => {
      flushHandle = 0
      flushPending()
    }, 0) as unknown as number
    return
  }
  flushHandle = requestAnimationFrame(() => {
    flushHandle = 0
    flushPending()
  })
}

function flushPending(): void {
  const batchData = pendingInbound.slice()
  pendingInbound.length = 0
  for (const data of batchData) {
    if (typeof data === 'string') {
      processInboundMessage(data)
    } else {
      processInboundParsedMessage(data)
    }
  }
}

function clearPendingInbound(): void {
  pendingInbound.length = 0
  if (flushHandle) {
    if (typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(flushHandle)
    } else {
      clearTimeout(flushHandle)
    }
    flushHandle = 0
  }
}

/** Test-only helper: synchronously flush any pending inbound messages.
 *  Production code should never call this — the rAF loop owns timing. */
export function flushPendingInbound(): void {
  if (flushHandle) {
    if (typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(flushHandle)
    } else {
      clearTimeout(flushHandle)
    }
    flushHandle = 0
  }
  flushPending()
}

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

  // Overview tab needs execution slice for World Visualizer keeper fleet data.
  if (routeState.tab === 'overview') {
    slices.add('execution')
  }
  if (routeState.tab === 'workspace' && routeState.params.section === 'planning') {
    slices.add('execution')
    slices.add('goals')
  }
  if (routeState.tab === 'workspace' && routeState.params.section === 'board') {
    slices.add('board')
  }
  if (routeState.tab === 'monitoring') {
    const section = routeState.params.section
    if (section === 'observatory' || section === 'journey' || section === 'agents' || section === 'cognition') {
      slices.add('execution')
    }
    if (section === 'agents' || section === 'cognition') {
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

function rejectPendingRpcs(err: Error): void {
  for (const { reject, timeout } of pending.values()) {
    clearTimeout(timeout)
    reject(err)
  }
  pending.clear()
}

function formatCloseEventError(event: CloseEvent): string {
  const parts = [`code=${event.code}`, `wasClean=${event.wasClean}`]
  if (event.reason) parts.splice(1, 0, `reason=${event.reason}`)
  return `dashboard websocket closed (${parts.join(', ')})`
}

// WebSocket reconnect uses an explicit 500ms base (half of the SSE
// RECONNECT_BASE_MS) so transient socket churn recovers faster. Derive the
// exp clamp from the configured cap so a future operator bump of
// RECONNECT_MAX_MS actually grows the achievable backoff.
const WS_RECONNECT_BASE_MS = 500
const WS_RECONNECT_MAX_EXP = Math.max(
  1,
  Math.ceil(Math.log2(RECONNECT_MAX_MS / WS_RECONNECT_BASE_MS)),
)

function scheduleReconnect(): void {
  if (!shouldReconnect) return
  if (reconnectTimer) return
  reconnectAttempts += 1
  const exp = Math.min(reconnectAttempts, WS_RECONNECT_MAX_EXP)
  const backoff = Math.min(RECONNECT_MAX_MS, WS_RECONNECT_BASE_MS * Math.pow(2, exp))
  const jitter = Math.random() * RECONNECT_JITTER_MS
  const delay = backoff + jitter
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
  clearPendingInbound()
  rejectPendingRpcs(new Error('dashboard websocket closed'))
}

async function discoverWsUrl(): Promise<DashboardWsDiscoveryResult> {
  const response = await fetch('/ws', { credentials: 'same-origin' })
  if (!response.ok) return { wsUrl: null, retry: true }
  const data = await response.json() as DashboardWsDiscovery
  if (data.enabled !== true) {
    return { wsUrl: null, retry: false }
  }
  if (data.listening !== true || typeof data.ws_url !== 'string') {
    return { wsUrl: null, retry: true }
  }
  return { wsUrl: data.ws_url, retry: false }
}

function sendRpc(method: string, params: JsonObject): Promise<unknown> {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return Promise.reject(new Error('dashboard websocket is not open'))
  }
  const currentSocket = socket
  const id = ++rpcId
  const payload = { jsonrpc: '2.0', id, method, params }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      if (!pending.delete(id)) return
      reject(new Error(`dashboard websocket rpc timed out: ${method}`))
    }, DASHBOARD_WS_RPC_TIMEOUT_MS)
    pending.set(id, { resolve, reject, timeout })
    try {
      currentSocket.send(JSON.stringify(payload))
    } catch (err) {
      pending.delete(id)
      clearTimeout(timeout)
      reject(err instanceof Error ? err : new Error(String(err)))
    }
  })
}

function sendNotification(method: string, params: JsonObject): void {
  if (!socket || socket.readyState !== WebSocket.OPEN) return
  const currentSocket = socket
  try {
    currentSocket.send(JSON.stringify({ jsonrpc: '2.0', method, params }))
  } catch (err) {
    // Best-effort telemetry; the close/error path owns reconnect decisions.
    // P1 silent-failure fix: previously the catch was empty, so a flood
    // of dropped notifications (e.g. socket transitioning to closing
    // mid-send, or readyState lying) was completely invisible.  At least
    // surface to the console so operators can see the drop pattern in
    // DevTools when investigating "server keeps re-sending stale deltas."
    console.warn('[dashboard-ws] sendNotification failed', { method, err })
  }
}

function handleRpcResponse(raw: JsonObject): boolean {
  if (typeof raw.id !== 'number') return false
  const pendingRpc = pending.get(raw.id)
  if (!pendingRpc) return true
  pending.delete(raw.id)
  clearTimeout(pendingRpc.timeout)
  const error = raw.error as { message?: unknown } | undefined
  if (error) {
    pendingRpc.reject(new Error(typeof error.message === 'string' ? error.message : 'dashboard websocket rpc failed'))
  } else {
    pendingRpc.resolve(raw.result)
  }
  return true
}

function applySnapshot(raw: unknown): void {
  batch(() => {
    const snapshot = raw as { slices?: unknown; seq?: unknown }
    if (typeof snapshot.seq === 'number') {
      dashboardWsLastSeq.value = snapshot.seq
    }
    const slices = snapshot.slices as Record<string, unknown> | undefined
    if (!slices || typeof slices !== 'object') return
    for (const [slice, payload] of Object.entries(slices)) {
      hydrateRouteDashboardSlice(slice, payload)
    }
  })
}

function applySubscribeResult(raw: unknown): void {
  const result = raw as { snapshot?: unknown }
  if (result.snapshot) applySnapshot(result.snapshot)
}

function applyDelta(raw: unknown): void {
  batch(() => {
    const delta = raw as {
      seq?: unknown
      slice?: unknown
      event_type?: unknown
      payload?: unknown
    }
    if (typeof delta.seq === 'number') {
      dashboardWsLastSeq.value = delta.seq
      sendNotification('dashboard/ack', {
        seq: delta.seq,
        bufferedAmount: socket?.bufferedAmount ?? 0,
      })
    }
    noteDashboardWsEvent()
    if (typeof delta.slice !== 'string') return
    hydrateRouteDashboardSlice(
      delta.slice,
      delta.payload,
      typeof delta.event_type === 'string' ? delta.event_type : undefined,
    )
  })
}

function activeRouteWantsDashboardSlice(slice: string): boolean {
  if (!desiredRouteState) return true
  return dashboardSlicesForRoute(desiredRouteState).includes(slice)
}

function hydrateRouteDashboardSlice(slice: string, payload: unknown, eventType?: string): void {
  if (!activeRouteWantsDashboardSlice(slice)) return
  hydrateDashboardSlice(slice, payload, eventType)
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
  batch(() => {
    if (!raw || typeof raw !== 'object') return
    const candidate = unwrapSseCandidate(raw as JsonObject)
    const parsed = parseSSEMessage(candidate)
    if (!parsed) return
    routeServerPushEvent(parsed as unknown as SSEEvent)
  })
}

function processInboundParsedMessage(raw: unknown): void {
  batch(() => {
    if (!raw || typeof raw !== 'object') return
    const record = raw as JsonObject
    if (handleRpcResponse(record)) return
    if (handleNotification(record)) return
    handleRawPush(record)
  })
}

function processInboundMessage(data: string): void {
  batch(() => {
    let raw: unknown
    try {
      raw = JSON.parse(data)
    } catch {
      for (const payload of parseWebSocketSseFramesImpl(data)) {
        handleRawPush(payload)
      }
      return
    }
    if (!raw || typeof raw !== 'object') return
    const record = raw as JsonObject
    if (handleRpcResponse(record)) return
    if (handleNotification(record)) return
    handleRawPush(record)
  })
}

function handleMessage(data: unknown): void {
  if (typeof data !== 'string') return
  const worker = initParseWorker()
  if (worker) {
    const id = ++workerJobId
    workerJobs.set(id, {
      data,
      timeout: setTimeout(() => {
        fallbackParseWorkerJob(id)
      }, DASHBOARD_WS_PARSE_TIMEOUT_MS),
    })
    try {
      worker.postMessage({ id, data })
    } catch {
      fallbackParseWorkerJob(id)
      parseWorker = null
    }
    return
  }
  pendingInbound.push(data)
  scheduleFlush()
}

function reconnectAfterCurrentSocketFailure(ws: WebSocket, err: unknown): void {
  if (socket !== ws) return
  batch(() => {
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
    dashboardWsLastError.value = err instanceof Error ? err.message : String(err)
  })
  lastSubscribeKey = ''
  closeSocket()
  scheduleReconnect()
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
  let discovery: DashboardWsDiscoveryResult
  try {
    discovery = await discoverWsUrl()
  } catch (err) {
    if (generation === connectGeneration && shouldReconnect) {
      batch(() => {
        dashboardWsLastError.value = err instanceof Error ? err.message : String(err)
      })
      scheduleReconnect()
    }
    return
  }
  const wsUrl = discovery.wsUrl
  if (!wsUrl) {
    if (generation === connectGeneration && shouldReconnect && discovery.retry) {
      batch(() => {
        dashboardWsLastError.value = 'dashboard websocket unavailable'
      })
      scheduleReconnect()
    }
    return
  }
  if (!shouldReconnect || generation !== connectGeneration) return

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
        if (socket !== ws) return
        batch(() => {
          dashboardWsReady.value = true
          dashboardWsLastError.value = null
        })
        if (desiredRouteState) {
          void subscribeDashboardRoute(desiredRouteState)
            .catch(err => reconnectAfterCurrentSocketFailure(ws, err))
        }
      })
      .catch(err => reconnectAfterCurrentSocketFailure(ws, err))
  }
  ws.onmessage = (event) => {
    if (socket !== ws) return
    handleMessage(event.data)
  }
  ws.onerror = () => {
    if (socket !== ws) return
    batch(() => {
      dashboardWsLastError.value = 'dashboard websocket error'
    })
  }
  ws.onclose = (event) => {
    if (socket !== ws) return
    const closeError = new Error(formatCloseEventError(event))
    batch(() => {
      dashboardWsConnected.value = false
      dashboardWsReady.value = false
      dashboardWsLastError.value = closeError.message
    })
    lastSubscribeKey = ''
    socket = null
    rejectPendingRpcs(closeError)
    scheduleReconnect()
  }
}

export function disconnectDashboardWS(): void {
  shouldReconnect = false
  connectGeneration += 1
  clearReconnectTimer()
  batch(() => {
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
  })
  lastSubscribeKey = ''
  desiredRouteState = null
  closeSocket()
}
