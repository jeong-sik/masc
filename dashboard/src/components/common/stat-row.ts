// KpiCard / StatGrid — data display primitives

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

// ── KPI card (vertical: label on top, big number, optional hint) ──
interface KpiCardProps {
  label: string
  value: string | number | ComponentChildren
  hint?: string
  tone?: string
  class?: string
}

export function KpiCard({ label, value, hint, tone, class: cx }: KpiCardProps) {
  return html`
    <div class="flex flex-col gap-1 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] ${cx ?? ''}">
      <span class="text-3xs text-[var(--text-muted)] uppercase tracking-[0.06em] font-medium">${label}</span>
      <span class="text-[20px] font-semibold tabular-nums leading-none ${tone ?? 'text-[var(--text-strong)]'}">${value}</span>
      ${hint ? html`<span class="text-2xs text-[var(--text-dim)] mt-0.5">${hint}</span>` : null}
    </div>
  `
}

// ── Stat grid (2-col or 3-col layout) ──
interface StatGridProps {
  cols?: 2 | 3 | 4
  class?: string
  children: ComponentChildren
}

export function StatGrid({ cols = 2, class: cx, children }: StatGridProps) {
  const colClass = cols === 2 ? 'grid-cols-2' : cols === 3 ? 'grid-cols-3' : 'grid-cols-4'
  return html`
    <div class="grid ${colClass} gap-x-4 gap-y-1 text-2xs ${cx ?? ''}">${children}</div>
  `
}


