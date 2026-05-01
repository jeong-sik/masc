// SectionHead — atomic primitive ported from design-system v0.4
// primitives.html (`<div class="section-head"><span>LABEL</span>
// <span class="count">N</span></div>`). The SPEC defines a 28px panel
// header *strip* — uppercase label on the left, optional count or
// arbitrary tail content right-aligned, and a hairline border-bottom
// that visually separates the head from the body of a card / panel.
//
// Distinct from existing dashboard primitives:
//
//   SectionCap     (common/section-cap.ts)    — pure label *style*,
//     no surface, no flex layout. Caller owns layout.
//   SectionHeader  (common/section-header.ts) — flex container with
//     a heading + right slot, but NO border-bottom, NO bg-surface,
//     NO 28px min-height. Closer to SPEC than SectionCap but still
//     not the strip surface SPEC defines.
//   SectionHead    (THIS FILE)                — full SPEC: strip
//     surface (bg + border-bottom + min-height + padding) +
//     uppercase label + count/tail right slot.
//
// SPEC mapping (primitives.css `.section-head`):
//   min-height 28px, padding 0 12px, border-bottom 1px,
//   background var(--color-bg-surface), font-size 11px, weight 600,
//   letter-spacing 0.08em, uppercase, color var(--color-fg-muted).
//   Right slot via `.count` (tabular-nums, fg-disabled) or `.tail`
//   (flex container) — both push to right with margin-left:auto.
//
// Why a new primitive instead of upgrading SectionHeader: SectionHeader
// has 9+ callers that read its current visual contract (no surface).
// Adding strip styling there would visually mutate every caller in a
// single change. New atom + opt-in adoption is safer; legacy callers
// migrate incrementally.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

export interface SectionHeadProps {
  /** The label text. Rendered uppercase via the SPEC font rule. */
  children: ComponentChildren
  /** Right-side count, formatted as a string. Rendered with
   *  tabular-nums + fg-disabled tone (SPEC `.count` rule). */
  count?: string | number
  /** Arbitrary right-aligned content (Pill, Chip, button row).
   *  Mutually compatible with `count` — both render in the same
   *  right-flex container, count first then tail children. */
  tail?: ComponentChildren
  /** Drop the bottom hairline (e.g. when the head sits above a
   *  custom divider or another strip). Default false. */
  noBorder?: boolean
  /** Forwarded to data-testid on the host. */
  testId?: string
  /** Override the auto aria-label. By default the host emits no
   *  aria — the heading text is read directly. */
  ariaLabel?: string
}


export function SectionHead(props: SectionHeadProps): VNode {
  const noBorder = props.noBorder === true

  const containerStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    minHeight: '28px',
    padding: '0 12px',
    // Longhand instead of `borderBottom` shorthand — happy-dom mis-
    // parses `border-bottom: 1px solid var(--token)` and splits the
    // var() across all three sub-properties (width/style/color), so
    // the rule never applies. Longhand is unambiguous.
    borderBottomWidth: noBorder ? '0' : '1px',
    borderBottomStyle: noBorder ? 'none' : 'solid',
    borderBottomColor: noBorder ? 'transparent' : 'var(--color-border-default)',
    background: 'var(--color-bg-surface)',
    fontSize: 'var(--fs-11)',
    fontWeight: 600,
    letterSpacing: '0.08em',
    textTransform: 'uppercase' as const,
    color: 'var(--color-fg-muted)',
    flexShrink: 0,
  }

  const labelStyle = {
    flexShrink: 0,
  }

  const countStyle = {
    marginLeft: 'auto',
    fontFamily: MONO_STACK,
    color: 'var(--color-fg-disabled)',
    fontWeight: 500,
    fontVariantNumeric: 'tabular-nums' as const,
  }

  const tailStyle = {
    marginLeft: props.count != null ? '8px' : 'auto',
    display: 'inline-flex',
    gap: '4px',
    alignItems: 'center',
  }

  return html`
    <div
      data-testid=${props.testId}
      aria-label=${props.ariaLabel}
      style=${containerStyle}
    >
      <span style=${labelStyle}>${props.children}</span>
      ${props.count != null
        ? html`<span data-section-head-count style=${countStyle}>${props.count}</span>`
        : null}
      ${props.tail != null
        ? html`<span data-section-head-tail style=${tailStyle}>${props.tail}</span>`
        : null}
    </div>
  `
}
