// Kbd — keyboard-shortcut pill. The <kbd> element with consistent styling.
//
// Atom 9/14 (design-system v0.4 SPEC alignment). Aligns Tailwind utility
// values with `dashboard/design-system/source_styles/primitives.css .kbd`
// so the keyboard primitive matches the rest of the cockpit token set.
//
// SPEC mapping (primitives.css `.kbd`, lines 174–183):
//   min-width        16px            → md: min-w-4
//   height           16px            → md: h-4
//   padding          0 4px           → px-1
//   font-family      var(--font-mono)→ font-mono
//   font-size        var(--fs-10)    → text-3xs (= --font-size-3xs = 10px)
//   color            var(--color-fg-muted)        → text-[var(--color-fg-muted)]
//   background       var(--color-bg-elevated)     → bg-[var(--color-bg-elevated)]
//   border           1px solid var(--color-border-strong)
//                                     → border border-[var(--color-border-strong)]
//   border-bottom-width 2px (chiclet) → border-b-2
//   border-radius    3px              → rounded-[var(--r-1)]-xs (--radius-xs token)
//
// Two sizes — SPEC defines md only; sm is a Tailwind-only tightening
// for inline contexts that don't need fixed 16×16 dimensions:
//  - `md` (default) — shortcut-sheet rows, inline hints beside actions.
//                     SPEC pixel-exact 16×16 chiclet.
//  - `sm`           — dense inline hints ("press ?" micro-badge, status
//                     bar). Same 10px text as `md`, tighter padding,
//                     no fixed dimensions, dimmed color.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type KbdSize = 'sm' | 'md'

const BASE =
  'inline-flex items-center justify-center rounded-xs border border-b-2 font-mono text-center text-3xs ' +
  'border-[var(--color-border-strong)] bg-[var(--color-bg-elevated)]'

/** Pure: class string for a given size. Exposed so callers that wrap
    their own `<kbd>` (e.g. a native `<kbd>` inside a `<details>` without
    mounting the component) stay visually consistent. */
export function kbdClasses(size: KbdSize = 'md', extra?: string): string {
  const sized =
    size === 'sm'
      ? 'px-1 py-0 text-[var(--color-fg-disabled)]'
      : 'h-4 min-w-4 px-1 text-[var(--color-fg-muted)]'
  return extra === undefined || extra === ''
    ? `${BASE} ${sized}`
    : `${BASE} ${sized} ${extra}`
}

interface KbdProps {
  /** Key label — e.g. "⌘K", "?", "1", "Ctrl+P". Supports multi-char
      strings because the primitive deliberately doesn't parse chords;
      callers that want auto-split key chords should compose several
      <Kbd> with a "+" separator between them (GitHub convention). */
  children?: ComponentChildren
  size?: KbdSize
  class?: string
  /** HTML title attribute — hover tooltip. Matches the existing
      `title="단축키 목록 (?)"` usage in fsm-hub.ts verbatim. */
  title?: string
  testId?: string
}

export function Kbd({
  children,
  size = 'md',
  class: cx,
  title,
  testId,
}: KbdProps) {
  const cls = kbdClasses(size, cx)
  return html`<kbd
    class=${cls}
    data-kbd
    data-kbd-size=${size}
    title=${title}
    data-testid=${testId}
  >${children}</kbd>`
}
