// Elev — atomic primitive ported from design-system v0.4 primitives.html
// "Elevation" section (`<div class="elev-{N}">`). The SPEC defines a 7-
// step (0..6) elevation stack — each step bundles three surface fields
// (background + border + shadow). Step 0 is the page/inset surface
// (chromeless), steps 1..2 are resting panel and card, 3 is hovered
// card / selected row, 4..6 climb through floating menu / popover →
// drawer / sheet → modal overlay (the cap).
//
// SPEC fidelity: matches design-system/source_styles/tokens.css
// `--elev-{0..6}-{bg,border,shadow}` triples (lines 273-299) and
// primitives.css `.elev-{0..6}` selectors (lines 247-253). Same
// fidelity contract as chip.ts / pill.ts / btn.ts: dashboard runtime
// does not import design-system source CSS, so the atom translates
// the SPEC triples into inline style + the runtime semantic tokens
// from styles/variables.css. Shadow stacks come through verbatim
// because dashboard runtime has no shadow tier — the SPEC shadow
// values are baked into the atom as the SSOT.
//
// Token dependencies (all in dashboard/src/styles/variables.css):
//   --color-bg-page / -panel-alt / -elevated / -hover  (level surfaces)
//   --color-border-divider / -default / -strong         (level borders)
//
// Usage: `<${Elev} level=${2} class="rounded-xs p-4">…<//>` — host DOM
// is `<div>` by default. Layout (`display`, `padding`, `border-radius`)
// is the caller's responsibility — Elev owns surface only (bg + border
// + shadow), never geometry.
//
// Modals top out at 6 per SPEC (line 297-299 in tokens.css). Higher
// levels are rejected at the type tier (`ElevLevel` is 0..6 union).

import { html } from 'htm/preact'
import type { ComponentChildren, JSX, VNode } from 'preact'

export type ElevLevel = 0 | 1 | 2 | 3 | 4 | 5 | 6

export interface ElevProps {
  children?: ComponentChildren
  /** Elevation step. `undefined` ≡ level 0 (page / inset surface). */
  level?: ElevLevel
  /** Layout / geometry classes. Atom only owns surface tokens; padding,
   *  display, border-radius all flow through here. */
  class?: string
  /** Forwarded to data-testid for E2E selectors. */
  testId?: string
  /** ARIA role override. Default is no role (a plain surface div). */
  role?: string
  /** Override for screen-reader label. */
  ariaLabel?: string
}

interface LevelStyle {
  background: string
  border: string
  boxShadow: string
}

// Surface triples match SPEC tokens.css lines 273-299 (`--elev-N-*`).
// Background tokens map dashboard semantic surface tier to SPEC bg-N
// (page / panel / panel-alt / elevated / hover); shadow stacks are
// inlined verbatim because dashboard has no shadow scale equivalent.
// Border-color tokens map SPEC line-N (subtle / default / strong) to
// the dashboard `--color-border-*` semantic tier.
const LEVEL_STYLE: Record<ElevLevel, LevelStyle> = {
  // Page / inset — chromeless. Lives at SPEC bg-0.
  0: {
    background: 'var(--color-bg-page)',
    border: '1px solid transparent',
    boxShadow: 'none',
  },
  // Resting panel (sticky chrome). Single thin downward shadow.
  1: {
    background: 'var(--color-bg-panel-alt)',
    border: '1px solid var(--color-border-divider)',
    boxShadow: '0 1px 0 rgb(0 0 0 / 0.4)',
  },
  // Card / default section surface. Adds inner highlight.
  2: {
    background: 'var(--color-bg-elevated)',
    border: '1px solid var(--color-border-default)',
    boxShadow:
      '0 1px 0 rgb(0 0 0 / 0.4), inset 0 1px 0 rgb(255 255 255 / 0.02)',
  },
  // Hovered card / selected row. First step with real ambient shadow.
  3: {
    background: 'var(--color-bg-hover)',
    border: '1px solid var(--color-border-strong)',
    boxShadow:
      '0 2px 6px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 255 255 / 0.03)',
  },
  // Floating menu / popover. Outset ring for crisp edge over content.
  4: {
    background: 'var(--color-bg-hover)',
    border: '1px solid var(--color-border-strong)',
    boxShadow:
      '0 6px 18px rgb(0 0 0 / 0.55), 0 0 0 1px var(--color-border-strong), inset 0 1px 0 rgb(255 255 255 / 0.03)',
  },
  // Drawer / sheet. Long drop, brighter inner highlight.
  5: {
    background: 'var(--color-bg-hover)',
    border: '1px solid var(--color-border-strong)',
    boxShadow:
      '0 12px 32px rgb(0 0 0 / 0.6), 0 0 0 1px var(--color-border-strong), inset 0 1px 0 rgb(255 255 255 / 0.04)',
  },
  // Modal overlay — SPEC cap. Heaviest shadow, same chrome as drawer.
  6: {
    background: 'var(--color-bg-hover)',
    border: '1px solid var(--color-border-strong)',
    boxShadow:
      '0 24px 64px rgb(0 0 0 / 0.7), 0 0 0 1px var(--color-border-strong), inset 0 1px 0 rgb(255 255 255 / 0.04)',
  },
}

/** Pure: resolve the level default. Exported for tests so the
 *  defaulting rule stays observable without a DOM mount. */
export function resolveLevel(level: ElevLevel | undefined): ElevLevel {
  return level ?? 0
}

export function Elev(props: ElevProps): VNode {
  const level = resolveLevel(props.level)
  const ls = LEVEL_STYLE[level]

  const style: JSX.CSSProperties = {
    background: ls.background,
    border: ls.border,
    boxShadow: ls.boxShadow,
  }

  return html`
    <div
      class=${props.class}
      data-testid=${props.testId}
      data-elev=${String(level)}
      role=${props.role}
      aria-label=${props.ariaLabel}
      style=${style}
    >
      ${props.children}
    </div>
  `
}
