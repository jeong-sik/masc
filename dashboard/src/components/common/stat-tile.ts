// StatTile — reusable KPI/stat display tile.
// Layer 1: inline variant (backward compat, label/value/hint).
// Layer 2: kpi.css status semantics (inset accent bar, gradient bg, delta, spark).

import { html } from 'htm/preact'
import { Sparkline } from './sparkline'

type DeltaDirection = 'up' | 'down' | 'flat'

interface StatTileProps {
  label: string
  value: string | number
  hint?: string
  variant?: 'default' | 'gold' | 'accent' | 'warn'
  /** Semantic status — applies kpi.css inset accent bar + gradient bg.
   *  Overrides `variant` for background/value-color when provided. */
  status?: 'crit' | 'warn' | 'ok' | 'brass'
  /** Trend indicator next to value. */
  delta?: { direction: DeltaDirection; text?: string }
  /** Pulse animation on value — signals live-updating data. */
  live?: boolean
  /** Sparkline data points rendered as a mini canvas chart. */
  sparkValues?: number[]
}

const VARIANT_STYLES = {
  default: 'bg-[var(--color-bg-elevated)] border-[var(--color-border-default)] text-[var(--color-fg-secondary)]',
  gold: 'bg-[var(--color-brass-soft)] border-[var(--color-brass-border)] text-[var(--color-fg-secondary)]',
  accent: 'bg-[var(--color-state-active-bg)] border-[var(--color-state-active-border)] text-[var(--color-fg-secondary)]',
  warn: 'bg-[var(--color-warn-soft)] border-[var(--color-warn-border)] text-[var(--color-warn-fg)]',
} as const

const LABEL_STYLES = {
  default: 'text-[var(--color-fg-muted)]',
  gold: 'text-[var(--color-brass-fg)]',
  accent: 'text-[var(--color-state-active-fg)]',
  warn: 'text-[var(--color-warn-fg)]',
} as const

const STATUS_CLASS = {
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

export function StatTile({ label, value, hint, variant = 'default', status, delta, live, sparkValues }: StatTileProps) {
  const useStatus = status != null
  const cellClass = useStatus
    ? `kpi-cell ${STATUS_CLASS[status]}${live ? ' is-live' : ''}`
    : `flex flex-col items-center gap-0.5 rounded-[var(--r-1)] border px-4 py-3 ${VARIANT_STYLES[variant]}`

  const valueClass = useStatus
    ? 'kpi-value'
    : 'text-base font-bold tabular-nums leading-tight'

  const labelClass = useStatus
    ? 'kpi-label'
    : `text-[length:var(--fs-2xs)] tracking-wider uppercase ${LABEL_STYLES[variant]}`

  return html`
    <div class="${cellClass}">
      ${useStatus ? html`
        <span class="${labelClass}">${label}</span>
        <div class="kpi-row">
          <span class="${valueClass}">${value}</span>
          ${delta ? html`<span class="kpi-delta ${delta.direction}">${delta.text ?? DELTA_ARROW[delta.direction]}</span>` : null}
        </div>
      ` : html`
        <span class="${valueClass}">${value}</span>
        <span class="${labelClass}">${label}</span>
        ${hint ? html`<span class="text-[length:var(--fs-2xs)] text-[var(--color-fg-disabled)] mt-0.5">${hint}</span>` : null}
      `}
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
