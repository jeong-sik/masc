// StatCell — single stat tile from the keeper-v2 overview family.
//
// Larger value, small-caps label, optional sub-unit. Composes into an
// outer grid (e.g. <StatGrid>) exactly like the source `.ov-kpis` strip.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export type StatCellTone = 'ok' | 'bad' | 'warn' | 'volt'

export interface StatCellProps {
  label: string
  value: string | number
  /** Optional small suffix rendered after the value. */
  sub?: string
  /** Optional value tone. */
  tone?: StatCellTone
}

export function StatCell({ label, value, sub, tone }: StatCellProps): VNode {
  return html`
    <div class="stat-cell">
      <div class="stat-cell-k">${label}</div>
      <div class=${`stat-cell-v ${tone ?? ''}`.trim()}>
        ${value}${sub ? html`<small> ${sub}</small>` : null}
      </div>
    </div>
  `
}
