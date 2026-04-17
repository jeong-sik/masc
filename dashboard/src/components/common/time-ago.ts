// Relative time display — "2분 전", "3시간 전" 등.
//
// Reference UI pattern (Slack / GitHub / Linear): render as HTML5
// `<time datetime="...">` semantic element (machine-readable, valid
// landmark), title attr for hover tooltip with absolute time, aria-label
// with both relative and absolute so screen readers don't just hear
// "2분 전" without date context. Three render modes let callers pick
// the density they need.

import { signal } from '@preact/signals'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { formatTimeAgo, formatTimestampKo } from '../../lib/format-time'

type TimeAgoMode = 'relative' | 'absolute' | 'both'

interface TimeAgoProps {
  timestamp: string | number
  /** relative="2분 전" (default) · absolute="04. 17. 18:30" · both="2분 전 · 04. 17. 18:30" */
  mode?: TimeAgoMode
  class?: string
}

const CLOCK_TICK_MS = 30_000
const relativeClock = signal(Date.now())
let relativeClockTimer: number | null = null
let relativeClockSubscribers = 0

function startRelativeClock(): void {
  if (relativeClockTimer != null || typeof window === 'undefined') return
  relativeClockTimer = window.setInterval(() => {
    relativeClock.value = Date.now()
  }, CLOCK_TICK_MS)
}

function stopRelativeClock(): void {
  if (relativeClockTimer == null || typeof window === 'undefined') return
  window.clearInterval(relativeClockTimer)
  relativeClockTimer = null
}

/** Normalize a timestamp (ISO string, unix seconds, or unix ms) to ms.
    Exposed for unit tests so the normalization rule is verifiable. */
export function toMs(ts: string | number): number {
  if (typeof ts === 'string') return new Date(ts).getTime()
  return ts < 1_000_000_000_000 ? ts * 1000 : ts
}

/** ISO 8601 string for the `<time datetime="...">` attribute. Machine-readable
    timestamp that dev tools and crawlers can parse without re-running our
    format logic. */
export function toIsoDatetime(ts: string | number): string {
  return new Date(toMs(ts)).toISOString()
}

/** Unix-seconds form for `formatTimestampKo`, which expects seconds. */
function toUnixSeconds(ts: string | number): number {
  return Math.floor(toMs(ts) / 1000)
}

/** Accessible label for screen readers: combines relative "2분 전" with
    the absolute ko-KR formatted date. Without this, an AT user hears only
    "2분 전" and loses the anchor point. */
export function toAccessibleLabel(ts: string | number): string {
  return `${formatTimeAgo(ts)} (${formatTimestampKo(toUnixSeconds(ts))})`
}

/** Pick the displayed text based on mode. */
export function pickDisplayText(ts: string | number, mode: TimeAgoMode): string {
  const rel = formatTimeAgo(ts)
  if (mode === 'relative') return rel
  const abs = formatTimestampKo(toUnixSeconds(ts))
  if (mode === 'absolute') return abs
  return `${rel} · ${abs}`
}

export function TimeAgo({ timestamp, mode = 'relative', class: cx }: TimeAgoProps) {
  useEffect(() => {
    relativeClockSubscribers += 1
    startRelativeClock()
    return () => {
      relativeClockSubscribers = Math.max(0, relativeClockSubscribers - 1)
      if (relativeClockSubscribers === 0) stopRelativeClock()
    }
  }, [])

  // Subscribe to the tick so relative text refreshes without parent re-render.
  void relativeClock.value
  const text = pickDisplayText(timestamp, mode)
  const iso = toIsoDatetime(timestamp)
  const label = toAccessibleLabel(timestamp)
  const cls = cx ? `time-ago ${cx}` : 'time-ago'
  return html`<time class=${cls} datetime=${iso} title=${iso} aria-label=${label}>${text}</time>`
}

export { formatTimeAgo }
