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
  default: 'bg-[var(--white-4)] border-[var(--card-border)] text-[var(--text-strong)]',
  gold: 'bg-[rgba(200,168,78,0.05)] border-[var(--ff-gold-10)] text-[var(--text-strong)]',
  accent: 'bg-[var(--accent-soft)] border-[rgba(71,184,255,0.2)] text-[var(--text-strong)]',
  warn: 'bg-[rgba(230,167,0,0.06)] border-[rgba(230,167,0,0.2)] text-[var(--warn)]',
} as const

const LABEL_STYLES = {
  default: 'text-[var(--text-muted)]',
  gold: 'text-[var(--ff-gold)]',
  accent: 'text-[var(--accent)]',
  warn: 'text-[var(--warn)]',
} as const

function StatTile({ label, value, hint, variant = 'default' }: StatTileProps) {
  return html`
    <div class="flex flex-col items-center gap-0.5 rounded-lg border px-4 py-3 ${VARIANT_STYLES[variant]}">
      <span class="text-base font-bold tabular-nums leading-tight">${value}</span>
      <span class="text-[length:var(--fs-2xs)] tracking-wider uppercase ${LABEL_STYLES[variant]}">${label}</span>
      ${hint ? html`<span class="text-[length:var(--fs-2xs)] text-[var(--text-dim)] mt-0.5">${hint}</span>` : null}
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
