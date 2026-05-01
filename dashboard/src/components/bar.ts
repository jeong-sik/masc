// Bar — atomic primitive ported from design-system v0.4 primitives.html
// (`<div class="bar"><div class="fill"></div></div>`). The SPEC defines
// a 4px progress bar with kind-tinted fill (default brass + ok/warn/err
// variants). Used wherever an inline progress signal lives next to a
// metric — task counters, goal completion, budget consumption.
//
// Distinct from Pill (16px stateful capsule) and Chip (sharp 2px label):
// Bar is a pure *quantity* primitive — it shows "how full" without
// announcing a state transition. role="progressbar" on the host gives
// assistive tech the value/min/max contract directly.
//
// SPEC mapping (primitives.css lines for `.bar`):
//   .bar       — 4px height, --color-bg-elevated track, 2px radius
//   .bar > .fill        — default brass-2 fill
//   .bar.is-ok  > .fill — --ok fill
//   .bar.is-warn> .fill — --warn fill
//   .bar.is-err > .fill — --err fill
//
// Dashboard token mapping (no glow channel needed — Bar is solid fill):
//   default → --color-accent-fg
//   ok      → --color-status-ok
//   warn    → --color-status-warn
//   err     → --color-status-err
//
// Future: Bar-segment variant (`.bar-seg` with seg-ok/seg-err/seg-warn/
// seg-idle stripes for passing/failing/skipped split) is intentionally
// not in this PR; introduce as a separate `BarSeg` primitive when the
// first callsite (e.g. test result split) lands.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { barPercent, FILL_COLOR, type BarProps } from './bar-shared'

export { barPercent, type BarProps, type BarKind } from './bar-shared'

export function Bar(props: BarProps): VNode {
  const kind = props.kind ?? 'default'
  const pct = barPercent(props.value)
  const fillColor = FILL_COLOR[kind]

  const trackStyle = {
    display: 'block',
    width: '100%',
    height: '4px',
    background: 'var(--color-bg-elevated)',
    borderRadius: '2px',
    overflow: 'hidden' as const,
  }

  const fillStyle = {
    display: 'block',
    height: '100%',
    width: `${pct}%`,
    background: fillColor,
    transition: props.noTransition === true ? undefined : 'width 500ms',
  }

  const announce = props.ariaLabel ?? `${pct}%`

  return html`
    <div
      role="progressbar"
      aria-valuenow=${pct}
      aria-valuemin=${0}
      aria-valuemax=${100}
      aria-label=${announce}
      data-testid=${props.testId}
      data-kind=${kind}
      title=${props.title}
      style=${trackStyle}
    >
      <span aria-hidden="true" style=${fillStyle}></span>
    </div>
  `
}
