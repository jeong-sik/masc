// SectionHeader — consistent section labels across dashboard
// Replaces 34+ inline patterns: `text-3xs uppercase tracking-1 text-[var(--color-fg-muted)] font-medium`

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type HeaderSize = 'xs' | 'sm' | 'md'

const SIZE_CLASSES: Record<HeaderSize, string> = {
  xs: 'text-3xs font-semibold tracking-wider',
  sm: 'text-2xs font-medium tracking-[0.06em]',
  md: 'text-sm font-medium tracking-[0.06em]',
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
  size = 'sm',
  class: cx,
  right,
  children,
}: SectionHeaderProps) {
  return html`
    <div class="flex items-center justify-between gap-2 ${cx ?? ''}">
      <h4 class="m-0 ${SIZE_CLASSES[size]} uppercase tracking-[0.06em] text-[var(--color-fg-muted)]">${children}</h4>
      ${right ?? null}
    </div>
  `
}
