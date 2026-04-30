// Treegrid — hierarchical grid with ARIA treegrid pattern
// Kimi sec06 ARIA pattern: treegrid. role="treegrid" + row/cell roles.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface TreegridProps {
  children: ComponentChildren
  'aria-label': string
  class?: string
}

interface TreegridRowProps {
  children: ComponentChildren
  expanded?: boolean
  level?: number
  class?: string
}

interface TreegridCellProps {
  children: ComponentChildren
  class?: string
}

export function Treegrid({ children, 'aria-label': ariaLabel, class: cx }: TreegridProps) {
  return html`<table role="treegrid" aria-label=${ariaLabel} class=${cx ?? ''}>${children}</table>`
}

export function TreegridRow({ children, expanded, level, class: cx }: TreegridRowProps) {
  return html`<tr role="row" aria-expanded=${expanded} aria-level=${level} class=${cx ?? ''}>${children}</tr>`
}

export function TreegridCell({ children, class: cx }: TreegridCellProps) {
  return html`<td role="gridcell" class=${cx ?? ''}>${children}</td>`
}
