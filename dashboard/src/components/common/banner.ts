// Banner — ARIA banner landmark

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface BannerProps {
  children: ComponentChildren
  'aria-label'?: string
  class?: string
}

export function Banner({ children, 'aria-label': ariaLabel, class: cx }: BannerProps) {
  return html`
    <header role="banner" aria-label=${ariaLabel} class=${cx ?? ''}>
      ${children}
    </header>
  `
}
