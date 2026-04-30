// Log — ARIA live region for appended messages
// Kimi sec06 ARIA pattern: log. role="log" with implicit aria-live="polite".

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface LogProps {
  children: ComponentChildren
  'aria-label'?: string
  class?: string
}

export function Log({ children, 'aria-label': ariaLabel, class: cx }: LogProps) {
  return html`
    <div role="log" aria-label=${ariaLabel} class=${cx ?? ''}>${children}</div>
  `
}
