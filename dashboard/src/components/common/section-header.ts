// SectionHeader — consistent section labels across dashboard
// Replaces 34+ inline patterns: `text-[10px] uppercase tracking-[0.08em] text-[var(--text-muted)] font-medium`

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type HeaderSize = 'xs' | 'sm' | 'md'

const SIZE_CLASSES: Record<HeaderSize, string> = {
  xs: 'text-[10px]',
  sm: 'text-[11px]',
  md: 'text-[13px]',
}

interface SectionHeaderProps {
  size?: HeaderSize
  class?: string
  /** Right-side slot (counts, actions) */
  right?: ComponentChildren
  children: ComponentChildren
}

/** Uppercase tracked section label — the dashboard's standard heading pattern */
export function SectionHeader({
  size = 'xs',
  class: cx,
  right,
  children,
}: SectionHeaderProps) {
  return html`
    <div class="flex items-center justify-between gap-2 ${cx ?? ''}">
      <h4 class="m-0 ${SIZE_CLASSES[size]} uppercase tracking-[0.06em] text-[var(--text-muted)] font-medium">${children}</h4>
      ${right ?? null}
    </div>
  `
}
