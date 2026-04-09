// Unified time formatting utilities.

const rtf = new Intl.RelativeTimeFormat('ko', { numeric: 'auto' })

function formatRelativeSec(deltaSec: number): string {
  if (deltaSec < 60) return rtf.format(-deltaSec, 'second')
  if (deltaSec < 3600) return rtf.format(-Math.round(deltaSec / 60), 'minute')
  if (deltaSec < 86400) return rtf.format(-Math.round(deltaSec / 3600), 'hour')
  return rtf.format(-Math.round(deltaSec / 86400), 'day')
}

/** Relative time from ISO string — "3분 전", "2시간 전" etc. Uses Intl.RelativeTimeFormat. */
export function relativeTime(iso?: string | null, fallback = '정보 없음'): string {
  if (!iso) return fallback
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  return formatRelativeSec(Math.max(0, Math.round((Date.now() - ts) / 1000)))
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
  return formatRelativeSec(Math.max(0, Math.floor((now - then) / 1000)))
}

/** Format unix timestamp (seconds) as "MM. DD. HH:MM" in ko-KR locale. */
export function formatTimestampKo(ts: number): string {
  return new Date(ts * 1000).toLocaleString('ko-KR', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

// ── Time-only formatters (no date) ──

const timeHhMm = new Intl.DateTimeFormat('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })

/** Format millisecond timestamp as "HH:MM" (24h, ko-KR). */
export function formatTimeOnly(tsMs: number): string {
  return timeHhMm.format(new Date(tsMs))
}

/** Format unix-seconds timestamp as "HH:MM:SS" (24h, ko-KR). */
export function formatTimeHms(tsUnixSec: number): string {
  return new Date(tsUnixSec * 1000).toLocaleTimeString('ko-KR', {
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

/** Format ISO timestamp as English relative time — "just now", "5m ago", "2h ago". */
export function formatTimeAgoEn(iso: string): string {
  if (!iso.trim()) return 'unknown'
  if (iso === 'never') return 'never'
  const diff = (Date.now() - new Date(iso).getTime()) / 1000
  if (Number.isNaN(diff)) return 'unknown'
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

/** Format a numeric delta with sign prefix. */
export function formatDelta(delta: number, decimals = 4): string {
  const sign = delta >= 0 ? '+' : ''
  return `${sign}${delta.toFixed(decimals)}`
}
