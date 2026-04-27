// Sep — atomic primitive ported from design-system v0.4 primitives.html
// (SPEC `.sep-v` / `.sep-h`). Two orientations:
//
//   sep-v  — 1px wide × 16px tall vertical bar with 8px horizontal
//            margin. Drops between inline siblings inside a flex row
//            (keyboard shortcut hint groups, action button clusters,
//            breadcrumb separators).
//   sep-h  — 1px tall horizontal hairline with 8px vertical margin.
//            Drops between block siblings inside a stacked card or
//            list (between two paragraph blocks, between a description
//            and an action row).
//
// Distinct from sibling primitives:
//
//   Band (band.ts)        — 2px decorative state strip at top of a
//                            card. Carries kind tone, never neutral.
//                            Sep is *neutral*, no kind, no state.
//   Bar (bar.ts)          — 4px progress fill. Conveys quantity, not
//                            adjacency.
//   Tailwind `divide-y`   — between-children divider applied via
//                            parent. Different mechanism (no element
//                            in the DOM, can't carry margin/spacing
//                            independently). Sep is a *self-contained
//                            element* between two adjacent siblings.
//
// Why a new atom even though dashboard has no current `w-px h-N`
// callsites: Sep is a foundational SSOT for the inline-divider intent.
// Future atoms (key-cap groups, breadcrumb rows, stat-row separators)
// will need this primitive — introducing it now lets follow-up sweeps
// reach for `<Sep />` instead of inventing yet another `w-px h-3
// bg-[var(--color-border-strong)]` chain.
//
// SPEC mapping (primitives.css `.sep-v` / `.sep-h`):
//   .sep-v  width 1px, height 16px, bg --color-border-strong,
//           margin 0 var(--sp-2)
//   .sep-h  height 1px, bg --color-border-default,
//           margin var(--sp-2) 0

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export interface SepProps {
  /** Orientation. `vertical` = 1px wide × 16px tall (inline row).
   *  `horizontal` = 1px tall (block stack). Default `horizontal`. */
  orientation?: 'horizontal' | 'vertical'
  /** Tone. SPEC defines border-strong for vertical, border-default
   *  for horizontal — preserved as the per-orientation default. Use
   *  `strong` to force the heavier tone on a horizontal sep, or vice
   *  versa, when adjacent context calls for it. */
  tone?: 'default' | 'strong'
  /** Drop the SPEC margin (8px on the cross axis). Use when the
   *  parent layout already provides the gap (flex-gap / space-y-N) or
   *  when the separator should hug its siblings. Default false. */
  noMargin?: boolean
  /** Forwarded to data-testid. */
  testId?: string
}

export function Sep(props: SepProps): VNode {
  const orientation = props.orientation ?? 'horizontal'
  const tone = props.tone ?? 'default'

  // SPEC defaults:
  //   vertical → border-strong (inline rows want a heavier tone so
  //              the eye can resolve the boundary between dense
  //              sibling clusters)
  //   horizontal → border-default (block stacks already have generous
  //                whitespace; a softer tone reads as "section break")
  const defaultColor = orientation === 'vertical'
    ? 'var(--color-border-strong)'
    : 'var(--color-border-default)'
  const strongColor = 'var(--color-border-strong)'
  const background = tone === 'strong' ? strongColor : defaultColor

  const isVertical = orientation === 'vertical'
  const margin = props.noMargin === true
    ? '0'
    : isVertical ? '0 8px' : '8px 0'

  const style = isVertical
    ? {
        display: 'inline-block',
        width: '1px',
        height: '16px',
        background,
        margin,
        flexShrink: 0,
        verticalAlign: 'middle' as const,
      }
    : {
        display: 'block',
        height: '1px',
        width: '100%',
        background,
        margin,
      }

  return html`
    <div
      role="separator"
      aria-orientation=${orientation}
      data-testid=${props.testId}
      data-orientation=${orientation}
      data-tone=${tone}
      style=${style}
    ></div>
  `
}
