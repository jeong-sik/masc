// KvRow — atomic primitive ported from design-system v0.4
// primitives.html (`<div class="kv-row"><span class="k">LABEL</span>
// <span class="v">value</span></div>`). The SPEC defines a single
// label / value row with a fixed 80px label column, 4px vertical
// padding, baseline alignment, uppercase muted label, and a mono
// value in primary fg. Used inside drawer details, inspector panels,
// keeper-detail KV strips — anywhere a screen says "here are the
// metadata facts about this thing".
//
// Distinct from existing dashboard primitives:
//
//   AuthRow (auth-status.ts) — `display:contents` cells that fill a
//     parent grid. Coupled to its parent's grid template; not a
//     self-contained row. This PR replaces all four AuthRow callers
//     with KvRow + a `flex flex-col` parent.
//   StatCell / KpiCell — value-first metric tiles, not label/value
//     symmetry. Different intent.
//
// SPEC mapping (primitives.css `.kv-row`):
//   grid-template-columns: 80px 1fr  (`is-wide` → 120px 1fr)
//   gap: var(--sp-3) (12px)
//   padding: 4px 0
//   align-items: baseline
//   font-size: 11px
//   .k → fg-muted, fs-10, uppercase, letter-spacing 0.06em
//   .v → fg-primary, mono, fs-11

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

export interface KvRowProps {
  /** Label text (rendered uppercase via the SPEC font rule). */
  label: string
  /** Value content. Either a string (rendered as the SPEC mono span)
   *  or arbitrary children (chips, pills, links — caller controls
   *  font then). When children are provided, `value` is ignored. */
  value?: string
  children?: ComponentChildren
  /** SPEC `.kv-row.is-wide` — 120px label column. Default false. */
  wide?: boolean
  /** Allow long values to wrap on word boundaries. SPEC value is
   *  whitespace:nowrap by default; long ids / paths often need wrap.
   *  Default false (matches SPEC). */
  wrap?: boolean
  /** Forwarded to data-testid on the row container. */
  testId?: string
}


export function KvRow(props: KvRowProps): VNode {
  const wide = props.wide === true

  const rowStyle = {
    display: 'grid',
    gridTemplateColumns: wide ? '120px 1fr' : '80px 1fr',
    gap: 'var(--sp-3)',
    padding: 'var(--sp-1) 0',
    alignItems: 'baseline' as const,
    fontSize: 'var(--fs-11)',
  }

  const keyStyle = {
    color: 'var(--color-fg-muted)',
    fontSize: 'var(--fs-10)',
    textTransform: 'uppercase' as const,
    letterSpacing: '0.06em',
  }

  const valueStyle = {
    color: 'var(--color-fg-primary)',
    fontFamily: MONO_STACK,
    fontSize: 'var(--fs-11)',
    whiteSpace: props.wrap === true ? 'normal' as const : 'nowrap' as const,
    overflow: props.wrap === true ? undefined : 'hidden',
    textOverflow: props.wrap === true ? undefined : 'ellipsis',
    wordBreak: props.wrap === true ? 'break-all' as const : undefined,
  }

  // Children win over the value string — callers passing chips /
  // pills as the value need their own typography, not the mono span.
  const valueContent = props.children != null
    ? props.children
    : html`<span data-kv-value style=${valueStyle}>${props.value ?? ''}</span>`

  return html`
    <div
      data-testid=${props.testId}
      data-kv-row
      data-kv-wide=${wide ? 'true' : 'false'}
      style=${rowStyle}
    >
      <span data-kv-key style=${keyStyle}>${props.label}</span>
      ${valueContent}
    </div>
  `
}
