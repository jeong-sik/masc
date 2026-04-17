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
//                     bar). 11-12px tall, sits without pushing text lines.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export type KbdSize = 'sm' | 'md'

const BASE = 'inline-flex items-center justify-center rounded border font-mono text-center'

/** Pure: class string for a given size. Exposed so callers that wrap
    their own `<kbd>` (e.g. a native `<kbd>` inside a `<details>` without
    mounting the component) stay visually consistent. */
export function kbdClasses(size: KbdSize = 'md', extra?: string): string {
  const sized =
    size === 'sm'
      ? 'text-[9px] px-1 py-0 border-[var(--white-10)] bg-[var(--white-3)] text-[var(--text-dim)]'
      : 'text-[10px] px-1.5 py-[1px] border-[var(--white-10)] bg-[var(--bg-0)] text-[var(--text-body)]'
  return extra === undefined || extra === ''
    ? `${BASE} ${sized}`
    : `${BASE} ${sized} ${extra}`
}

export interface KbdProps {
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
