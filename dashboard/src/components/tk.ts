// Tk — atomic primitive ported from design-system v0.4 primitives.html
// (`<code class="tk">value</code>`). The SPEC defines an *inline mono
// highlight* — a small mono-font chunk on a tinted background, used
// to mark identifier-shaped tokens inside running prose: env var
// names, file paths, agent ids, error codes, command flags. Reads
// like inline code in technical writing.
//
// Why a new atom: dashboard scatters 27+ inline `<code>` callsites
// across 4+ drifting class compositions:
//
//   <code class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-1">                — connector-{status,keeper-matrix}
//   <code class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-1 py-0.5 text-2xs ...">    — goals/goal-tree, task-create-form
//   <code class="text-3xs text-[var(--color-fg-muted)]">           — safe-autonomy (no bg)
//   <code class="text-xs font-mono text-[var(--color-fg-secondary)]"> — server-config
//
// Every one is the same intent (inline mono highlight) shaped by
// inconsistent token / spacing combos. Tk consolidates them.
//
// Distinct from sibling primitives:
//
//   CopyableCode  — full-block command snippet + copy button
//                   (Vercel "Deploy" pattern). Block, not inline.
//   Kbd           — keyboard shortcut indicator.  Different shape
//                   (3D-ish key cap), different intent (input hint).
//   Chip / Pill   — semantic state labels.  Tk has no state, just
//                   "this string is technical content".
//
// SPEC mapping (primitives.css `.tk`):
//   font-family    var(--font-mono)
//   font-size      0.92em (relative — sits in surrounding prose)
//   padding        0 4px
//   border-radius  2px
//   background     var(--color-bg-elevated)
//   color          var(--color-fg-primary)
//   .tk.is-brass   accent-fg + 0.08 accent-glow bg
//   .tk.is-err     err fg + 0.08 err-glow bg

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

export type TkKind = 'default' | 'brass' | 'err'

export interface TkProps {
  /** The token / identifier / path / code fragment to render. */
  children: ComponentChildren
  /** Tone. SPEC has default + `is-brass` + `is-err`. Other status
   *  kinds (warn / info / stalled) are not in SPEC for `.tk` —
   *  callers wanting those should use Surf or Chip. */
  kind?: TkKind
  /** Override the rendered tag. Default `code` (semantic match). Use
   *  `span` when the surrounding context is itself inside `<code>` /
   *  `<pre>` and nesting would be invalid. */
  as?: 'code' | 'span'
  /** Forwarded to data-testid. */
  testId?: string
  /** Optional native `title` for hover tooltips (e.g. "click to copy"
   *  hint when used inside an interactive parent). The primitive
   *  itself is non-interactive — caller wraps in <button> if needed. */
  title?: string
}

interface KindStyle {
  color: string
  background: string
}

const KIND_STYLE: Record<TkKind, KindStyle> = {
  default: {
    color: 'var(--color-fg-primary)',
    background: 'var(--color-bg-elevated)',
  },
  brass: {
    color: 'var(--color-accent-fg)',
    // glow channel + alpha — same SPEC `rgb(var(--color-accent-glow) / 0.08)`
    background: 'rgb(var(--color-accent-glow) / 0.08)',
  },
  err: {
    color: 'var(--color-status-err)',
    background: 'rgb(var(--color-status-err-glow) / 0.08)',
  },
}


export function Tk(props: TkProps): VNode {
  const kind = props.kind ?? 'default'
  const ks = KIND_STYLE[kind]
  const tag = props.as ?? 'code'

  const style = {
    fontFamily: MONO_STACK,
    fontSize: '0.92em',
    padding: '0 4px',
    borderRadius: '2px',
    background: ks.background,
    color: ks.color,
    // Inline content — the primitive shouldn't introduce its own
    // line break behaviour, but should clip overflow on extreme
    // values so a 2KB path doesn't blow up the row.
    whiteSpace: 'nowrap' as const,
    overflow: 'hidden' as const,
    textOverflow: 'ellipsis' as const,
    verticalAlign: 'baseline' as const,
    maxWidth: '100%',
  }

  // htm/preact tag interpolation via a string variable: render via two
  // branches because htm parses tag names statically at the call site.
  if (tag === 'span') {
    return html`<span
      data-testid=${props.testId}
      data-kind=${kind}
      data-tk
      title=${props.title}
      style=${style}
    >${props.children}</span>`
  }
  return html`<code
    data-testid=${props.testId}
    data-kind=${kind}
    data-tk
    title=${props.title}
    style=${style}
  >${props.children}</code>`
}
