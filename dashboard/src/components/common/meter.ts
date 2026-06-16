// Meter — horizontal quantity bar (keeper-v2 primitive port).
//
// A thinner, more dramatic progress indicator than <Bar>. Use for
// context-ratio, budget, or any "how full" signal where the meter
// should read as a gauge rather than a completion bar.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export interface MeterProps {
  /** Percentage fill 0–100. Out-of-range values are clamped. */
  pct?: number
  /** Hot gradient (warn → err) instead of the default accent gradient. */
  hot?: boolean
  /** Override the default aria-label ("<pct>%"). */
  ariaLabel?: string
  /** Forwarded to data-testid. */
  testId?: string
}

/** Clamp and round a percentage to the renderable [0, 100] range. */
export function meterPercent(value: number): number {
  if (Number.isNaN(value)) return 0
  return Math.max(0, Math.min(100, Math.round(value)))
}

export function Meter({ pct = 0, hot = false, ariaLabel, testId }: MeterProps): VNode {
  const clamped = meterPercent(pct)
  const announce = ariaLabel ?? `${clamped}%`

  return html`
    <div
      class=${`meter${hot ? ' hot' : ''}`}
      role="progressbar"
      aria-valuenow=${clamped}
      aria-valuemin=${0}
      aria-valuemax=${100}
      aria-label=${announce}
      data-testid=${testId}
    >
      <span aria-hidden="true" style=${{ width: `${clamped}%` }}></span>
    </div>
  `
}
