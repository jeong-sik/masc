// HeartbeatUptimeChip — rolling uptime % as a small threshold-toned badge.
//
// Reference UIs (Uptime Kuma status page "Overall uptime 99.87%" card,
// Statuspage "Uptime last 90 days" ring): reliability-at-a-glance is a
// distinct operator question from the current-state streak. "UP × 22" +
// "100%" together answer both "is it up right now?" and "has it been
// reliable over the window?" in one row.
//
// The strip tooltip already exposes the same number, but only on hover —
// this chip surfaces it so a flaky connector reads as "85%" in peripheral
// vision, not as "looks fine, probably".

import { html } from 'htm/preact'
import type { HeartbeatState } from '../../lib/heartbeat-history'
import { summarizeHistory, type HeartbeatSummary } from './heartbeat-strip'

type UptimeTone = 'operational' | 'degraded' | 'unhealthy'

interface UptimeChipView {
  /** Integer percent (0-100) as a string — 99.87 → "99.87", 100 → "100". */
  label: string
  tone: UptimeTone
}

/** Pure: classify a heartbeat summary into a chip view. Returns null
    when there are no observed (up+down) samples so the tile renders
    nothing instead of a meaningless "N/A%". Thresholds match Uptime
    Kuma's default "operational / degraded / down" color ramp — two
    nines (≥99) is quiet green, 95-99 is warning amber, below 95 is
    alarming rose. */
export function formatUptimeChip(summary: HeartbeatSummary): UptimeChipView | null {
  if (summary.uptimePct === null) return null
  const pct = summary.uptimePct
  const label = pct >= 99.995 ? '100' : pct.toFixed(pct >= 99 ? 2 : 1)
  const tone: UptimeTone =
    pct >= 99 ? 'operational' : pct >= 95 ? 'degraded' : 'unhealthy'
  return { label, tone }
}

const TONE_CLASS: Record<UptimeTone, string> = {
  operational: 'text-[var(--ok)] border-emerald-400/30 bg-emerald-500/10',
  degraded: 'text-[var(--warn)] border-amber-400/30 bg-amber-500/10',
  unhealthy: 'text-[var(--bad-light)] border-rose-400/30 bg-rose-500/10',
}

interface HeartbeatUptimeChipProps {
  history: HeartbeatState[]
  class?: string
  testId?: string
}

export function HeartbeatUptimeChip({
  history,
  class: cx,
  testId,
}: HeartbeatUptimeChipProps) {
  const summary = summarizeHistory(history)
  const view = formatUptimeChip(summary)
  if (view === null) return null
  const tone = TONE_CLASS[view.tone]
  const title = `${view.label}% uptime · ${summary.up}/${summary.up + summary.down} observed`
  const chipClass = cx ?? ''
  return html`<span
    class=${`inline-flex items-center gap-0.5 rounded-full border px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] tabular-nums ${tone} ${chipClass}`}
    title=${title}
    aria-label=${title}
    data-heartbeat-uptime-chip
    data-heartbeat-uptime-tone=${view.tone}
    data-heartbeat-uptime-pct=${view.label}
    data-testid=${testId}
  >
    <span>${view.label}%</span>
  </span>`
}
