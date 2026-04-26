// Kbd — keyboard-shortcut pill. The <kbd> element with consistent styling.
//
// Reference UIs (GitHub command palette hint, Linear shortcut menu,
// Vercel keyboard help sheet, Notion / Stripe tooltip chips): keyboard
// shortcuts should render as small beveled-edge pills so the reader
// instantly recognizes "this is a key to press", not inline prose. A
// single primitive keeps every kbd pill in the dashboard pixel-perfect
// identical — the alternative (inline Tailwind strings scattered across
// 4 call sites) always drifts within weeks.
//
// Two sizes for the two usage contexts we already have in the repo:
//  - `md` (default) — shortcut-sheet rows, inline hints beside actions.
//                     16-18px tall pill, matches 13px body text baseline.
//  - `sm`           — dense inline hints (\"press ?\" micro-badge, status
//                     bar). Same 10px text as `md` (P5 density sweep
//                     upgraded `sm` from 9px → 10px for legibility),
//                     but tighter padding (px-1 py-0 vs px-1.5 py-px).

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type KbdSize = 'sm' | 'md'

const BASE = 'inline-flex items-center justify-center rounded border font-mono text-center'

/** Pure: class string for a given size. Exposed so callers that wrap
    their own `<kbd>` (e.g. a native `<kbd>` inside a `<details>` without
    mounting the component) stay visually consistent. */
export function kbdClasses(size: KbdSize = 'md', extra?: string): string {
  const sized =
    size === 'sm'
      ? 'text-3xs px-1 py-0 border-[var(--white-10)] bg-[var(--white-3)] text-[var(--color-fg-disabled)]'
      : 'text-3xs px-1.5 py-px border-[var(--white-10)] bg-[var(--color-bg-page)] text-[var(--color-fg-primary)]'
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
