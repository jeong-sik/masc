// TagBadge — rounded-full info chip for inline metadata display.
// Replaces 5+ inline px-2.5 py-1.5 rounded-full border patterns.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface TagBadgeProps {
  children: ComponentChildren
  onClick?: (e: Event) => void
  class?: string
}

export function TagBadge({ children, onClick, class: className }: TagBadgeProps) {
  const base = 'px-2.5 py-1.5 rounded-full border border-[var(--white-8)] bg-[var(--white-4)] text-[var(--text-body)] text-xs leading-tight'
  if (onClick) {
    return html`<button type="button" class="${base} cursor-pointer ${className ?? ''}" onClick=${onClick}>${children}</button>`
  }
  return html`<span class="${base} ${className ?? ''}">${children}</span>`
}
