// Unified time formatting utilities.

/** Relative time from ISO string — "3분 전", "2시간 전" etc. */
export function relativeTime(iso?: string | null, fallback = '정보 없음'): string {
  if (!iso) return fallback
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}초 전`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}분 전`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}시간 전`
  return `${Math.round(deltaSec / 86400)}일 전`
}

/** Format elapsed seconds — "3초", "5분", "2시간". Returns '정보 없음' for invalid. */
export function formatElapsed(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '정보 없음'
  if (value < 60) return `${Math.round(value)}초`
  if (value < 3600) return `${Math.round(value / 60)}분`
  return `${Math.round(value / 3600)}시간`
}

/** Format duration in seconds as Korean text — includes days. Returns '확인 필요' for invalid. */
export function formatDuration(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return '확인 필요'
  if (seconds < 60) return `${Math.round(seconds)}초`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분`
  if (seconds < 86400) return `${Math.round(seconds / 3600)}시간`
  return `${Math.round(seconds / 86400)}일`
}

/** Format duration in milliseconds as Korean text — "5분", "2시간 30분", "1일 3시간". */
export function formatDurationMs(ms: number): string {
  if (ms < 0) ms = 0
  const totalMinutes = Math.floor(ms / 60_000)
  const totalHours = Math.floor(totalMinutes / 60)
  const totalDays = Math.floor(totalHours / 24)

  if (totalDays >= 1) {
    const remainHours = totalHours % 24
    return remainHours > 0 ? `${totalDays}일 ${remainHours}시간` : `${totalDays}일`
  }
  if (totalHours >= 1) {
    const remainMinutes = totalMinutes % 60
    return remainMinutes > 0 ? `${totalHours}시간 ${remainMinutes}분` : `${totalHours}시간`
  }
  return `${totalMinutes}분`
}

/** Format elapsed seconds in compact English — "3s", "5m", "2h 30m". */
export function formatElapsedCompact(seconds?: number | null): string {
  if (seconds == null) return ''
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`
}

/** Format timestamp (string or number) as relative time. Handles unix seconds and ms. */
export function formatTimeAgo(ts: string | number): string {
  const now = Date.now()
  const then =
    typeof ts === 'number'
      ? (ts < 1_000_000_000_000 ? ts * 1000 : ts)
      : new Date(ts).getTime()
  const diffSec = Math.floor((now - then) / 1000)
  if (diffSec < 60) return `${diffSec}초 전`
  const diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return `${diffMin}분 전`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}시간 전`
  const diffDay = Math.floor(diffHr / 24)
  return `${diffDay}일 전`
}
