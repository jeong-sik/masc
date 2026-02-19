// Generic card wrapper — consistent card styling

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface CardProps {
  title?: string
  class?: string
  children: ComponentChildren
}

export function Card({ title, class: className, children }: CardProps) {
  return html`
    <div class="card ${className ?? ''}">
      ${title ? html`<div class="card-title">${title}</div>` : null}
      ${children}
    </div>
  `
}
