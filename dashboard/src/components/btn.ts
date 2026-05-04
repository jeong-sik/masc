// Btn — atomic primitive ported from design-system v0.4 primitives.html
// (`<button class="btn ...">…</button>`). The SPEC defines a base button
// (warm border, transparent surface) plus three semantic variants
// (primary / danger / ghost), four sizes (xs / sm / default / lg), and
// an `icon` square modifier. Distinct from Chip / Pill (display-only):
// Btn is the canonical *interactive* element — keyboard focusable,
// click-dispatching, hover-transition.
//
// SPEC fidelity: matches design-system/source_styles/primitives.css
// `.btn.{primary,danger,ghost}` and `.btn.{xs,sm,lg,icon}` selectors,
// and the `button, .btn` base in tokens.css line 467. The dashboard
// runtime does not import the design-system CSS files (Preact owns its
// styles via styles/), so this primitive translates the SPEC's
// `.btn` rules into inline style + the runtime semantic tokens defined
// by styles/variables.css. Same fidelity contract as chip.ts / pill.ts.
//
// Token dependencies (all in dashboard/src/styles/variables.css):
//   --color-fg-{primary,secondary,muted}
//   --color-bg-{page,panel-alt,elevated}
//   --color-border-default
//   --color-accent-fg / --color-accent-fg-dim
//   --color-status-err / --color-status-err-glow (rgb-triplet)
//
// Usage: `<${Btn} variant="primary" size="sm" onClick=${handler}>SAVE<//>`
// — host DOM is `<button type="button">` by default. `type="submit"` is
// preserved when explicitly passed (forms).
//
// Hover transition is handled inline (Preact useState + mouseenter/leave)
// since SPEC defines the transition declaratively; focus-visible relies
// on the browser default until atom 13/14 (Focus ring) lands.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { ComponentChildren, JSX, VNode } from 'preact'

export type BtnVariant = 'primary' | 'danger' | 'ghost'
export type BtnSize = 'xs' | 'sm' | 'default' | 'lg'

type ResolvedVariant = 'default' | BtnVariant

export interface BtnProps {
  children?: ComponentChildren
  /** Semantic tone. `undefined` ≡ default (warm-bordered base). */
  variant?: BtnVariant
  /** `xs` 18px / `sm` 20px / `default` 24px / `lg` 28px. */
  size?: BtnSize
  /** Square 22×22 icon-only button. Overrides `size` geometry, keeps
   *  `size`-derived font-size for the glyph. */
  icon?: boolean
  /** Native disabled state. Pointer cursor swaps to not-allowed and the
   *  surface drops to 50% opacity. */
  disabled?: boolean
  /** Native button type. Defaults to `button` (does not submit forms). */
  type?: 'button' | 'submit' | 'reset'
  /** Click handler forwarded to the underlying `<button>`. */
  onClick?: JSX.MouseEventHandler<HTMLButtonElement>
  /** Forwarded to data-testid for E2E selectors. */
  testId?: string
  /** Override for screen-reader label. Required for `icon` buttons that
   *  render only a glyph (no readable child text). */
  ariaLabel?: string
  /** Optional native `title` attribute for hover tooltips. */
  title?: string
  /** Extra class names appended verbatim. The atom does not need a class
   *  for its own styling (everything is inline) — this slot exists for
   *  callers that want layout utilities (e.g. `mt-2`, `flex-1`). */
  class?: string
}

interface VariantStyle {
  color: string
  borderColor: string
  background: string
  fontWeight?: number
  hover: { color: string; background: string; borderColor?: string }
}

// Foreground / border / background tuples match SPEC primitives.css
// `.btn.{primary,danger,ghost}` selectors plus the unstyled base.
// Hover state is read off the same SPEC `:hover` rules.
const VARIANT_STYLE: Record<ResolvedVariant, VariantStyle> = {
  default: {
    color: 'var(--color-fg-secondary)',
    borderColor: 'var(--color-border-default)',
    background: 'transparent',
    hover: {
      color: 'var(--color-fg-primary)',
      background: 'var(--color-bg-elevated)',
    },
  },
  primary: {
    color: 'var(--color-bg-page)',
    borderColor: 'var(--color-accent-fg-dim)',
    background: 'var(--color-accent-fg-dim)',
    fontWeight: 600,
    hover: {
      color: 'var(--color-bg-page)',
      background: 'var(--color-accent-fg)',
      borderColor: 'var(--color-accent-fg)',
    },
  },
  danger: {
    color: 'var(--color-status-err)',
    borderColor: 'rgb(var(--color-status-err-glow) / 0.4)',
    background: 'transparent',
    hover: {
      color: 'var(--color-status-err)',
      background: 'rgb(var(--color-status-err-glow) / 0.1)',
    },
  },
  ghost: {
    color: 'var(--color-fg-muted)',
    borderColor: 'transparent',
    background: 'transparent',
    hover: {
      color: 'var(--color-fg-primary)',
      background: 'var(--color-bg-panel-alt)',
    },
  },
}

interface SizeStyle {
  height: string
  padding: string
  fontSize: string
  letterSpacing?: string
}

// Sizes match SPEC primitives.css: xs (line 164), sm (163), default
// (tokens.css line 467 base — derived 24px height from `padding 4px 10px`
// + 11px font line-height), lg (line 165 — added by this PR, fs-12 paired
// with the 28px geometry inferred from the xs(18)→sm(20)→default(24)→
// lg(28) +2px progression that primitives.html demos).
const SIZE_STYLE: Record<BtnSize, SizeStyle> = {
  xs: { height: 'var(--ctrl-h-xs)', padding: '0 6px', fontSize: 'var(--fs-9)', letterSpacing: '0.06em' },
  sm: { height: 'var(--ctrl-h-sm)', padding: '0 8px', fontSize: 'var(--fs-10)' },
  default: { height: 'var(--ctrl-h)', padding: '0 10px', fontSize: 'var(--fs-11)' },
  lg: { height: 'var(--ctrl-h-lg)', padding: '0 14px', fontSize: 'var(--fs-12)' },
}

const TRANSITION =
  `background var(--motion-swap) var(--ease), color var(--motion-swap) var(--ease), border-color var(--motion-swap) var(--ease)`

/** Pure: resolve the variant default. Exported for tests so the variant
 *  defaulting rule stays observable without a DOM mount. */
export function resolveVariant(variant: BtnVariant | undefined): ResolvedVariant {
  return variant ?? 'default'
}

export function Btn(props: BtnProps): VNode {
  const variant = resolveVariant(props.variant)
  const size = props.size ?? 'default'
  const vs = VARIANT_STYLE[variant]
  const ss = SIZE_STYLE[size]

  const [hovered, setHovered] = useState(false)
  const active = hovered && !props.disabled

  const color = active ? vs.hover.color : vs.color
  const background = active ? vs.hover.background : vs.background
  const borderColor =
    active && vs.hover.borderColor ? vs.hover.borderColor : vs.borderColor

  // Icon mode swaps the geometry to a 22×22 square but keeps the size-
  // derived font-size so the glyph (▸, ⌃, ⊘ etc.) scales with the chosen
  // size token rather than always rendering at 11px.
  const geometry: Pick<JSX.CSSProperties, 'width' | 'height' | 'padding'> =
    props.icon
      ? { width: '22px', height: '22px', padding: '0' }
      : { height: ss.height, padding: ss.padding }

  const style: JSX.CSSProperties = {
    display: 'inline-flex',
    alignItems: 'center',
    justifyContent: 'center',
    ...geometry,
    fontFamily: 'inherit',
    fontSize: ss.fontSize,
    fontWeight: vs.fontWeight,
    letterSpacing: ss.letterSpacing,
    color,
    background,
    border: `1px solid ${borderColor}`,
    borderRadius: 'var(--r-1)',
    cursor: props.disabled ? 'not-allowed' : 'pointer',
    opacity: props.disabled ? 0.5 : 1,
    transition: TRANSITION,
  }

  return html`
    <button
      type=${props.type ?? 'button'}
      class=${props.class}
      data-testid=${props.testId}
      data-variant=${variant}
      data-size=${size}
      data-icon=${props.icon ? 'true' : undefined}
      disabled=${props.disabled || undefined}
      aria-label=${props.ariaLabel}
      title=${props.title}
      style=${style}
      onClick=${props.onClick}
      onMouseEnter=${() => setHovered(true)}
      onMouseLeave=${() => setHovered(false)}
      onBlur=${() => setHovered(false)}
    >
      ${props.children}
    </button>
  `
}
