// Band — atomic primitive ported from design-system v0.4 primitives.html
// (`<div class="band is-{kind}"></div>`). The SPEC defines a 2px strip
// at the top of cards indicating overall state. Pure decoration: no
// content, no role, no aria — its job is to give the card a single-
// glance state cue alongside whatever Pill/Chip/text the body carries.
//
// Distinct from Bar (4px progress with fill width%), Chip (label),
// and Pill (capsule state badge): Band is a *card-level* state strip,
// always 100% width, 2px tall, no quantity, no label.
//
// SPEC mapping (primitives.css `.band`):
//   default          — --color-border-strong (idle, no state)
//   .band.is-running — --color-accent-fg + glow shadow
//   .band.is-ok      — --ok
//   .band.is-warn    — --warn
//   .band.is-err     — --err
//   .band.is-stalled — --stalled
//
// Dashboard token mapping (no glow channel needed except `running`):
//   default → --color-border-strong
//   running → --color-accent-fg + box-shadow w/ rgb(var(--color-accent-glow) / 0.5)
//   ok      → --color-status-ok
//   warn    → --color-status-warn
//   err     → --color-status-err
//   stalled → --color-status-stalled
//
// The accent-glow channel was added in #11163, so `running` reaches
// 100% SPEC fidelity (with a 6px box-shadow glow). Other kinds use
// solid fill — also 100% fidelity.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export type BandKind =
  | 'default'
  | 'running'
  | 'ok'
  | 'warn'
  | 'err'
  | 'stalled'

export interface BandProps {
  /** State tone. `undefined` ≡ `default` (idle, border-strong color). */
  kind?: BandKind
  /** Forwarded to data-testid. */
  testId?: string
  /** Border radius on top corners only. Default true (matches SPEC
   *  `.band` rendered above a card's rounded surface — `1px 1px 0 0`).
   *  Set false when the band is not at the top of a rounded container. */
  topRadius?: boolean
}

interface KindStyle {
  background: string
  boxShadow?: string
}

const KIND_STYLE: Record<BandKind, KindStyle> = {
  default: {
    background: 'var(--color-border-strong)',
  },
  running: {
    background: 'var(--color-accent-fg)',
    boxShadow: '0 0 6px rgb(var(--color-accent-glow, 71 184 255) / 0.5)',
  },
  ok: {
    background: 'var(--color-status-ok)',
  },
  warn: {
    background: 'var(--color-status-warn)',
  },
  err: {
    background: 'var(--color-status-err)',
  },
  stalled: {
    background: 'var(--color-status-stalled)',
  },
}

export function Band(props: BandProps): VNode {
  const kind = props.kind ?? 'default'
  const ks = KIND_STYLE[kind]
  const topRadius = props.topRadius !== false

  const style = {
    display: 'block',
    height: '2px',
    width: '100%',
    background: ks.background,
    borderRadius: topRadius ? '1px 1px 0 0' : '0',
    boxShadow: ks.boxShadow,
  }

  return html`
    <div
      aria-hidden="true"
      data-testid=${props.testId}
      data-kind=${kind}
      style=${style}
    ></div>
  `
}
