import { currentStoredTokenRevision, subscribeStoredTokenChanges } from './api/core'
import { signal } from '@preact/signals'
import type { DashboardKeeperWaitingInventory } from './api'
import { fetchKeeperWaitingInventory } from './api'
import { dashboardWsReconnectCount } from './dashboard-ws-state'
import { registerKeeperWaitingInventoryRefresh } from './sse-store'

export type KeeperWaitingInventoryState = {
  readonly inventory: DashboardKeeperWaitingInventory | null
  readonly ready: boolean
  readonly loading: boolean
  readonly error: string | null
}

const EMPTY_STATE: KeeperWaitingInventoryState = {
  inventory: null,
  ready: false,
  loading: false,
  error: null,
}

export const keeperWaitingInventoryStates = signal<
  Record<string, KeeperWaitingInventoryState>
>({})

const subscriberCounts = new Map<string, number>()
type InventoryReadOwner = { readonly token: object; readonly promise: Promise<void> } & (
  | { readonly kind: 'preparing'; readonly authRevision: number }
  | { readonly kind: 'admitted'; readonly authRevision: number }
)
const inFlight = new Map<string, InventoryReadOwner>()
const pendingInvalidations = new Set<string>()
let stopPushRefresh: (() => void) | null = null
let stopReconnectRefresh: (() => void) | null = null
let lastReconnectCount = dashboardWsReconnectCount.value

function stateFor(keeperName: string): KeeperWaitingInventoryState {
  return keeperWaitingInventoryStates.value[keeperName] ?? EMPTY_STATE
}

function setState(keeperName: string, state: KeeperWaitingInventoryState): void {
  keeperWaitingInventoryStates.value = {
    ...keeperWaitingInventoryStates.value,
    [keeperName]: state,
  }
}

export function keeperWaitingInventoryState(
  keeperName: string,
): KeeperWaitingInventoryState {
  return stateFor(keeperName)
}

/** One keeper-scoped authoritative read. Concurrent consumers share the same
 * request; the last good projection remains visible while it refreshes. */
export function refreshKeeperWaitingInventory(keeperName: string): Promise<void> {
  const authRevision = currentStoredTokenRevision()
  const existing = inFlight.get(keeperName)
  if (existing && (existing.kind === 'preparing' || existing.authRevision === authRevision)) return existing.promise
  const token = {}
  const ownsRead = () => {
    const owner = inFlight.get(keeperName)
    return owner?.token === token && owner.authRevision === currentStoredTokenRevision()
  }

  const previous = stateFor(keeperName)
  setState(keeperName, { ...previous, loading: true, error: null })
  const request = Promise.resolve().then(() => fetchKeeperWaitingInventory(keeperName, {
    onAdmission: admission => {
      const owner = inFlight.get(keeperName)
      if (owner?.token !== token || admission.authRevision !== currentStoredTokenRevision()) return
      inFlight.set(keeperName, { ...owner, kind: 'admitted', authRevision: admission.authRevision })
    },
  }))
    .then(inventory => {
      if (!ownsRead()) return
      setState(keeperName, {
        inventory,
        ready: true,
        loading: false,
        error: null,
      })
    })
    .catch((cause: unknown) => {
      if (!ownsRead()) return
      const current = stateFor(keeperName)
      setState(keeperName, {
        ...current,
        loading: false,
        error: cause instanceof Error ? cause.message : String(cause),
      })
    })
    .finally(() => {
      if (inFlight.get(keeperName)?.token !== token) return
      inFlight.delete(keeperName)
      if (
        pendingInvalidations.delete(keeperName)
        && (subscriberCounts.get(keeperName) ?? 0) > 0
      ) {
        void refreshKeeperWaitingInventory(keeperName)
      }
    })
  inFlight.set(keeperName, { kind: 'preparing', authRevision, token, promise: request })
  return request
}

/** Preserve one trailing authoritative read when an invalidation arrives
 * during an in-flight read. This prevents burst coalescing from losing the
 * final queue state. */
function invalidateKeeperWaitingInventory(keeperName: string): void {
  if (inFlight.has(keeperName)) {
    pendingInvalidations.add(keeperName)
    return
  }
  void refreshKeeperWaitingInventory(keeperName)
}

function refreshActiveKeepers(): void {
  if (document.visibilityState !== 'visible') return
  for (const [keeperName, count] of subscriberCounts) {
    if (count > 0) invalidateKeeperWaitingInventory(keeperName)
  }
}

function startRecoveryListeners(): void {
  if (stopPushRefresh) return
  stopPushRefresh = registerKeeperWaitingInventoryRefresh(keeperName => {
    if ((subscriberCounts.get(keeperName) ?? 0) > 0) {
      invalidateKeeperWaitingInventory(keeperName)
    }
  })
  stopReconnectRefresh = dashboardWsReconnectCount.subscribe(count => {
    if (count !== lastReconnectCount) {
      lastReconnectCount = count
      refreshActiveKeepers()
    }
  })
  window.addEventListener('focus', refreshActiveKeepers)
  document.addEventListener('visibilitychange', refreshActiveKeepers)
}

function stopRecoveryListeners(): void {
  stopPushRefresh?.()
  stopPushRefresh = null
  stopReconnectRefresh?.()
  stopReconnectRefresh = null
  window.removeEventListener('focus', refreshActiveKeepers)
  document.removeEventListener('visibilitychange', refreshActiveKeepers)
}

/** Subscribe a mounted Keeper surface to push invalidations and event-based
 * recovery. There is deliberately no periodic timer. */
export function subscribeKeeperWaitingInventory(keeperName: string): () => void {
  const previous = subscriberCounts.get(keeperName) ?? 0
  subscriberCounts.set(keeperName, previous + 1)
  if (subscriberCounts.size === 1 && previous === 0) startRecoveryListeners()
  void refreshKeeperWaitingInventory(keeperName)

  return () => {
    const next = Math.max(0, (subscriberCounts.get(keeperName) ?? 0) - 1)
    if (next === 0) subscriberCounts.delete(keeperName)
    else subscriberCounts.set(keeperName, next)
    if (subscriberCounts.size === 0) stopRecoveryListeners()
  }
}

// Credential changes revoke cached and pending observations before admitting
// replacement reads for mounted surfaces. Old promises retain no publication owner.
subscribeStoredTokenChanges(() => {
  for (const [keeperName, owner] of inFlight) {
    if (owner.kind === 'admitted') inFlight.delete(keeperName)
  }
  pendingInvalidations.clear()
  keeperWaitingInventoryStates.value = {}
  for (const [keeperName, count] of subscriberCounts) {
    if (count > 0) {
      if (inFlight.get(keeperName)?.kind === 'preparing') setState(keeperName, { ...EMPTY_STATE, loading: true })
      else void refreshKeeperWaitingInventory(keeperName)
    }
  }
})
