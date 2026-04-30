// List — ARIA list primitive
// Kimi sec06 ARIA pattern: list. role="list" container + role="listitem" items.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface ListProps {
  children: ComponentChildren
  class?: string
}

export function List({ children, class: cx }: ListProps) {
  return html`<ul role="list" class=${cx ?? ''}>${children}</ul>`
}

interface ListItemProps {
  children: ComponentChildren
  class?: string
}

export function ListItem({ children, class: cx }: ListItemProps) {
  return html`<li role="listitem" class=${cx ?? ''}>${children}</li>`
}
