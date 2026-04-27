// Relative time display — "2분 전", "3시간 전" 등.
//
// Reference UI pattern (Slack / GitHub / Linear): render as HTML5
// `<time datetime="...">` semantic element (machine-readable, valid
// landmark), title attr for hover tooltip with absolute time, aria-label
// with both relative and absolute so screen readers don't just hear
// "2분 전" without date context. Three render modes let callers pick
// the density they need.

import { html } from 'htm/preact'
import { formatTimeAgo, formatTimestampKo } from '../../lib/format-time'
import { createSharedTicker } from '../../lib/shared-ticker'

type TimeAgoMode = 'relative' | 'absolute' | 'both'

interface TimeAgoProps {
  timestamp: string | number
  /** relative="2분 전" (default) · absolute="04. 17. 18:30" · both="2분 전 · 04. 17. 18:30" */
  mode?: TimeAgoMode
  class?: string
}

const CLOCK_TICK_MS = 30_000
const clockTicker = createSharedTicker(CLOCK_TICK_MS)
const relativeClock = clockTicker.signal

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

/** Pure: the hover-tooltip string for the <time> element. GitHub,
    Linear, Notion — all render a HUMAN-readable timestamp on hover,
    not the machine-readable ISO form. ISO stays on `datetime` attr
    where crawlers / dev tools want it; `title` gets the ko-KR form
    so a mouse user can read \"04. 17. 18:30\" without squinting at
    \"2026-04-18T01:05:33.000Z\". Same shape as toAccessibleLabel —
    relative + absolute together — so hovering confirms whatever
    you'd hear with a screen reader. */
export function toHumanTooltip(ts: string | number): string {
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
  clockTicker.use()

  // Subscribe to the tick so relative text refreshes without parent re-render.
  void relativeClock.value
  const text = pickDisplayText(timestamp, mode)
  const iso = toIsoDatetime(timestamp)
  const label = toAccessibleLabel(timestamp)
  const tooltip = toHumanTooltip(timestamp)
  const cls = cx ? `time-ago ${cx}` : 'time-ago'
  return html`<time class=${cls} datetime=${iso} title=${tooltip} aria-label=${label}>${text}</time>`
}

export { formatTimeAgo }
