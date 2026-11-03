import { subscribeStoredTokenChanges } from './api/core'
import { observeKeeperWaitingChanges } from './api/keeper-waiting-observer'
import { TRANSPORT_RETRY_BASE_MS, TRANSPORT_RETRY_JITTER_MS, TRANSPORT_RETRY_MAX_MS } from './config/constants'
import { ObserverAccessError, ObserverScopeError } from './lib/observer-protocol'
import type { KeeperWaitingInventoryChange } from './sse-store'

type ObserverCallbacks = {
  ready: (instance: string) => void
  change: (change: KeeperWaitingInventoryChange) => void
  unavailable: (reason: 'disconnected' | 'credentials_changed' | 'access_refused' | 'scope_changed') => void
}

/** One connection for the currently mounted waiting-inventory surfaces. */
export function startKeeperWaitingObserver(callbacks: ObserverCallbacks): { stop: () => void; invalidate: () => void } {
  let stopped = false
  let generation = 0
  let active: AbortController | null = null
  let retryTimer: ReturnType<typeof setTimeout> | null = null
  let retryDelay = TRANSPORT_RETRY_BASE_MS
  let invalidateActive: (() => void) | null = null

  const clearRetry = () => {
    if (retryTimer !== null) clearTimeout(retryTimer)
    retryTimer = null
  }
  const launch = () => {
    if (stopped) return
    const ticket = ++generation
    const controller = new AbortController()
    active = controller
    let readyAt: number | null = null
    const current = () => !stopped && ticket === generation && !controller.signal.aborted
    const failed = (cause: unknown) => {
      if (!current()) return
      generation++
      active = null
      invalidateActive = null
      callbacks.unavailable(cause instanceof ObserverAccessError ? 'access_refused'
        : cause instanceof ObserverScopeError ? 'scope_changed' : 'disconnected')
      if (readyAt !== null && performance.now() - readyAt >= TRANSPORT_RETRY_MAX_MS) {
        retryDelay = TRANSPORT_RETRY_BASE_MS
      }
      const delay = retryDelay + Math.random() * TRANSPORT_RETRY_JITTER_MS
      retryDelay = Math.min(TRANSPORT_RETRY_MAX_MS, retryDelay * 2)
      retryTimer = setTimeout(() => {
        retryTimer = null
        launch()
      }, delay)
    }
    invalidateActive = () => {
      if (!current()) return
      failed(new ObserverScopeError())
      controller.abort()
    }
    void observeKeeperWaitingChanges(
      controller.signal,
      instance => {
        if (!current()) return
        readyAt = performance.now()
        callbacks.ready(instance)
      },
      change => {
        if (current() && readyAt !== null) callbacks.change(change)
      },
    ).then(() => failed(null), failed)
  }

  const stopTokenListener = subscribeStoredTokenChanges(() => {
    if (stopped) return
    generation++
    active?.abort()
    active = null
    invalidateActive = null
    clearRetry()
    retryDelay = TRANSPORT_RETRY_BASE_MS
    callbacks.unavailable('credentials_changed')
    launch()
  })
  launch()
  return {
    invalidate: () => invalidateActive?.(),
    stop: () => {
      stopped = true
      generation++
      clearRetry()
      active?.abort()
      active = null
      invalidateActive = null
      stopTokenListener()
    },
  }
}
