// SuggestionChip — a keeper's proposed next action.
//
// Renders as a clickable capsule with a leading arrow/pre affordance.
// Scoped to .suggestion-chip so it does not collide with the dashboard's
// existing .chip tag primitive.

import { html } from 'htm/preact'
import type { JSX, ComponentChildren, VNode } from 'preact'

export interface SuggestionChipProps extends JSX.HTMLAttributes<HTMLButtonElement> {
  pre?: string | VNode
  children?: ComponentChildren
}

export function SuggestionChip({
  pre = '\u2192',
  children,
  class: cx,
  ...rest
}: SuggestionChipProps): VNode {
  const cls = `suggestion-chip${cx ? ` ${cx}` : ''}`
  return html`
    <button type="button" class=${cls} ...${rest}>
      ${pre ? html`<span class="suggestion-chip-pre">${pre}</span>` : null}
      ${children}
    </button>
  `
}
