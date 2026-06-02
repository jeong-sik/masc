const AUTO_REFRESH_EVENT_DEDUPE_MS = 500

/**
 * Default polling interval for panel-level auto-refresh.
 *
 * Three sibling panels (ide-persistence, keeper-memory-tier,
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

export function setupVisibleAutoRefresh(
  refresh: () => void | Promise<void>,
  intervalMs: number,
): () => void {
  let lastRefreshAt = 0
  let lastRefreshSource: 'event' | 'interval' | null = null

  const runRefresh = (source: 'event' | 'interval') => {
    if (typeof document.visibilityState === 'string' && document.visibilityState !== 'visible') return
    const now = Date.now()
    const dedupeRecentRefresh = source === 'event' || lastRefreshSource === 'event'
    if (dedupeRecentRefresh && now - lastRefreshAt < AUTO_REFRESH_EVENT_DEDUPE_MS) return
    lastRefreshAt = now
    lastRefreshSource = source
    void refresh()
  }

  const runIntervalRefresh = () => { runRefresh('interval') }
  const runEventRefresh = () => { runRefresh('event') }

  const interval = window.setInterval(runIntervalRefresh, intervalMs)
  window.addEventListener('focus', runEventRefresh)
  document.addEventListener('visibilitychange', runEventRefresh)

  return () => {
    window.clearInterval(interval)
    window.removeEventListener('focus', runEventRefresh)
    document.removeEventListener('visibilitychange', runEventRefresh)
  }
}
