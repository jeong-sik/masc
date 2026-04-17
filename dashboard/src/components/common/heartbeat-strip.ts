// HeartbeatStrip — Uptime Kuma style pulse row showing the last N samples.
//
// Reference UI (Uptime Kuma status page): row of ~45 colored bars, left=oldest
// right=newest, tones: emerald (up), rose (down), muted gray (unknown / no
// data yet). A single combined tooltip summarizes uptime % + sample count;
// per-bar hover is intentionally omitted to keep the strip dense.

import { html } from 'htm/preact'
import type { HeartbeatState } from '../../lib/heartbeat-history'

const COLOR: Record<HeartbeatState, string> = {
  // Emerald 500 / Rose 500 / Zinc 700 — matches the dashboard token palette.
  up: 'bg-emerald-500',
  down: 'bg-rose-500',
  unknown: 'bg-[var(--white-8)]',
}

const BAR_W = 'w-[4px]'
const BAR_H = 'h-3'
const BAR_RADIUS = 'rounded-[1px]'

/** Pure: left-pad the history with 'unknown' so a new connector still
    renders a full-width strip (empty slots read as "no data yet" rather
    than a stubby row). */
export function padHistory(
  history: HeartbeatState[],
  slots: number,
): HeartbeatState[] {
  if (history.length >= slots) return history.slice(history.length - slots)
  const padding: HeartbeatState[] = Array(slots - history.length).fill('unknown')
  return [...padding, ...history]
}

export interface HeartbeatSummary {
  total: number
  up: number
  down: number
  unknown: number
  /** up / (up + down), ignoring unknowns. null when no real samples. */
  uptimePct: number | null
}

/** Pure: compute uptime stats from a history array. Uptime % ignores
    unknown samples (matching Uptime Kuma's "ignore pending" convention). */
export function summarizeHistory(history: HeartbeatState[]): HeartbeatSummary {
  let up = 0
  let down = 0
  let unknown = 0
  for (const s of history) {
    if (s === 'up') up++
    else if (s === 'down') down++
    else unknown++
  }
  const observed = up + down
  return {
    total: history.length,
    up,
    down,
    unknown,
    uptimePct: observed === 0 ? null : (up / observed) * 100,
  }
}

/** Pure: format the tooltip / aria-label narrative. Matches the Uptime
    Kuma "{uptime}% uptime · {up}/{total}" convention. */
export function formatHeartbeatLabel(summary: HeartbeatSummary): string {
  if (summary.uptimePct === null) {
    return 'Heartbeat: no data yet'
  }
  const pct = summary.uptimePct.toFixed(summary.uptimePct >= 99 ? 2 : 1)
  return `Heartbeat: ${pct}% uptime · ${summary.up}/${summary.up + summary.down} observed`
}

export interface HeartbeatStripProps {
  history: HeartbeatState[]
  /** Number of bar slots to render. Defaults to 45 (Uptime Kuma parity). */
  slots?: number
  class?: string
  /** Override the auto-generated aria-label. */
  ariaLabel?: string
  /** `data-testid` for E2E stable hooks. */
  testId?: string
}

export function HeartbeatStrip({
  history,
  slots = 45,
  class: cx,
  ariaLabel,
  testId,
}: HeartbeatStripProps) {
  const bars = padHistory(history, slots)
  const summary = summarizeHistory(history)
  const label = ariaLabel ?? formatHeartbeatLabel(summary)
  const cls = cx ? `inline-flex items-end gap-[2px] ${cx}` : 'inline-flex items-end gap-[2px]'
  return html`<span
    class=${cls}
    role="img"
    aria-label=${label}
    title=${label}
    data-testid=${testId}
    data-heartbeat-uptime=${summary.uptimePct === null ? 'n/a' : summary.uptimePct.toFixed(2)}
    data-heartbeat-samples=${summary.total}
  >${bars.map(state => html`
    <span
      class=${`${BAR_W} ${BAR_H} ${BAR_RADIUS} ${COLOR[state]}`}
      data-heartbeat-bar=${state}
    ></span>
  `)}</span>`
}
