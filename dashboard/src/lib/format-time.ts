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

const MS_PER_DAY = SECONDS_PER_DAY * 1000
const RECENT_SECONDS = 45
const CALENDAR_DAY_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/
const PARSED_ISO_CACHE_MAX = 512
const parsedIsoMsCache = new Map<string, number>()

/** What a relative label is made from. */
type RelativeTimeInput =
  | { readonly kind: 'instant'; readonly ms: number }
  | { readonly kind: 'day'; readonly localMidnightMs: number }
  | { readonly kind: 'unreadable'; readonly raw: string }

function parseIsoMs(raw: string): number {
  const cached = parsedIsoMsCache.get(raw)
  if (cached !== undefined) return cached
  const parsed = Date.parse(raw)
  if (parsedIsoMsCache.size >= PARSED_ISO_CACHE_MAX) parsedIsoMsCache.clear()
  parsedIsoMsCache.set(raw, parsed)
  return parsed
}

/** Local midnight of `YYYY-MM-DD`, or null when it names no real day (`2026-02-30`). */
function localMidnightOfCalendarDay(raw: string): number | null {
  const match = CALENDAR_DAY_PATTERN.exec(raw)
  if (match === null) return null
  const year = Number(match[1])
  const monthIndex = Number(match[2]) - 1
  const day = Number(match[3])
  const date = new Date(year, monthIndex, day)
  const real = date.getFullYear() === year && date.getMonth() === monthIndex && date.getDate() === day
  return real ? date.getTime() : null
}

function readRelativeTimeInput(tsInput: number | string): RelativeTimeInput | null {
  if (typeof tsInput === 'number') {
    if (!Number.isFinite(tsInput)) return null
    return { kind: 'instant', ms: normalizeTimestampMs(tsInput) }
  }
  if (CALENDAR_DAY_PATTERN.test(tsInput)) {
    const localMidnightMs = localMidnightOfCalendarDay(tsInput)
    return localMidnightMs === null
      ? { kind: 'unreadable', raw: tsInput }
      : { kind: 'day', localMidnightMs }
  }
  const ms = parseIsoMs(tsInput)
  return Number.isNaN(ms) ? { kind: 'unreadable', raw: tsInput } : { kind: 'instant', ms }
}

/** What a time ahead of now reads as. An event (a write, a post, a vote)
 *  cannot lie ahead, so one that does only shows the two clocks disagree and
 *  reads as now. A schedule's next run can lie ahead. */
type AheadOfNow = 'reads_as_now' | 'reads_as_ahead'

function formatInstantFromNow(diffSec: number, ahead: AheadOfNow): string {
  if (diffSec < 0) {
    switch (ahead) {
      case 'reads_as_now':
        return '방금 전'
      case 'reads_as_ahead': {
        const aheadSec = -diffSec
        if (aheadSec < SECONDS_PER_MINUTE) return `${aheadSec}초 후`
        if (aheadSec < SECONDS_PER_HOUR) return `${Math.floor(aheadSec / SECONDS_PER_MINUTE)}분 후`
        if (aheadSec < SECONDS_PER_DAY) return `${Math.floor(aheadSec / SECONDS_PER_HOUR)}시간 후`
        return `${Math.floor(aheadSec / SECONDS_PER_DAY)}일 후`
      }
    }
  }
  if (diffSec < RECENT_SECONDS) return '방금 전'
  if (diffSec < SECONDS_PER_HOUR) return `${Math.floor(diffSec / SECONDS_PER_MINUTE)}분 전`
  if (diffSec < SECONDS_PER_DAY) return `${Math.floor(diffSec / SECONDS_PER_HOUR)}시간 전`
  return `${Math.floor(diffSec / SECONDS_PER_DAY)}일 전`
}

function formatDayFromToday(daysAgo: number, ahead: AheadOfNow): string {
  if (daysAgo < 0) {
    switch (ahead) {
      case 'reads_as_now':
        return '오늘'
      case 'reads_as_ahead':
        return daysAgo === -1 ? '내일' : `${-daysAgo}일 후`
    }
  }
  if (daysAgo === 0) return '오늘'
  if (daysAgo === 1) return '어제'
  return `${daysAgo}일 전`
}

function formatRelative(tsInput: number | string | null | undefined, nowMs: number, ahead: AheadOfNow): string {
  if (tsInput === null || tsInput === undefined || tsInput === '') return '없음'
  const input = readRelativeTimeInput(tsInput)
  if (input === null) return '없음'
  switch (input.kind) {
    case 'unreadable':
      return input.raw
    case 'instant':
      return formatInstantFromNow(Math.round((nowMs - input.ms) / 1000), ahead)
    case 'day': {
      const today = new Date(nowMs)
      today.setHours(0, 0, 0, 0)
      return formatDayFromToday(Math.round((today.getTime() - input.localMidnightMs) / MS_PER_DAY), ahead)
    }
  }
}

/**
 * How long ago an event happened, from unix seconds or milliseconds, an ISO
 * instant, or a calendar day: "방금 전", "3분 전", "어제", "4일 전". A calendar
 * day (`2026-11-28`) has no time of day, so it reads in whole days. A time
 * ahead of now reads as now. Returns "없음" without input and the text itself
 * when it is no time.
 */
export function formatRelativeTime(tsInput: number | string | null | undefined, nowMs = Date.now()): string {
  return formatRelative(tsInput, nowMs, 'reads_as_now')
}

/** {@link formatRelativeTime} for a time that can lie ahead, such as a
 *  schedule's next run: "3분 후", "내일", and "2분 전" once it has passed. */
export function formatScheduledTime(tsInput: number | string | null | undefined, nowMs = Date.now()): string {
  return formatRelative(tsInput, nowMs, 'reads_as_ahead')
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
