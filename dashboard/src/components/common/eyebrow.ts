import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface EyebrowProps {
  tone?: 'muted' | 'disabled'
  class?: string
  children: ComponentChildren
}

/** Inline eyebrow label — `text-3xs uppercase tracking-wider` used inside cards */
export function Eyebrow({ tone = 'muted', class: cx, children }: EyebrowProps) {
  const color =
    tone === 'disabled'
      ? 'text-[var(--color-fg-disabled)]'
      : 'text-[var(--color-fg-muted)]'
  return html`<span class="text-3xs uppercase tracking-wider ${color} ${cx ?? ''}">${children}</span>`
}
