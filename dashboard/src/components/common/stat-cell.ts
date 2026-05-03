// StatCell — label/value/detail stat box for mission cards and grids.
// Replaces 12+ inline p-3 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] grid gap-1 patterns.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface StatCellProps {
  label: string
  value: ComponentChildren
  detail?: ComponentChildren
  tone?: string
  size?: 'md' | 'lg'
  bg?: 'white-3' | 'white-4'
  class?: string
}

const BG = {
  'white-3': 'bg-[var(--color-bg-panel-alt)]',
  'white-4': 'bg-[var(--color-bg-elevated)]',
} as const

const VALUE_SIZE = {
  md: 'text-lg',
  lg: 'text-xl',
} as const

export function StatCell({ label, value, detail, tone, size = 'md', bg = 'white-4', class: className }: StatCellProps) {
  return html`
    <div class="p-4 rounded-[var(--r-1)] ${BG[bg]} border border-[var(--color-border-default)] grid gap-1.5 ${tone ?? ''} ${className ?? ''}" role="group" aria-label="${label}: ${value}${detail != null ? ` (${detail})` : ''}">
      <span class="text-3xs text-[var(--color-fg-muted)] tracking-wider uppercase font-medium">${label}</span>
      <strong class="text-[var(--color-fg-secondary)] ${VALUE_SIZE[size]} leading-tight tabular-nums">${value}</strong>
      ${detail != null ? html`<small class="text-[var(--color-fg-muted)] text-3xs leading-relaxed">${detail}</small>` : null}
    </div>
  `
}
