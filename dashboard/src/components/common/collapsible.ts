// CollapsibleSection — consistent expandable section
// Replaces 5+ inline `<details class="rounded border border-[var(--card-border)] overflow-hidden">` patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface CollapsibleSectionProps {
  title: ComponentChildren
  open?: boolean
  id?: string
  class?: string
  /** Summary extra content (badges, counts) */
  badge?: ComponentChildren
  children: ComponentChildren
}

export function CollapsibleSection({
  title,
  open,
  id,
  class: cx,
  badge,
  children,
}: CollapsibleSectionProps) {
  return html`
    <details open=${open} id=${id} class="rounded border border-[var(--card-border)] overflow-hidden ${cx ?? ''}">
      <summary class="flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)] select-none hover:bg-[var(--white-3)] transition-colors list-none">
        ${title}
        ${badge ?? null}
      </summary>
      <div class="p-4 pt-0">
        ${children}
      </div>
    </details>
  `
}
