const AUTO_REFRESH_EVENT_DEDUPE_MS = 500

export function formatAutoRefreshLabel(intervalMs: number): string {
  const seconds = Math.max(1, Math.round(intervalMs / 1000))
  if (seconds % 60 === 0) {
    return `${seconds / 60}분 자동 갱신`
  }
  return `${seconds}초 자동 갱신`
}

export function setupVisibleAutoRefresh(
  refresh: () => void | Promise<void>,
  intervalMs: number,
): () => void {
  let lastRefreshAt = 0

  const runRefresh = () => {
    if (typeof document.visibilityState === 'string' && document.visibilityState !== 'visible') return
    const now = Date.now()
    if (now - lastRefreshAt < AUTO_REFRESH_EVENT_DEDUPE_MS) return
    lastRefreshAt = now
    void refresh()
  }

  const interval = window.setInterval(runRefresh, intervalMs)
  window.addEventListener('focus', runRefresh)
  document.addEventListener('visibilitychange', runRefresh)

  return () => {
    window.clearInterval(interval)
    window.removeEventListener('focus', runRefresh)
    document.removeEventListener('visibilitychange', runRefresh)
  }
}
