// Generic card wrapper — consistent card styling

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { PanelSemanticDetails } from './semantic-layer'

interface CardProps {
  title?: ComponentChildren
  class?: string
  semanticId?: string
  testId?: string
  children: ComponentChildren
}

export function Card({ title, class: className, semanticId, testId, children }: CardProps) {
  return html`
    <div class="card ${className ?? ''}" data-testid=${testId}>
      ${title
        ? html`
            <div class="card-title-row">
              <div class="card-title">${title}</div>
              ${semanticId ? html`<${PanelSemanticDetails} panelId=${semanticId} compact=${true} />` : null}
            </div>
          `
        : null}
      ${children}
    </div>
  `
}
