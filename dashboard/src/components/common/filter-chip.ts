// FilterChip — single selectable filter chip.
//
// Distinct from <FilterChips> (the collection/bar component): this is the
// individual toggle button. Use it when a parent wants to own layout and
// state, or when composing chips outside the standard tablist pattern.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'

export interface FilterChipProps {
  active?: boolean
  count?: number | string
  onClick?: (e: Event) => void
  children?: ComponentChildren
  class?: string
}

export function FilterChip({
  active = false,
  count,
  onClick,
  children,
  class: cx,
}: FilterChipProps): VNode {
  return html`
    <button
      type="button"
      class=${`rfilter${active ? ' on' : ''}${cx ? ` ${cx}` : ''}`}
      onClick=${onClick}
      aria-pressed=${active}
    >
      ${children}
      ${count != null ? html`<span class="rfilter-n">${count}</span>` : null}
    </button>
  `
}
