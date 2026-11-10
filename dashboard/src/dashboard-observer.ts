import { batch } from '@preact/signals'
import { authHeaders, fetchControlPlane, subscribeStoredTokenChanges } from './api/core'
import { hasPendingDevTokenFailure, pendingDevTokenRetryDelayMs, ensureDevToken, refreshDevTokenAfterAuthError } from './api/dev-token'
import { DEFAULT_GET_TIMEOUT_MS, TRANSPORT_RETRY_BASE_MS, TRANSPORT_RETRY_MAX_MS } from './config/constants'
import { errorToString } from './lib/format-string'
import { isRecord } from './lib/type-guards'
import { isObserverInstance, OBSERVER_IDLE_TIMEOUT_HEADER, OBSERVER_INSTANCE_HEADER, ObserverAccessError } from './lib/observer-protocol'
import { readSse } from './lib/sse-reader'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from './lib/observation-refresh'
import { readDashboardObservationChangedPayload, writeDashboardObservationTopic } from './schemas/sse_event_generated'
import { parseSSEMessage } from './schemas/sse'
import { recordServerPushEvent } from './sse'
import { routeServerPushEvent } from './sse-store'
import type { DashboardObservationTopic } from './lib/observation-refresh'
import { captureDashboardObservationOwner } from './lib/observation-read-owner'
import { rejectOperatorSnapshotFrame, type OperatorSnapshotObservationSource } from './operator-snapshot-observation'
import {
  dashboardObserverConnected, dashboardObserverReady, dashboardObserverLastError,
  dashboardObserverLastActivityAt, noteDashboardObserverReady,
  noteDashboardObserverDisconnected, noteDashboardObserverEvent,
  noteDashboardObserverRejectedFrame,
} from './dashboard-observer-state'

let running = false
let generation = 0
let controller: AbortController | null = null
let retryTimer: ReturnType<typeof setTimeout> | null = null
let retryDelay = TRANSPORT_RETRY_BASE_MS
let unsubscribeToken: (() => void) | null = null
let credentialRecovery: 'available' | 'in_flight' | 'spent' = 'available'

/** Decode at the wire boundary. A scope always retains its original authority. */
export function receiveDashboardObserverEvent(raw: unknown, source?: OperatorSnapshotObservationSource): void {
  if (!isRecord(raw)) return
  const candidate = raw.jsonrpc && isRecord(raw.params) && typeof raw.params.type === 'string'
    ? raw.params : raw
  if (candidate.type === 'workspace_dataset_changed' && candidate.dataset === 'dashboard_observation') {
    const payload = readDashboardObservationChangedPayload(candidate)
    const topic = writeDashboardObservationTopic(payload.topic) as DashboardObservationTopic
    switch (payload.scope.kind) {
      case 'Workspace': publishDashboardObservationChange({ topic }); break
      case 'Keeper':
        if (!payload.scope.value.trim()) throw new Error('observer keeper scope is empty')
        publishDashboardObservationChange({ topic, keeperName: payload.scope.value }); break
      case 'Operation': {
        const { keeper_name, operation_id } = payload.scope.value
        if (!keeper_name.trim() || !operation_id.trim()) throw new Error('observer operation scope is empty')
        publishDashboardObservationChange({ topic, keeperName: keeper_name, operationId: operation_id }); break
      }
      default:
        payload.scope satisfies never
        throw new Error('unhandled observation scope')
    }
    noteDashboardObserverEvent()
    return
  }
  const event = parseSSEMessage(candidate)
  if (!event) {
    if (candidate.type === 'operator_snapshot') {
      noteDashboardObserverRejectedFrame('Operator Snapshot observation envelope is invalid')
      if (source !== undefined) rejectOperatorSnapshotFrame(candidate.payload, source)
    }
    return
  }
  batch(() => {
    noteDashboardObserverEvent()
    recordServerPushEvent(event)
    routeServerPushEvent(event)
  })
}

function clearRetry(): void {
  if (retryTimer !== null) clearTimeout(retryTimer)
  retryTimer = null
}

function current(attempt: number): boolean { return running && attempt === generation }

function lost(error?: unknown): void {
  batch(() => {
    if (dashboardObserverReady.peek()) noteDashboardObserverDisconnected()
    dashboardObserverConnected.value = false
    dashboardObserverReady.value = false
    dashboardObserverLastError.value = error === undefined ? null : errorToString(error)
  })
}

function scheduleRetry(attempt: number): void {
  if (!current(attempt) || retryTimer !== null) return
  retryTimer = setTimeout(() => {
    retryTimer = null
    if (current(attempt)) startAttempt()
  }, Math.max(retryDelay, pendingDevTokenRetryDelayMs()))
  retryDelay = Math.min(retryDelay * 2, TRANSPORT_RETRY_MAX_MS)
}

function startAttempt(): void {
  clearRetry()
  controller?.abort()
  const abort = new AbortController()
  controller = abort
  const attempt = ++generation
  void observe(attempt, abort)
}

async function observe(attempt: number, abort: AbortController): Promise<void> {
  let body: ReadableStream<Uint8Array> | null = null
  let deadline: ReturnType<typeof setTimeout> | undefined
  let timedOut = false
  try {
    await ensureDevToken()
    if (!current(attempt) || abort.signal.aborted) return
    const authority = captureDashboardObservationOwner()
    deadline = setTimeout(() => { timedOut = true; abort.abort() }, DEFAULT_GET_TIMEOUT_MS)
    const response = await fetchControlPlane('/mcp?sse_kind=observer', {
      signal: abort.signal,
      credentials: 'omit',
      headers: { ...authHeaders(), Accept: 'text/event-stream' },
    })
    clearTimeout(deadline)
    deadline = undefined
    body = response.body
    if (!current(attempt) || abort.signal.aborted) return
    if (response.status === 401 || response.status === 403) {
      let renewed = false
      if (response.status === 401 && credentialRecovery === 'available') {
        credentialRecovery = 'in_flight'
        try { renewed = await refreshDevTokenAfterAuthError('invalid_token') }
        finally {
          if (credentialRecovery === 'in_flight') credentialRecovery = 'spent'
        }
      }
      if (renewed) {
        // The token-change listener already started the new generation.
        if (current(attempt)) startAttempt()
        return
      }
      if (hasPendingDevTokenFailure()) throw new Error('observer credential read remains unavailable')
      throw new ObserverAccessError(response.status)
    }
    if (!response.ok) throw new Error(`observer request failed (${response.status})`)
    if (!body || !response.headers.get('content-type')?.toLowerCase().startsWith('text/event-stream')) {
      throw new Error('observer stream response is unavailable')
    }
    const instance = response.headers.get(OBSERVER_INSTANCE_HEADER)
    const timeout = response.headers.get(OBSERVER_IDLE_TIMEOUT_HEADER)
    const idleTimeoutMs = timeout !== null && /^[1-9][0-9]*$/.test(timeout) ? Number(timeout) : NaN
    if (!isObserverInstance(instance) || response.headers.get('x-masc-sse-replay') !== 'fresh'
        || !Number.isSafeInteger(idleTimeoutMs) || idleTimeoutMs > 2_147_483_647) {
      throw new Error('observer admission authority is unavailable')
    }
    retryDelay = TRANSPORT_RETRY_BASE_MS
    credentialRecovery = 'available'
    batch(() => {
      dashboardObserverConnected.value = true
      dashboardObserverLastError.value = null
      noteDashboardObserverReady(instance, idleTimeoutMs)
    })
    // This connection is admitted before any authoritative recovery reads.
    // Every reconnect requests a fresh stream and re-reads mounted scopes.
    publishDashboardObservationRecovery()
    await readSse(body, (_event, data) => {
      if (!current(attempt)) return
      try { receiveDashboardObserverEvent(JSON.parse(data), { authority, instance }) }
      catch (error) {
        noteDashboardObserverRejectedFrame(errorToString(error))
      }
    }, {
      idleTimeoutMs,
      signal: abort.signal,
      onActivity: () => { if (current(attempt)) dashboardObserverLastActivityAt.value = Date.now() },
    })
    if (current(attempt)) throw new Error('observer stream closed')
  } catch (error) {
    if (!current(attempt) || (abort.signal.aborted && !timedOut)) return
    lost(timedOut ? new Error('observer connection timed out') : error)
    if (!(error instanceof ObserverAccessError)) scheduleRetry(attempt)
  } finally {
    if (deadline !== undefined) clearTimeout(deadline)
    abort.abort()
    if (body && !body.locked) void body.cancel().catch(() => {})
    if (controller === abort) controller = null
  }
}

export function connectDashboardObserver(): void {
  if (running) return
  running = true
  retryDelay = TRANSPORT_RETRY_BASE_MS
  credentialRecovery = 'available'
  unsubscribeToken = subscribeStoredTokenChanges(() => {
    if (!running) return
    lost()
    retryDelay = TRANSPORT_RETRY_BASE_MS
    if (credentialRecovery !== 'in_flight') credentialRecovery = 'available'
    startAttempt()
  })
  startAttempt()
}

export function disconnectDashboardObserver(): void {
  running = false
  generation++
  clearRetry()
  controller?.abort()
  controller = null
  unsubscribeToken?.()
  unsubscribeToken = null
  lost()
}
