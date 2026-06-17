// Stepper — +/- numeric control.
//
// Ported from keeper-v2 primitives.jsx. Value is always controlled;
// onChange fires with the next integer clamped to min/max.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export interface StepperProps {
  value?: number
  min?: number
  max?: number
  onChange?: (value: number) => void
}

export function Stepper({ value = 0, min = -Infinity, max = Infinity, onChange }: StepperProps): VNode {
  return html`
    <div class="set-stepper">
      <button
        type="button"
        onClick=${() => onChange?.(Math.max(min, value - 1))}
        aria-label="Decrease"
      >−</button>
      <span class="mono">${value}</span>
      <button
        type="button"
        onClick=${() => onChange?.(Math.min(max, value + 1))}
        aria-label="Increase"
      >+</button>
    </div>
  `
}
