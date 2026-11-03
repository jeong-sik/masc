import { signal } from '@preact/signals'
import type { DashboardKeeperWaitingInventory } from './api'
import { fetchKeeperWaitingInventory } from './api'
import { ApiRequestError } from './api/core'
import { ObserverScopeError } from './lib/observer-protocol'
import { startKeeperWaitingObserver } from './keeper-waiting-observer-client'

export type KeeperWaitingInventoryState = {
  readonly inventory: DashboardKeeperWaitingInventory | null
  readonly ready: boolean
  readonly loading: boolean
  readonly error: string | null
  /** The snapshot was read on the current observer after its last change. */
  readonly observerCurrent: boolean
}

const EMPTY_STATE: KeeperWaitingInventoryState = {
  inventory: null,
  ready: false,
  loading: false,
  error: null,
  observerCurrent: false,
}

export const keeperWaitingInventoryStates = signal<
  Record<string, KeeperWaitingInventoryState>
>({})

const subscriberCounts = new Map<string, number>()
const inFlight = new Map<string, Promise<void>>()
const pendingInvalidations = new Set<string>()
let observer: ReturnType<typeof startKeeperWaitingObserver> | null = null
let observerInstance: string | null = null
let retainedObserverInstance: string | null = null
let observerGeneration = 0

function stateFor(keeperName: string): KeeperWaitingInventoryState {
  return keeperWaitingInventoryStates.value[keeperName] ?? EMPTY_STATE
}

function setState(keeperName: string, state: KeeperWaitingInventoryState): void {
  keeperWaitingInventoryStates.value = {
    ...keeperWaitingInventoryStates.value,
    [keeperName]: state,
  }
}

function withdrawRetainedInventories(): void {
  keeperWaitingInventoryStates.value = Object.fromEntries(
    Object.entries(keeperWaitingInventoryStates.value).map(([name, previous]) => [
      name, { ...previous, inventory: null, ready: false, error: null, observerCurrent: false },
    ]),
  )
}

export function keeperWaitingInventoryState(
  keeperName: string,
): KeeperWaitingInventoryState {
  return stateFor(keeperName)
}

/** One keeper-scoped authoritative read. Concurrent consumers share the same
 * request; the last good projection remains visible while it refreshes. */
export function refreshKeeperWaitingInventory(keeperName: string): Promise<void> {
  const existing = inFlight.get(keeperName)
  if (existing) return existing
  const instance = observerInstance
  if (!instance) {
    const previous = stateFor(keeperName)
    setState(keeperName, { ...previous, observerCurrent: false, error: '실시간 대기 상태 연결을 확인할 수 없습니다.' })
    return Promise.resolve()
  }
  const generation = observerGeneration

  const previous = stateFor(keeperName)
  setState(keeperName, { ...previous, loading: true, error: null, observerCurrent: false })
  const request = fetchKeeperWaitingInventory(keeperName, instance)
    .then(inventory => {
      if (observerInstance !== instance || observerGeneration !== generation) {
        const current = stateFor(keeperName)
        setState(keeperName, { ...current, loading: false, observerCurrent: false })
        return
      }
      setState(keeperName, {
        inventory,
        ready: true,
        loading: false,
        error: null,
        observerCurrent: observerInstance === instance
          && observerGeneration === generation
          && !pendingInvalidations.has(keeperName)
          && (subscriberCounts.get(keeperName) ?? 0) > 0,
      })
    })
    .catch((cause: unknown) => {
      const current = stateFor(keeperName)
      if (observerInstance !== instance || observerGeneration !== generation) {
        setState(keeperName, { ...current, loading: false, observerCurrent: false })
        return
      }
      if (cause instanceof ObserverScopeError || (cause instanceof ApiRequestError
          && cause.status === 409 && cause.errorCode === 'observer_instance_changed')) {
        setState(keeperName, { ...current, loading: false, observerCurrent: false })
        observer?.invalidate()
        return
      }
      const refused = cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403)
      setState(keeperName, {
        ...current,
        ...(refused ? { inventory: null, ready: false } : {}),
        loading: false,
        error: cause instanceof Error ? cause.message : String(cause),
        observerCurrent: false,
      })
    })
    .finally(() => {
      if (inFlight.get(keeperName) !== request) return
      inFlight.delete(keeperName)
      if (
        pendingInvalidations.delete(keeperName)
        && (subscriberCounts.get(keeperName) ?? 0) > 0
      ) {
        void refreshKeeperWaitingInventory(keeperName)
      }
    })
  inFlight.set(keeperName, request)
  return request
}

/** Preserve one trailing authoritative read when an invalidation arrives
 * during an in-flight read. This prevents burst coalescing from losing the
 * final queue state. */
function invalidateKeeperWaitingInventory(keeperName: string): void {
  const previous = stateFor(keeperName)
  if (previous.observerCurrent) setState(keeperName, { ...previous, observerCurrent: false })
  if (inFlight.has(keeperName)) {
    pendingInvalidations.add(keeperName)
    return
  }
  void refreshKeeperWaitingInventory(keeperName)
}

function invalidateSubscribedKeepers(): void {
  for (const [keeperName, count] of subscriberCounts) {
    if (count > 0) invalidateKeeperWaitingInventory(keeperName)
  }
}

function refreshActiveKeepers(): void {
  if (document.visibilityState === 'visible') invalidateSubscribedKeepers()
}

function startRecoveryListeners(): void {
  if (observer) return
  observer = startKeeperWaitingObserver({
    ready: instance => {
      if (retainedObserverInstance !== null && retainedObserverInstance !== instance) {
        withdrawRetainedInventories()
      }
      retainedObserverInstance = instance
      observerInstance = instance
      observerGeneration++
      invalidateSubscribedKeepers()
    },
    change: change => {
      if (change.scope === 'workspace') {
        invalidateSubscribedKeepers()
      } else if ((subscriberCounts.get(change.keeperName) ?? 0) > 0) {
        invalidateKeeperWaitingInventory(change.keeperName)
      }
    },
    unavailable: reason => {
      observerInstance = null
      observerGeneration++
      if (reason === 'credentials_changed' || reason === 'access_refused' || reason === 'scope_changed') {
        retainedObserverInstance = null
        withdrawRetainedInventories()
      }
      for (const [keeperName] of subscriberCounts) {
        const previous = stateFor(keeperName)
        setState(keeperName, { ...previous, observerCurrent: false, error: '실시간 대기 상태 연결이 끊겼습니다.' })
      }
    },
  })
  window.addEventListener('focus', refreshActiveKeepers)
  document.addEventListener('visibilitychange', refreshActiveKeepers)
}

function stopRecoveryListeners(): void {
  observer?.stop()
  observer = null
  observerInstance = null
  retainedObserverInstance = null
  observerGeneration++
  withdrawRetainedInventories()
  window.removeEventListener('focus', refreshActiveKeepers)
  document.removeEventListener('visibilitychange', refreshActiveKeepers)
}

/** Subscribe a mounted Keeper surface to push invalidations and event-based
 * recovery. There is deliberately no periodic timer. */
export function subscribeKeeperWaitingInventory(keeperName: string): () => void {
  const previous = subscriberCounts.get(keeperName) ?? 0
  subscriberCounts.set(keeperName, previous + 1)
  if (subscriberCounts.size === 1 && previous === 0) startRecoveryListeners()
  if (observerInstance) void refreshKeeperWaitingInventory(keeperName)

  return () => {
    const next = Math.max(0, (subscriberCounts.get(keeperName) ?? 0) - 1)
    if (next === 0) {
      subscriberCounts.delete(keeperName)
      const previous = stateFor(keeperName)
      if (previous.observerCurrent) setState(keeperName, { ...previous, observerCurrent: false })
    } else subscriberCounts.set(keeperName, next)
    if (subscriberCounts.size === 0) stopRecoveryListeners()
  }
}
