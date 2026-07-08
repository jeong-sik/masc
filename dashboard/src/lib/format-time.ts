// Unified time formatting utilities.

import { UNKNOWN_STATUS_LABEL } from './format-string'

export const SECONDS_PER_MINUTE = 60
export const SECONDS_PER_HOUR = 3600
export const SECONDS_PER_DAY = 86400

const rtf = new Intl.RelativeTimeFormat('ko', { numeric: 'auto' })
const UNIX_MS_THRESHOLD = 1_000_000_000_000

/**
 * Marker string returned when a time-related helper has no input to format.
 *
 * Exposed so call sites that compare against it (e.g. unwrapping the
 * fallback back to `null` in keeper-shared.formatTime) don't have to
 * duplicate the literal — changing the displayed marker here updates
 * every comparison automatically. Tests in `format-time.test.ts`
 * deliberately keep the literal so the assertion documents the
 * user-visible string.
 */
export const NO_TIME_INFO = '정보 없음'

export function formatRelativeSec(deltaSec: number): string {
  if (!Number.isFinite(deltaSec)) return NO_TIME_INFO
  const safeDeltaSec = Math.max(0, deltaSec)
  if (safeDeltaSec < SECONDS_PER_MINUTE) return rtf.format(-safeDeltaSec, 'second')
  if (safeDeltaSec < SECONDS_PER_HOUR) return rtf.format(-Math.round(safeDeltaSec / SECONDS_PER_MINUTE), 'minute')
  if (safeDeltaSec < SECONDS_PER_DAY) return rtf.format(-Math.round(safeDeltaSec / SECONDS_PER_HOUR), 'hour')
  return rtf.format(-Math.round(safeDeltaSec / SECONDS_PER_DAY), 'day')
}

/** Compact age label for dense roster rows — bare magnitude, no relative
 *  marker: "방금", "41분", "2시간", "1일". Matches the v2 mock roster time
 *  column, which drops the "최근 활동 …" label and the "전" suffix that
 *  {@link formatRelativeSec} carries so a long name column is not squeezed. */
export function formatCompactAge(deltaSec: number): string {
  if (!Number.isFinite(deltaSec)) return NO_TIME_INFO
  const s = Math.max(0, Math.round(deltaSec))
  if (s < SECONDS_PER_MINUTE) return '방금'
  if (s < SECONDS_PER_HOUR) return `${Math.round(s / SECONDS_PER_MINUTE)}분`
  if (s < SECONDS_PER_DAY) return `${Math.round(s / SECONDS_PER_HOUR)}시간`
  return `${Math.round(s / SECONDS_PER_DAY)}일`
}

/** Mirror of {@link formatRelativeSec} for a FUTURE instant: a non-negative
 *  "seconds until" delta formatted with a positive sign — "1시간 후", "3분 후". */
export function formatRelativeUntilSec(deltaSec: number): string {
  if (!Number.isFinite(deltaSec)) return NO_TIME_INFO
  const safeDeltaSec = Math.max(0, deltaSec)
  if (safeDeltaSec < SECONDS_PER_MINUTE) return rtf.format(safeDeltaSec, 'second')
  if (safeDeltaSec < SECONDS_PER_HOUR) return rtf.format(Math.round(safeDeltaSec / SECONDS_PER_MINUTE), 'minute')
  if (safeDeltaSec < SECONDS_PER_DAY) return rtf.format(Math.round(safeDeltaSec / SECONDS_PER_HOUR), 'hour')
  return rtf.format(Math.round(safeDeltaSec / SECONDS_PER_DAY), 'day')
}

export function normalizeTimestampMs(ts: number): number {
  return ts < UNIX_MS_THRESHOLD ? ts * 1000 : ts
}

/** Convert unix-seconds timestamp to Date. SSOT for the `new Date(ts * 1000)` pattern. */
export function unixSecondsToDate(ts: number): Date {
  return new Date(ts * 1000)
}

export function formatRelativeAgeMs(ageMs: number): string {
  return formatRelativeSec(Math.max(0, Math.round(ageMs / 1000)))
}

/** Relative time from ISO string — "3분 전", "2시간 전" etc. Uses Intl.RelativeTimeFormat. */
export function relativeTime(iso?: string | null, fallback: string = NO_TIME_INFO): string {
  if (!iso) return fallback
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  return formatRelativeAgeMs(Date.now() - ts)
}

/** Format elapsed seconds — "3초", "5분", "2시간". Returns NO_TIME_INFO for invalid. */
export function formatElapsed(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return NO_TIME_INFO
  if (value < SECONDS_PER_MINUTE) return `${Math.round(value)}초`
  if (value < SECONDS_PER_HOUR) return `${Math.round(value / SECONDS_PER_MINUTE)}분`
  return `${Math.round(value / SECONDS_PER_HOUR)}시간`
}

/** Format duration in seconds as Korean text — includes days. Returns UNKNOWN_STATUS_LABEL for invalid. */
export function formatDuration(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return UNKNOWN_STATUS_LABEL
  if (seconds < SECONDS_PER_MINUTE) return `${Math.round(seconds)}초`
  if (seconds < SECONDS_PER_HOUR) return `${Math.round(seconds / SECONDS_PER_MINUTE)}분`
  if (seconds < SECONDS_PER_DAY) return `${Math.round(seconds / SECONDS_PER_HOUR)}시간`
  return `${Math.round(seconds / SECONDS_PER_DAY)}일`
}

/** Format duration in seconds as Korean text with compound units — "2시간 30분", "1시간 0분".
 *  Returns UNKNOWN_STATUS_LABEL for invalid. */
export function formatDurationCompound(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return UNKNOWN_STATUS_LABEL
  const totalMinutes = Math.floor(seconds / SECONDS_PER_MINUTE)
  const totalHours = Math.floor(totalMinutes / 60)

  if (totalHours >= 1) {
    const remainMinutes = totalMinutes % 60
    return `${totalHours}시간 ${remainMinutes}분`
  }
  if (totalMinutes >= 1) return `${totalMinutes}분`
  return `${Math.round(seconds)}초`
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
  if (seconds < SECONDS_PER_MINUTE) return `${Math.round(seconds)}s`
  if (seconds < SECONDS_PER_HOUR) return `${Math.floor(seconds / SECONDS_PER_MINUTE)}m ${Math.round(seconds % SECONDS_PER_MINUTE)}s`
  return `${Math.floor(seconds / SECONDS_PER_HOUR)}h ${Math.floor((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)}m`
}

/** Format timestamp (string or number) as relative time. Handles unix seconds and ms. */
export function formatTimeAgo(ts: string | number): string {
  const now = Date.now()
  const then =
    typeof ts === 'number'
      ? normalizeTimestampMs(ts)
      : new Date(ts).getTime()
  if (!Number.isFinite(then)) return NO_TIME_INFO
  return formatRelativeSec(Math.max(0, Math.floor((now - then) / 1000)))
}

/** Relative time until a FUTURE timestamp — "1시간 후", "3분 후". Mirror of
 *  {@link formatTimeAgo}; an already-past instant clamps to 0 ("지금"). Use this
 *  (not formatTimeAgo) for future instants — formatTimeAgo floors the future to
 *  0 and renders "지금", which is wrong for a not-yet-elapsed deadline. */
export function formatTimeUntil(ts: string | number): string {
  const now = Date.now()
  const then =
    typeof ts === 'number'
      ? normalizeTimestampMs(ts)
      : new Date(ts).getTime()
  return formatRelativeUntilSec(Math.max(0, Math.floor((then - now) / 1000)))
}

/** Format any date value (ISO string, unix seconds, or null) as Korean localized datetime.
 *  Returns '--' for null/empty, raw value for invalid dates. */
export function formatDateTimeKo(value: string | number | null): string {
  if (value === null || value === '') return '--'
  try {
    const d = typeof value === 'number' ? unixSecondsToDate(value) : new Date(value)
    if (Number.isNaN(d.getTime())) return String(value)
    return d.toLocaleString('ko-KR', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return String(value)
  }
}

/** Format unix timestamp (seconds) as "MM. DD. HH:MM" in ko-KR locale. */
export function formatTimestampKo(ts: number): string {
  return unixSecondsToDate(ts).toLocaleString('ko-KR', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

// ── Time-only formatters (no date) ──

/** Format unix-seconds timestamp as "HH:MM:SS" (24h, ko-KR). */
export function formatTimeHms(tsUnixSec: number): string {
  return unixSecondsToDate(tsUnixSec).toLocaleTimeString('ko-KR', {
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

/** Format ISO timestamp as English relative time — "just now", "5m ago", "2h ago". */
export function formatTimeAgoEn(iso: string): string {
  if (!iso.trim()) return 'unknown'
  if (iso === 'never') return 'never'
  const diff = (Date.now() - new Date(iso).getTime()) / 1000
  if (Number.isNaN(diff)) return 'unknown'
  if (diff < SECONDS_PER_MINUTE) return 'just now'
  if (diff < SECONDS_PER_HOUR) return `${Math.floor(diff / SECONDS_PER_MINUTE)}m ago`
  if (diff < SECONDS_PER_DAY) return `${Math.floor(diff / SECONDS_PER_HOUR)}h ago`
  return `${Math.floor(diff / SECONDS_PER_DAY)}d ago`
}

/** Format millisecond timestamp as ISO string. Returns undefined for invalid. */
export function formatDateTimeIso(ts: number): string | undefined {
  if (!Number.isFinite(ts)) return undefined
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return undefined
  return d.toISOString()
}

/** Format ms timestamp as "HH:MM:SS". Returns fallback for invalid. */
export function formatTimeHmsMs(tsMs: number, fallback = '--:--:--'): string {
  if (!Number.isFinite(tsMs)) return fallback
  const d = new Date(tsMs)
  if (!Number.isFinite(d.getTime())) return fallback
  return d.toLocaleTimeString('ko-KR', {
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

/** Format ms timestamp as "HH:MM". Returns fallback for invalid. */
export function formatTimeHmMs(tsMs: number, fallback = '--:--'): string {
  if (!Number.isFinite(tsMs)) return fallback
  const d = new Date(tsMs)
  if (!Number.isFinite(d.getTime())) return fallback
  return d.toLocaleTimeString('ko-KR', {
    hour: '2-digit', minute: '2-digit',
  })
}

/** Format a numeric delta with sign prefix. */
export function formatDelta(delta: number, decimals = 4): string {
  const sign = delta >= 0 ? '+' : ''
  return `${sign}${delta.toFixed(decimals)}`
}

/**
 * Coerce a Unix timestamp into milliseconds, accepting either seconds or
 * milliseconds depending on magnitude.
 *
 * Backend producers emit timestamps in both units — anchored threads and
 * activity events use milliseconds, runtime hops and decision logs use
 * seconds. Any value larger than `1e12` is treated as already-millis;
 * anything smaller is multiplied by 1000. `null` / `NaN` / non-finite
 * inputs return `NaN` so callers can branch on `Number.isFinite` once.
 *
 * Three IDE trace bridges (`decision-log-trace-bridge`,
 * `runtime-hop-trace-bridge`, `ide-conversation-rail`) shipped this
 * exact body file-internal before centralising here.
 */
export function unixishToMs(ts: number | null | undefined): number {
  if (ts === null || ts === undefined || !Number.isFinite(ts)) return Number.NaN
  return ts > 1_000_000_000_000 ? ts : ts * 1000
}
