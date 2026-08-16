const AUTO_REFRESH_EVENT_DEDUPE_MS = 500

/**
 * Default polling interval for panel-level auto-refresh.
 *
 * Three sibling panels (ide-persistence, keeper-compaction,
 * memory-subsystems) all picked 30s independently. Lifting it here
 * makes the shared cadence visible — and if a panel needs a different
 * interval it can pass its own value to `setupVisibleAutoRefresh`
 * instead of overriding a const by accident.
 */
export const DEFAULT_PANEL_REFRESH_MS = 30_000

export function formatAutoRefreshLabel(intervalMs: number): string {
  const seconds = Math.max(1, Math.round(intervalMs / 1000))
  if (seconds % 60 === 0) {
    return `Auto-refresh ${seconds / 60}m`
  }
  return `Auto-refresh ${seconds}s`
}

type RefreshSource = 'push' | 'event' | 'interval'

/**
 * Sources that can arrive in bursts and therefore need dedupe. The
 * interval cannot burst against itself, so two interval ticks never
 * dedupe each other.
 */
const isBurstSource = (source: RefreshSource | null): boolean =>
  source === 'event' || source === 'push'

export interface VisibleAutoRefreshOptions {
  /**
   * Register a server-push notification for this panel's data. Called
   * once at setup; must return an unsubscribe function.
   *
   * When supplied, the timer becomes a fallback: a tick is skipped if a
   * push already refreshed within the last interval. If push stops, the
   * timer resumes on the next tick, so a dead WS costs at most one
   * interval of staleness rather than freezing the panel.
   */
  subscribeToPush?: (onPush: () => void) => () => void
}

export function setupVisibleAutoRefresh(
  refresh: () => void | Promise<void>,
  intervalMs: number,
  options: VisibleAutoRefreshOptions = {},
): () => void {
  let lastRefreshAt = 0
  let lastRefreshSource: RefreshSource | null = null
  let lastPushAt = 0

  const runRefresh = (source: RefreshSource) => {
    if (typeof document.visibilityState === 'string' && document.visibilityState !== 'visible') return
    const now = Date.now()
    const dedupeRecentRefresh = isBurstSource(source) || isBurstSource(lastRefreshSource)
    if (dedupeRecentRefresh && now - lastRefreshAt < AUTO_REFRESH_EVENT_DEDUPE_MS) return
    lastRefreshAt = now
    lastRefreshSource = source
    if (source === 'push') lastPushAt = now
    void refresh()
  }

  const runIntervalRefresh = () => {
    // A push within the last interval already delivered what this tick
    // would fetch. Without a push feed lastPushAt stays 0 and the timer
    // behaves exactly as before.
    if (lastPushAt !== 0 && Date.now() - lastPushAt < intervalMs) return
    runRefresh('interval')
  }
  const runEventRefresh = () => { runRefresh('event') }
  const runPushRefresh = () => { runRefresh('push') }

  const interval = window.setInterval(runIntervalRefresh, intervalMs)
  window.addEventListener('focus', runEventRefresh)
  document.addEventListener('visibilitychange', runEventRefresh)
  const unsubscribePush = options.subscribeToPush?.(runPushRefresh) ?? null

  return () => {
    window.clearInterval(interval)
    window.removeEventListener('focus', runEventRefresh)
    document.removeEventListener('visibilitychange', runEventRefresh)
    unsubscribePush?.()
  }
}
