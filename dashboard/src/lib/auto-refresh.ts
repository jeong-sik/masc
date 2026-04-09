export function setupVisibleAutoRefresh(
  refresh: () => void | Promise<void>,
  intervalMs: number,
): () => void {
  const runRefresh = () => {
    if (typeof document.visibilityState === 'string' && document.visibilityState !== 'visible') return
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
