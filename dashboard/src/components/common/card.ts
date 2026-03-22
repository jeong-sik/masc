// Generic card wrapper — consistent card styling

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface CardProps {
  title?: ComponentChildren
  class?: string
  testId?: string
  children: ComponentChildren
}

export function Card({ title, class: className, testId, children }: CardProps) {
  return html`
    <div class="card rounded-xl ${className ?? ''}" data-testid=${testId}>
      ${title
        ? html`
            <div class="card rounded-xl-title-row">
              <div class="card rounded-xl-title">${title}</div>
            </div>
          `
        : null}
      ${children}
    </div>
  `
}
