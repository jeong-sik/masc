// StatCell — label/value/detail stat box for mission cards and grids.
// Replaces 12+ inline p-3 rounded-xl bg-[var(--white-4)] grid gap-1 patterns.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface StatCellProps {
  label: string
  value: ComponentChildren
  detail?: ComponentChildren
  tone?: string
  class?: string
}

export function StatCell({ label, value, detail, tone, class: className }: StatCellProps) {
  return html`
    <div class="p-4 rounded-xl bg-[var(--white-4)] border border-[var(--white-6)] grid gap-1.5 ${tone ?? ''} ${className ?? ''}">
      <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">${label}</span>
      <strong class="text-[var(--text-strong)] text-lg leading-tight tabular-nums">${value}</strong>
      ${detail != null ? html`<small class="text-[var(--text-muted)] text-[10px] leading-relaxed">${detail}</small>` : null}
    </div>
  `
}
