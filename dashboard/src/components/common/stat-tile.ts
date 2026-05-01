// StatTile — reusable KPI/stat display tile
// Replaces inline stat boxes in overview, planning, keeper detail.

import { html } from 'htm/preact'

interface StatTileProps {
  label: string
  value: string | number
  hint?: string
  variant?: 'default' | 'gold' | 'accent' | 'warn'
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

export function StatTile({ label, value, hint, variant = 'default' }: StatTileProps) {
  return html`
    <div class="flex flex-col items-center gap-0.5 rounded border px-4 py-3 ${VARIANT_STYLES[variant]}">
      <span class="text-base font-bold tabular-nums leading-tight">${value}</span>
      <span class="text-[length:var(--fs-2xs)] tracking-wider uppercase ${LABEL_STYLES[variant]}">${label}</span>
      ${hint ? html`<span class="text-[length:var(--fs-2xs)] text-[var(--color-fg-disabled)] mt-0.5">${hint}</span>` : null}
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
