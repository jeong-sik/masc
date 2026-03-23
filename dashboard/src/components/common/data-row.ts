// DataRow — horizontal key-value display with alternating background
// Replaces 16+ inline patterns: `flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]`

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface DataRowProps {
  label: string
  class?: string
  /** Alternate background (for even rows in a list) */
  alt?: boolean
  children: ComponentChildren
}

/** Single key-value row with muted label and right-aligned value */
export function DataRow({ label, class: cx, alt, children }: DataRowProps) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg ${alt ? 'bg-[var(--white-3)]' : ''} ${cx ?? ''}">
      <span class="text-xs text-[var(--text-muted)]">${label}</span>
      <span class="text-xs font-medium text-[var(--text-strong)]">${children}</span>
    </div>
  `
}

interface DataRowGroupProps {
  class?: string
  children: ComponentChildren
}

/** Stack of DataRows with consistent spacing */
export function DataRowGroup({ class: cx, children }: DataRowGroupProps) {
  return html`<div class="flex flex-col gap-0.5 ${cx ?? ''}">${children}</div>`
}
