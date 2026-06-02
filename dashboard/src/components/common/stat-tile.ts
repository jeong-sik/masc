// StatTile — reusable KPI/stat display tile.
// Uses kpi.css status semantics (inset accent bar, gradient bg, delta, spark).

import { html } from 'htm/preact'
import { Sparkline } from './sparkline'

type DeltaDirection = 'up' | 'down' | 'flat'
type StatTileStatus = 'crit' | 'warn' | 'ok' | 'brass'

interface StatTileProps {
  label: string
  value: string | number
  /** Semantic status — applies kpi.css inset accent bar + gradient bg. */
  status?: StatTileStatus
  /** Trend indicator next to value. */
  delta?: { direction: DeltaDirection; text?: string }
  /** Pulse animation on value — signals live-updating data. */
  live?: boolean
  /** Sparkline data points rendered as a mini canvas chart. */
  sparkValues?: number[]
}

const STATUS_CLASS: Record<StatTileStatus, string> = {
  crit: 'is-crit',
  warn: 'is-warn',
  ok: 'is-ok',
  brass: 'is-brass',
} as const

const DELTA_ARROW: Record<DeltaDirection, string> = {
  up: '↑',
  down: '↓',
  flat: '→',
}

export function StatTile({ label, value, status = 'brass', delta, live, sparkValues }: StatTileProps) {
  return html`
    <div class="kpi-cell ${STATUS_CLASS[status]}${live ? ' is-live' : ''}">
      <span class="kpi-label">${label}</span>
      <div class="kpi-row">
        <span class="kpi-value">${value}</span>
        ${delta ? html`<span class="kpi-delta ${delta.direction}">${delta.text ?? DELTA_ARROW[delta.direction]}</span>` : null}
      </div>
      ${sparkValues && sparkValues.length >= 2 ? html`
        <${Sparkline}
          values=${sparkValues}
          width=${80}
          height=${20}
          color="var(--brass-1)"
          class="kpi-spark"
          ariaHidden=${true}
        />
      ` : null}
    </div>
  `
}

interface StatGridProps {
  items: StatTileProps[]
  cols?: number
}

export function StatGrid({ items, cols = 4 }: StatGridProps) {
  return html`
    <div class="grid gap-3" style="grid-template-columns: repeat(${cols}, 1fr)">
      ${items.map(item => html`<${StatTile} ...${item} />`)}
    </div>
  `
}
