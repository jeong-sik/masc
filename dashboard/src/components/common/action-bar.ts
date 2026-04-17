// ActionBar — consistent action button row at the bottom of cards.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface ActionBarProps {
  children: ComponentChildren
  class?: string
}

export function ActionBar({ children, class: className }: ActionBarProps) {
  return html`
    <div class="flex gap-3 flex-wrap mt-3 ${className ?? ''}">
      ${children}
    </div>
  `
}
