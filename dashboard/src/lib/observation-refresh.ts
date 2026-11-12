import { TRANSPORT_RETRY_BASE_MS, TRANSPORT_RETRY_MAX_MS } from '../config/constants'
import { ApiRequestError } from '../api/core'
import {
  captureDashboardObservationOwner,
  dashboardObservationOwnerHasWorkspace,
  dashboardObservationOwnerIsCurrent,
  subscribeDashboardObservationOwnerChanges,
  type DashboardObservationOwner,
} from './observation-read-owner'

// Observation topics name authoritative read models. The transport publishes
// invalidations here; a mounted consumer reads only the models it uses.
import { readDashboardObservationTopic } from '../schemas/sse_event_generated'
import type { DashboardObservationTopic as GeneratedTopic } from '../schemas/sse_event_generated'

export type DashboardObservationTopic = Lowercase<GeneratedTopic['kind']>

export interface DashboardObservationChange {
  readonly topic: DashboardObservationTopic
  readonly keeperName?: string
  readonly operationId?: string
}

export interface DashboardObservationSelection {
  readonly topics: readonly DashboardObservationTopic[]
  readonly keeperName?: string
  readonly operationId?: string
}

type Observer = {
  readonly selection: DashboardObservationSelection
  readonly change: () => void
  readonly recovery: () => void
}

const observers = new Set<Observer>()

/** This read published no authoritative projection. Its producer, a newer
 * accepted observation, or recovery/focus owns completion without polling. */
export class ObservationPending extends Error {}

const recoveryOwnedFailures = new WeakSet<object>()

/** The store owns this failure's retry debt. Retain the exact error object,
 * including HTTP status and identity, without mutating/forking its contract. */
export function retainObservationReadFailure(cause: unknown): unknown {
  const failure = typeof cause === 'object' && cause !== null ? cause : new Error(String(cause))
  recoveryOwnedFailures.add(failure)
  return failure
}

function hasReadRecoveryOwner(cause: unknown): boolean {
  return typeof cause === 'object' && cause !== null && recoveryOwnedFailures.has(cause)
}

/** A combined read must not let an earlier transient error hide a refused
 * sibling request and repeatedly resend that sibling's credential. */
export function selectObservationReadFailure(causes: readonly unknown[]): unknown | null {
  return causes.find(cause => cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403))
    ?? causes.find(cause => cause !== null && cause !== undefined) ?? null
}

export function isDashboardObservationTopic(value: unknown): value is DashboardObservationTopic {
  try { readDashboardObservationTopic(value); return true } catch { return false }
}

export function publishDashboardObservationChange(change: DashboardObservationChange): void {
  for (const observer of [...observers]) {
    const { selection } = observer
    if (!selection.topics.includes(change.topic)) continue
    if (selection.keeperName !== undefined && change.keeperName !== undefined
      && selection.keeperName !== change.keeperName) continue
    if (selection.operationId !== undefined && change.operationId !== undefined
      && selection.operationId !== change.operationId) continue
    observer.change()
  }
}

/** Reconnect, lost replay, credentials or workspace authority changed. */
export function publishDashboardObservationRecovery(): void {
  for (const observer of [...observers]) observer.recovery()
}

export function subscribeDashboardObservation(
  selection: DashboardObservationSelection,
  change: () => void,
  recovery: () => void = change,
): () => void {
  const observer = { selection, change, recovery }
  observers.add(observer)
  return () => { observers.delete(observer) }
}

export interface ObservationRefreshOptions extends DashboardObservationSelection {
  /** Use false only when another mount effect owns the initial read. */
  readonly initial?: boolean
  readonly onError?: (error: unknown) => void
  /** State-backed resources consume rejection to render it. Expose that
   * failure here without changing their manual-refresh promise contract. */
  readonly readError?: () => unknown | null
  /** Retire an active state-resource read when its own controller owns I/O. */
  readonly cancelRead?: () => void
  /** Withdraw a previous owner's rows, including a cache retained while the
   * surface was unmounted. Called before the first read and on owner change. */
  readonly resetRead?: () => void
  /** Existing source-specific push callbacks can share this read's owner,
   * refusal and coalescing boundary without inventing another wire topic. */
  readonly subscribeChanges?: (invalidate: () => void, recover: () => void) => (() => void)
}

/** Subscribe before the first read. Invalidation during a read retains one
 * trailing read, including after recovery. Successful quiet streams never trigger HTTP.
 * A failed owed read retains one capped-backoff retry until it succeeds.
 * Hidden consumers remember invalidation and read once when visible again. */
export function setupObservationRefresh(
  refresh: (signal: AbortSignal) => void | Promise<unknown>,
  options: ObservationRefreshOptions,
): () => void {
  let active = true
  let scheduled = false
  let owner = captureDashboardObservationOwner()
  let flight: { controller: AbortController; owner: DashboardObservationOwner } | null = null
  let refused = false
  let dirty = false
  let retryTimer: ReturnType<typeof setTimeout> | null = null
  let retryDelayMs = TRANSPORT_RETRY_BASE_MS
  const clearRetry = () => {
    if (retryTimer !== null) clearTimeout(retryTimer)
    retryTimer = null
  }

  const visible = () => typeof document.visibilityState !== 'string'
    || document.visibilityState === 'visible'

  const schedule = () => {
    if (!active || scheduled || flight !== null || refused || retryTimer !== null || !dirty
      || !dashboardObservationOwnerHasWorkspace(owner) || !visible()) return
    scheduled = true
    queueMicrotask(() => { void drain() })
  }

  const invalidate = () => {
    if (!active || refused) return
    dirty = true
    schedule()
  }

  const drain = async () => {
    scheduled = false
    if (!active || flight !== null || refused || !dirty
      || !dashboardObservationOwnerHasWorkspace(owner) || !visible()) return
    dirty = false
    const request = { controller: new AbortController(), owner }
    flight = request
    const current = () => active && flight === request && !request.controller.signal.aborted
      && dashboardObservationOwnerIsCurrent(request.owner)
    try {
      await refresh(request.controller.signal)
      if (current()) {
        const error = options.readError?.()
        if (error !== null && error !== undefined) throw error
        retryDelayMs = TRANSPORT_RETRY_BASE_MS
      }
    } catch (error) {
      if (!current()) return
      if (error instanceof ApiRequestError && (error.status === 401 || error.status === 403)) {
        // A store may own retry debt for this exact error. Its own refusal
        // still blocks this mounted observer's source/focus/recovery reads.
        refused = true
        dirty = false
        clearRetry()
        if (options.onError) options.onError(error)
      } else if (error instanceof ObservationPending || hasReadRecoveryOwner(error)) {
        retryDelayMs = TRANSPORT_RETRY_BASE_MS
        // Retain any invalidation received during the read as one trailing
        // read; otherwise the producer or store-owned recovery completes it.
      } else {
        dirty = true
        retryTimer = setTimeout(() => {
          retryTimer = null
          schedule()
        }, retryDelayMs)
        retryDelayMs = Math.min(retryDelayMs * 2, TRANSPORT_RETRY_MAX_MS)
        if (options.onError) options.onError(error)
        else console.warn('[observation] authoritative read failed', error)
      }
    } finally {
      if (flight === request) {
        flight = null
        schedule()
      }
    }
  }

  const retire = () => {
    const previous = flight
    flight = null
    if (previous !== null) {
      previous.controller.abort()
      options.cancelRead?.()
    }
  }
  const recover = () => {
    if (refused) return
    clearRetry()
    retryDelayMs = TRANSPORT_RETRY_BASE_MS
    retire()
    invalidate()
  }
  const refreshWhenVisible = () => { if (visible()) recover() }
  const unsubscribe = subscribeDashboardObservation(options, invalidate, recover)
  const unsubscribeChanges = options.subscribeChanges?.(invalidate, recover)
  const unsubscribeOwner = subscribeDashboardObservationOwnerChanges(next => {
    owner = next
    clearRetry()
    retryDelayMs = TRANSPORT_RETRY_BASE_MS
    refused = false
    retire()
    options.resetRead?.()
    invalidate()
  })
  window.addEventListener('focus', refreshWhenVisible)
  document.addEventListener('visibilitychange', refreshWhenVisible)
  options.resetRead?.()
  if (options.initial !== false) invalidate()

  return () => {
    active = false
    dirty = false
    clearRetry()
    retire()
    unsubscribe()
    unsubscribeChanges?.()
    unsubscribeOwner()
    window.removeEventListener('focus', refreshWhenVisible)
    document.removeEventListener('visibilitychange', refreshWhenVisible)
  }
}
