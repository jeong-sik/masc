import type { RouteState, SSEEvent } from './types'
import { parseSSEMessage } from './schemas/sse'
import { hydrateDashboardSlice, routeServerPushEvent } from './sse-store'
import { batch } from '@preact/signals'
import { dashboardBearerToken, subscribeStoredTokenChanges } from './api/core'
import { parseWebSocketSseFrames } from './dashboard-ws-parse'
import {
  GLOBAL_DASHBOARD_PUSH_SLICES,
  type DashboardPushSlice,
} from './dashboard-slices'
import {
  DASHBOARD_WS_DISCOVERY_CACHE_MAX_FAILURES,
  DASHBOARD_WS_HEARTBEAT_INTERVAL_MS,
  DASHBOARD_WS_HEARTBEAT_RPC_TIMEOUT_MS,
  DASHBOARD_WS_RPC_TIMEOUT_MS,
  RECONNECT_JITTER_MS,
  RECONNECT_MAX_MS,
} from './config/constants'
import {
  dashboardWsConnected,
  dashboardWsLastError,
  dashboardWsLastSeq,
  dashboardWsReady,
  noteDashboardWsEvent,
  noteDashboardWsPing,
  noteDashboardWsPong,
} from './dashboard-ws-state'
import { errorToString } from './lib/format-string'

type JsonObject = Record<string, unknown>
type PendingRpc = {
  resolve: (value: unknown) => void
  reject: (err: Error) => void
  timeout: ReturnType<typeof setTimeout>
}
type ParseWorkerJob = {
  data: string
  generation: number
  timeout: ReturnType<typeof setTimeout>
}
type DashboardRouteState = Pick<RouteState, 'tab' | 'params'>

interface DashboardWsDiscovery {
  enabled?: boolean
  listening?: boolean
  reachable?: boolean
  listen_status?: string | null
  ws_url?: string | null
  unavailable_reason?: string | null
  same_origin_upgrade_enabled?: boolean
  same_origin_upgrade_path?: string | null
  same_origin_ws_url?: string | null
}

interface DashboardWsDiscoveryResult {
  wsUrl: string | null
  retry: boolean
  fromCache: boolean
  reason?: string
}

const DASHBOARD_WS_DISCOVERY_CACHE_KEY = 'masc.dashboard.ws.discovery.v1'
const DASHBOARD_WS_PARSE_TIMEOUT_MS = 5_000

let socket: WebSocket | null = null
let rpcId = 0
let reconnectTimer: ReturnType<typeof setTimeout> | null = null
let heartbeatTimer: ReturnType<typeof setInterval> | null = null
let heartbeatInFlight = false
let reconnectAttempts = 0
let lastSubscribeKey = ''
let desiredRouteState: DashboardRouteState | null = null
let shouldReconnect = true
let connectGeneration = 0
let discoveryCacheFailureCount = 0
let helloFailed = false
const pending = new Map<number, PendingRpc>()

// WebSocket close codes that indicate a persistent failure and should stop
// reconnection attempts: 1002 protocol error, 1003 unsupported data, and 1008
// policy violation per RFC 6455.  1011 (internal server error) is kept
// reconnectable because it is usually a transient server-side condition
// (restart/crash/redeploy) rather than a protocol-level rejection.
const FATAL_CLOSE_CODES = new Set([1002, 1003, 1008])

function sessionStorageOrNull(): Storage | null {
  if (typeof sessionStorage === 'undefined') return null
  try {
    return sessionStorage
  } catch {
    return null
  }
}

function sameOriginWebSocketUrl(wsUrl: string): boolean {
  if (typeof window === 'undefined' || typeof window.location === 'undefined') return true
  const expectedProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  if (window.location.protocol !== 'https:' && window.location.protocol !== 'http:') return true
  try {
    const parsed = new URL(wsUrl, window.location.href)
    return parsed.protocol === expectedProtocol && parsed.host === window.location.host
  } catch {
    return false
  }
}

function currentOriginWebSocketUrl(pathOrUrl: string): string | null {
  if (typeof window === 'undefined' || typeof window.location === 'undefined') return null
  if (window.location.protocol !== 'https:' && window.location.protocol !== 'http:') return null
  try {
    const parsed = new URL(pathOrUrl, window.location.href)
    parsed.protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    parsed.host = window.location.host
    return parsed.toString()
  } catch {
    return null
  }
}

function sameOriginUpgradePath(data: DashboardWsDiscovery): string | null {
  const upgradePath = nonBlankString(data.same_origin_upgrade_path)
  if (upgradePath) return upgradePath
  const sameOriginWsUrl = nonBlankString(data.same_origin_ws_url)
  if (!sameOriginWsUrl) return null
  try {
    const baseUrl = typeof window !== 'undefined' && typeof window.location !== 'undefined'
      ? window.location.href
      : 'http://localhost/'
    const parsed = new URL(sameOriginWsUrl, baseUrl)
    return `${parsed.pathname}${parsed.search}${parsed.hash}`
  } catch {
    return null
  }
}

function preferredDiscoveredWsUrl(data: DashboardWsDiscovery): string | null {
  if (data.same_origin_upgrade_enabled === true) {
    const upgradePath = sameOriginUpgradePath(data)
    if (upgradePath) {
      const wsUrl = currentOriginWebSocketUrl(upgradePath)
      if (wsUrl) return wsUrl
    }
  }
  const wsUrl = nonBlankString(data.ws_url)
  if (wsUrl) return wsUrl
  const sameOriginWsUrl = nonBlankString(data.same_origin_ws_url)
  if (sameOriginWsUrl && sameOriginWebSocketUrl(sameOriginWsUrl)) return sameOriginWsUrl
  return null
}

function readCachedWsUrl(): string | null {
  const storage = sessionStorageOrNull()
  if (!storage) return null
  try {
    const raw = storage.getItem(DASHBOARD_WS_DISCOVERY_CACHE_KEY)
    if (!raw) return null
    const data = JSON.parse(raw) as { ws_url?: unknown }
    const wsUrl = nonBlankString(data.ws_url)
    if (!wsUrl) return null
    if (!sameOriginWebSocketUrl(wsUrl)) {
      storage.removeItem(DASHBOARD_WS_DISCOVERY_CACHE_KEY)
      return null
    }
    return wsUrl
  } catch {
    // Eviction must not propagate: in restricted storage contexts the
    // initial getItem can throw, and a follow-up removeItem can throw too.
    // If readCachedWsUrl propagates, discovery stops falling back to HTTP
    // /ws — exactly the wrong behavior in a degraded storage environment.
    // Degrade to null instead.
    try {
      storage.removeItem(DASHBOARD_WS_DISCOVERY_CACHE_KEY)
    } catch {
      // ignore secondary storage failure
    }
    return null
  }
}

function writeCachedWsUrl(wsUrl: string): void {
  const storage = sessionStorageOrNull()
  if (!storage) return
  try {
    storage.setItem(DASHBOARD_WS_DISCOVERY_CACHE_KEY, JSON.stringify({ ws_url: wsUrl }))
  } catch {
    // Ignore quota/private-mode failures; discovery still works without cache.
  }
}

function clearCachedWsUrl(): void {
  const storage = sessionStorageOrNull()
  if (!storage) return
  try {
    storage.removeItem(DASHBOARD_WS_DISCOVERY_CACHE_KEY)
  } catch {
    // Storage may be disabled; a failed clear is equivalent to no cache control.
  }
}

export function clearDashboardWsDiscoveryCacheForTests(): void {
  clearCachedWsUrl()
  discoveryCacheFailureCount = 0
}

function resetDiscoveryCacheFailures(): void {
  discoveryCacheFailureCount = 0
}

function maybeInvalidateDiscoveryCache(): void {
  discoveryCacheFailureCount += 1
  if (discoveryCacheFailureCount >= DASHBOARD_WS_DISCOVERY_CACHE_MAX_FAILURES) {
    clearCachedWsUrl()
    resetDiscoveryCacheFailures()
  }
}

function nonBlankString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

function discoveryUnavailableReason(data: DashboardWsDiscovery): string {
  const serverReason = nonBlankString(data.unavailable_reason)
  if (serverReason) return serverReason
  if (data.enabled !== true) return 'disabled'
  if (data.listening !== true) {
    const listenStatus = nonBlankString(data.listen_status)
    return listenStatus ? `not listening (${listenStatus})` : 'not listening'
  }
  if (!nonBlankString(data.ws_url)) {
    const sameOriginWsUrl = nonBlankString(data.same_origin_ws_url)
    if (sameOriginWsUrl && data.same_origin_upgrade_enabled !== true) {
      return 'standalone websocket URL unavailable; same-origin upgrade disabled'
    }
    if (data.same_origin_upgrade_enabled === true) {
      return 'same-origin websocket URL unavailable'
    }
    return 'websocket URL unavailable'
  }
  return 'unavailable'
}

function dashboardWsUnavailableMessage(reason?: string): string {
  return reason ? `dashboard websocket unavailable: ${reason}` : 'dashboard websocket unavailable'
}

// Phase 2 (PR-4.6): rAF accumulator for inbound WS messages.
// Instead of processing every WS frame immediately (which can trigger
// multiple signal writes / renders), we buffer them and flush on the
// next animation frame.  This bounds update frequency to 60 Hz and
// lets batch() coalesce all signal mutations in a single frame.
const pendingInbound: Array<string | unknown> = []
let flushHandle = 0

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
  if (job.generation !== connectGeneration || !socket) return
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

function cancelParseWorkerJobs(): void {
  for (const job of workerJobs.values()) {
    clearTimeout(job.timeout)
  }
  workerJobs.clear()
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
      if (job.generation !== connectGeneration || !socket) return
      deliverParsedPayloads(Array.isArray(payloads) ? payloads : [])
    }
    parseWorker.onerror = fallbackAllParseWorkerJobs
    parseWorker.onmessageerror = fallbackAllParseWorkerJobs
    return parseWorker
  } catch {
    return null
  }
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
  const slices = new Set<DashboardPushSlice>(GLOBAL_DASHBOARD_PUSH_SLICES)

  // Overview fleet statistics consume keeper data from the execution slice.
  if (routeState.tab === 'overview') {
    slices.add('execution')
  }
  if (routeState.tab === 'keepers') {
    slices.add('execution')
    slices.add('composite')
  }
  if (routeState.tab === 'registry') {
    slices.add('execution')
    slices.add('composite')
  }
  if (routeState.tab === 'board') {
    return Array.from(slices).sort()
  }
  if (routeState.tab === 'workspace' && routeState.params.section === 'planning') {
    slices.add('execution')
    slices.add('goals')
  }
  // Board rows are actor/filter scoped (`voter`, blind-vote policy, author and
  // hearth filters) and are loaded through refreshBoard's HTTP query. The WS
  // snapshot provider is route-scoped only, so subscribing the board slice here
  // can hydrate the list with a different query immediately after the route HTTP
  // refresh. Raw board SSE events still reach the client and schedule/increment
  // board refreshes through sse-store.
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

function clearHeartbeatTimer(): void {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer)
    heartbeatTimer = null
  }
  heartbeatInFlight = false
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

function websocketReadyStateName(state: number): string {
  if (typeof WebSocket !== 'undefined') {
    switch (state) {
      case WebSocket.CONNECTING:
        return 'CONNECTING'
      case WebSocket.OPEN:
        return 'OPEN'
      case WebSocket.CLOSING:
        return 'CLOSING'
      case WebSocket.CLOSED:
        return 'CLOSED'
    }
  }
  return `UNKNOWN(${state})`
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

function startHeartbeat(ws: WebSocket): void {
  clearHeartbeatTimer()
  heartbeatTimer = setInterval(() => {
    if (socket !== ws || ws.readyState !== WebSocket.OPEN || heartbeatInFlight) {
      return
    }
    heartbeatInFlight = true
    const sentAt = noteDashboardWsPing()
    void sendRpc('dashboard/ping', {}, DASHBOARD_WS_HEARTBEAT_RPC_TIMEOUT_MS)
      .then(() => {
        if (socket === ws) {
          noteDashboardWsPong(sentAt)
          heartbeatInFlight = false
        }
      })
      .catch(err => {
        heartbeatInFlight = false
        reconnectAfterCurrentSocketFailure(ws, err)
      })
  }, DASHBOARD_WS_HEARTBEAT_INTERVAL_MS)
}

function closeSocket(): void {
  clearHeartbeatTimer()
  if (socket) {
    socket.onopen = null
    socket.onclose = null
    socket.onerror = null
    socket.onmessage = null
    socket.close()
    socket = null
  }
  clearPendingInbound()
  cancelParseWorkerJobs()
  rejectPendingRpcs(new Error('dashboard websocket closed'))
}

async function discoverWsUrl(): Promise<DashboardWsDiscoveryResult> {
  const cachedUrl = readCachedWsUrl()
  if (cachedUrl) return { wsUrl: cachedUrl, retry: false, fromCache: true }

  const response = await fetch('/ws', { credentials: 'same-origin' })
  if (!response.ok) {
    return {
      wsUrl: null,
      retry: true,
      fromCache: false,
      reason: `discovery HTTP ${response.status}`,
    }
  }
  const data = await response.json() as DashboardWsDiscovery
  if (data.enabled !== true) {
    return {
      wsUrl: null,
      retry: false,
      fromCache: false,
      reason: discoveryUnavailableReason(data),
    }
  }
  const wsUrl = preferredDiscoveredWsUrl(data)
  if (data.listening !== true || !wsUrl) {
    return {
      wsUrl: null,
      retry: true,
      fromCache: false,
      reason: discoveryUnavailableReason(data),
    }
  }
  return { wsUrl, retry: false, fromCache: false }
}

function sendRpc(method: string, params: JsonObject, timeoutMs = DASHBOARD_WS_RPC_TIMEOUT_MS): Promise<unknown> {
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
    }, timeoutMs)
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
  const currentSocket = socket
  if (!currentSocket) return
  if (currentSocket.readyState !== WebSocket.OPEN) {
    reconnectAfterCurrentSocketFailure(
      currentSocket,
      new Error(
        `dashboard websocket notification send skipped while socket state=${websocketReadyStateName(currentSocket.readyState)}: ${method}`,
      ),
    )
    return
  }
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
    // A thrown send on a socket whose readyState claimed OPEN signals a
    // half-open connection. Treat it like any other transport failure and
    // reconnect rather than letting subsequent deltas stack up un-acked.
    reconnectAfterCurrentSocketFailure(currentSocket, err)
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
    // Server fan-out may split one logical delta into a shared payload frame
    // and a small per-session seq frame. A seq-only frame is an ACK checkpoint.
    if (typeof delta.slice !== 'string') return
    noteDashboardWsEvent()
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
  })
}

function handleMessage(data: unknown): void {
  if (typeof data !== 'string') return
  const worker = initParseWorker()
  if (worker) {
    const id = ++workerJobId
    workerJobs.set(id, {
      data,
      generation: connectGeneration,
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
    dashboardWsLastError.value = errorToString(err)
  })
  maybeInvalidateDiscoveryCache()
  lastSubscribeKey = ''
  closeSocket()
  scheduleReconnect()
}

function reconnectAfterAuthTokenChange(): void {
  if (!desiredRouteState || typeof WebSocket === 'undefined') return
  shouldReconnect = true
  connectGeneration += 1
  clearReconnectTimer()
  lastSubscribeKey = ''
  batch(() => {
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
  })
  const nextRoute = desiredRouteState
  closeSocket()
  void connectDashboardWS(nextRoute)
}

subscribeStoredTokenChanges(() => {
  reconnectAfterAuthTokenChange()
})

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
        dashboardWsLastError.value = errorToString(err)
      })
      scheduleReconnect()
    }
    return
  }
  const wsUrl = discovery.wsUrl
  if (!wsUrl) {
    if (generation === connectGeneration) clearCachedWsUrl()
    if (generation === connectGeneration && shouldReconnect) {
      batch(() => {
        dashboardWsLastError.value = dashboardWsUnavailableMessage(discovery.reason)
      })
    }
    if (generation === connectGeneration && shouldReconnect && discovery.retry) {
      scheduleReconnect()
    }
    return
  }
  if (!shouldReconnect || generation !== connectGeneration) return

  closeSocket()
  helloFailed = false
  let ws: WebSocket
  try {
    ws = new WebSocket(wsUrl)
  } catch (err) {
    // A constructor failure proves this URL is unusable for the current
    // browser. Keep it out of the cache and let reconnect rediscover.
    maybeInvalidateDiscoveryCache()
    batch(() => {
      dashboardWsLastError.value = errorToString(err)
    })
    scheduleReconnect()
    return
  }
  socket = ws
  ws.onopen = () => {
    if (socket !== ws) return
    dashboardWsConnected.value = true
    reconnectAttempts = 0
    const token = dashboardBearerToken()
    void sendRpc('dashboard/hello', {
      protocol: 'dashboard-ws.v1',
      token: token ?? undefined,
      features: ['snapshot', 'delta', 'mode_snapshot'],
    })
      .then(() => {
        if (socket !== ws) return
        if (!discovery.fromCache) writeCachedWsUrl(wsUrl)
        resetDiscoveryCacheFailures()
        batch(() => {
          dashboardWsReady.value = true
          dashboardWsLastError.value = null
        })
        if (desiredRouteState) {
          void subscribeDashboardRoute(desiredRouteState)
            .then(() => {
              if (socket === ws) startHeartbeat(ws)
            })
            .catch(err => reconnectAfterCurrentSocketFailure(ws, err))
        } else {
          startHeartbeat(ws)
        }
      })
      .catch(err => {
        const errMsg = errorToString(err)
        // A hello timeout may be transient; keep reconnecting. An explicit
        // hello error (server rejected the handshake) or a socket close during
        // hello is fatal and should stop reconnection attempts.
        if (errMsg.includes('rpc timed out')) {
          reconnectAfterCurrentSocketFailure(ws, err)
          return
        }
        if (socket !== ws) return
        helloFailed = true
        batch(() => {
          dashboardWsConnected.value = false
          dashboardWsReady.value = false
          dashboardWsLastError.value = errMsg
        })
        closeSocket()
      })
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
    // Clean close (wasClean=true) is server-initiated (shutdown/redeploy/idle),
    // not a degraded-WS error. Leaving lastError set on a clean close would trip
    // the SSE fallback (dashboard-transport-fallback.ts) for every clean close ->
    // reconnect window, producing the "dashboard keeps falling back to SSE"
    // symptom. Abnormal closes (wasClean=false: network drop, code 1006/1011)
    // keep lastError set so the fallback still engages. reconnect runs either
    // way; pending RPCs are rejected either way (socket is gone).
    const clean = event.wasClean === true
    // Fatal closes indicate a persistent condition (policy violation, server
    // error, or abnormal close after hello was explicitly rejected). Stop
    // reconnecting so the client does not spin on a rejected session.
    const fatal = FATAL_CLOSE_CODES.has(event.code) || (helloFailed && !clean)
    clearHeartbeatTimer()
    batch(() => {
      dashboardWsConnected.value = false
      dashboardWsReady.value = false
      dashboardWsLastError.value = clean ? null : closeError.message
    })
    if (!fatal) {
      maybeInvalidateDiscoveryCache()
    }
    lastSubscribeKey = ''
    socket = null
    cancelParseWorkerJobs()
    rejectPendingRpcs(closeError)
    if (fatal) {
      shouldReconnect = false
      return
    }
    scheduleReconnect()
  }
}

export function disconnectDashboardWS(): void {
  shouldReconnect = false
  connectGeneration += 1
  clearReconnectTimer()
  helloFailed = false
  discoveryCacheFailureCount = 0
  batch(() => {
    dashboardWsConnected.value = false
    dashboardWsReady.value = false
  })
  lastSubscribeKey = ''
  desiredRouteState = null
  closeSocket()
}
