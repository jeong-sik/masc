// Generic card wrapper — consistent card styling

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface CardProps {
  title?: ComponentChildren
  class?: string
  semanticId?: string
  testId?: string
  children: ComponentChildren
}

export function Card({ title, class: className, semanticId: _semanticId, testId, children }: CardProps) {
  return html`
    <div class="card ${className ?? ''}" data-testid=${testId}>
      ${title
        ? html`
            <div class="card-title-row">
              <div class="card-title">${title}</div>
            </div>
          `
        : null}
      ${children}
    </div>
  `
}
