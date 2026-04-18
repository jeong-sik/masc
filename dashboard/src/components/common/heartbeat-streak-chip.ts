// HeartbeatStreakChip — tiny status badge answering "how long has
// this connector been in its current state?".
//
// Reference UIs (Uptime Kuma monitor row, Statuspage component card):
// the current state + its duration is the first thing an operator
// wants to know. "Up for 22 checks" is strictly more useful than
// "Up" alone — it tells you if the service is stable or just briefly
// recovered. Paired with HeartbeatStrip (#8028) which shows the full
// history bar: chip = current headline, strip = backstory.

import { html } from 'htm/preact'
import {
  currentHeartbeatStreak,
  type HeartbeatState,
  type HeartbeatStreak,
} from '../../lib/heartbeat-history'

const STATE_GLYPH: Record<HeartbeatState, string> = {
  up: '▲',
  down: '▼',
  unknown: '·',
}

const STATE_LABEL: Record<HeartbeatState, string> = {
  up: 'UP',
  down: 'DOWN',
  unknown: 'N/A',
}

const STATE_TONE: Record<HeartbeatState, string> = {
  up: 'text-[var(--ok)] border-[var(--ok-20)] bg-[var(--ok-10)]',
  down: 'text-[var(--bad-light)] border-[var(--bad-20)] bg-[var(--bad-10)]',
  unknown: 'text-[var(--text-dim)] border-[var(--white-8)] bg-[var(--white-2)]',
}

/** Pure: render a streak as narrator-friendly text. Exposed so the
    same label can appear in tooltips, aria-labels, and future log
    exports without each caller re-deriving the grammar. */
export function formatStreakLabel(streak: HeartbeatStreak | null): string {
  if (streak === null) return 'Heartbeat: no data yet'
  const unit = streak.samples === 1 ? 'check' : 'checks'
  return `${STATE_LABEL[streak.state]} for ${streak.samples} ${unit}`
}

interface HeartbeatStreakChipProps {
  history: HeartbeatState[]
  class?: string
  testId?: string
}

export function HeartbeatStreakChip({
  history,
  class: cx,
  testId,
}: HeartbeatStreakChipProps) {
  const streak = currentHeartbeatStreak(history)
  if (streak === null) {
    // No data yet — render nothing rather than a stubby "0 checks"
    // placeholder. HeartbeatStrip below will show the unknown pad.
    return null
  }
  const tone = STATE_TONE[streak.state]
  const label = formatStreakLabel(streak)
  const chipClass = cx ?? ''
  return html`<span
    class=${`inline-flex items-center gap-1 rounded-sm border px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] tabular-nums ${tone} ${chipClass}`}
    title=${label}
    aria-label=${label}
    data-heartbeat-streak-chip
    data-heartbeat-streak-state=${streak.state}
    data-heartbeat-streak-samples=${streak.samples}
    data-testid=${testId}
  >
    <span aria-hidden="true">${STATE_GLYPH[streak.state]}</span>
    <span>${STATE_LABEL[streak.state]}</span>
    <span class="text-[var(--text-dim)]">×</span>
    <span>${streak.samples}</span>
  </span>`
}
