// Vital / Vitals — compact keeper-v2 stat grid.
//
// Lightweight key/value tiles arranged in a 2-column grid. Simpler than
// <KpiCell> / <StatTile> and intentionally unopinionated about surface
// styling beyond the standard border + cell background.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export type VitalTone = 'default' | 'volt' | 'ok' | 'warn' | 'bad'

export interface VitalItem {
  /** Label (upper-cased by CSS). */
  k: string
  /** Display value. */
  v: string | number
  /** Optional value tone. */
  tone?: VitalTone
}

export interface VitalProps extends VitalItem {}

export interface VitalsProps {
  items: VitalItem[]
  class?: string
}

export function Vital({ k, v, tone = 'default' }: VitalProps): VNode {
  return html`
    <div class="vital">
      <div class="vk">${k}</div>
      <div class=${`vv${tone === 'default' ? '' : ` ${tone}`}`}>${v}</div>
    </div>
  `
}

export function Vitals({ items, class: cx }: VitalsProps): VNode {
  return html`
    <div class=${`vitals ${cx ?? ''}`.trim()}>
      ${items.map((item, i) => html`<${Vital} key=${i} ...${item} />`)}
    </div>
  `
}
