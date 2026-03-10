// Generic card wrapper — consistent card styling

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { PanelSemanticDetails } from './semantic-layer'

interface CardProps {
  title?: ComponentChildren
  class?: string
  semanticId?: string
  children: ComponentChildren
}

export function Card({ title, class: className, semanticId, children }: CardProps) {
  return html`
    <div class="card ${className ?? ''}">
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
