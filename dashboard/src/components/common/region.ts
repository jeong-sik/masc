// Region — ARIA landmark region
// Kimi sec06 ARIA pattern: region. Generic section landmark with aria-label.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface RegionProps {
  children: ComponentChildren
  'aria-label': string
  class?: string
}

export function Region({ children, 'aria-label': ariaLabel, class: cx }: RegionProps) {
  return html`
    <section aria-label=${ariaLabel} class=${cx ?? ''}>${children}</section>
  `
}
