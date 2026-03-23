// ActionBar — consistent action button row at the bottom of cards.
// Replaces repeated flex gap-2 flex-wrap mt-3 + control-btn patterns.

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

interface ActionBtnProps {
  label: string
  onClick: (e: Event) => void
  disabled?: boolean
}

export function ActionBtn({ label, onClick, disabled }: ActionBtnProps) {
  return html`
    <button type="button" class="control-btn rounded-lg ghost" onClick=${onClick} disabled=${disabled}>
      ${label}
    </button>
  `
}
