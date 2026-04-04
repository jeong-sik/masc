// ListItem — clickable or static list row with title/subtitle/detail.
// Replaces 8+ inline w-full p-3 rounded-xl border grid gap-1 patterns.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface ListItemProps {
  title: ComponentChildren
  subtitle?: ComponentChildren
  detail?: ComponentChildren
  onClick?: (e: Event) => void
  class?: string
}

export function ListItem({ title, subtitle, detail, onClick, class: className }: ListItemProps) {
  const base = `w-full p-4 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-2.5 text-left text-inherit ${onClick ? 'cursor-pointer' : 'cursor-default'} ${className ?? ''}`

  const content = html`
    <strong class="text-[var(--text-strong)]">${title}</strong>
    ${subtitle != null ? html`<span class="text-[var(--text-body)] leading-snug">${subtitle}</span>` : null}
    ${detail != null ? html`<small class="text-[var(--text-muted)] leading-snug">${detail}</small>` : null}
  `

  if (onClick) {
    return html`<button type="button" class="${base}" onClick=${onClick}>${content}</button>`
  }
  return html`<div class="${base}">${content}</div>`
}
