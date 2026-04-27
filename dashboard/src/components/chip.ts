// Chip — atomic primitive ported from design-system v0.4 primitives.html
// (`<span class="chip is-{kind}">…</span>`). The SPEC defines 8 kinds ×
// 3 sizes + a leading dot variant; this implementation matches the
// public API but renders via inline style + Tailwind tokens that the
// dashboard already owns.
//
// SPEC fidelity: matches design-system/source_styles/primitives.css
// `.chip.is-{kind}` selectors for the five status kinds (ok/warn/err/
// info/stalled) — translucent kind-tinted borders at 0.35 alpha +
// backgrounds at 0.08 alpha.  Ghost stays transparent and neutral
// keeps the elevated surface (SPEC: ghost is chromeless, neutral has
// no semantic kind to tint).  Brass currently keeps the elevated
// background — its SPEC translucent form depends on
// --color-accent-glow being a triplet, which is an in-flight change
// in PR-Pill-Fidelity (#11171).  Brass will swap in a follow-up.
//
// Token dependencies (added by PR-DS-Glow / #11163):
//   --color-status-{ok,warn,err,info,stalled}-glow   rgb-triplets
// The dashboard runtime triplets decompose the bright Tailwind-400/500
// semantic colors; SPEC source tokens.css uses muted hues but the
// dashboard prefers visual consistency with the live surface.
//
// Usage: `<${Chip} kind="ok" dot>${count} PASS<//>`. The host DOM is a
// span with role="status" when a kind is present (so screen readers
// announce status updates), no role otherwise.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'

export type ChipKind =
  | 'neutral'
  | 'brass'
  | 'ok'
  | 'warn'
  | 'err'
  | 'info'
  | 'stalled'
  | 'ghost'

export type ChipSize = 'sm' | 'default' | 'lg'

export interface ChipProps {
  children: ComponentChildren
  /** Tone. `undefined` ≡ `neutral`. `ghost` is a transparent variant. */
  kind?: ChipKind
  /** `sm` 14px / `default` 18px / `lg` 22px. */
  size?: ChipSize
  /** Render a 5px leading dot in the kind color. Auto-suppressed when
   *  `kind` is undefined / 'neutral' / 'ghost' (no semantic color to
   *  show). */
  dot?: boolean
  /** Forwarded to data-testid. */
  testId?: string
  /** Override the auto aria-label (kind + content). */
  ariaLabel?: string
  /** Optional native `title` attribute for hover tooltips. Surfaces
   *  forwarded since chips frequently anchor diagnostic context. */
  title?: string
}

interface KindStyle {
  color: string
  borderColor: string
  background: string
}

// Foreground / border / background tuples match SPEC primitives.css
// `.chip.is-{kind}` selectors (see header comment).  Status kinds get
// translucent borders at 0.35 alpha + backgrounds at 0.08 alpha;
// brass uses the dimmed accent border with a translucent accent
// background; ghost is transparent; neutral keeps the elevated
// surface because SPEC defines it as the baseline chromeless state.
const KIND_STYLE: Record<ChipKind, KindStyle> = {
  neutral: {
    color: 'var(--color-fg-secondary)',
    borderColor: 'var(--color-border-default)',
    background: 'var(--color-bg-elevated)',
  },
  brass: {
    color: 'var(--color-accent-fg)',
    borderColor: 'var(--color-accent-fg-dim)',
    // SPEC: rgb(var(--color-accent-glow) / 0.08) — but the runtime
    // --color-accent-glow alias is currently a hex form (var(--accent)),
    // not a triplet, so the rgb()/alpha math would not parse. PR-Pill-
    // Fidelity (#11171) repurposes the alias to a triplet; the brass
    // background will swap to translucent in a follow-up after that
    // dependency lands.
    background: 'var(--color-bg-elevated)',
  },
  ok: {
    color: 'var(--color-status-ok)',
    borderColor: 'rgb(var(--color-status-ok-glow) / 0.35)',
    background: 'rgb(var(--color-status-ok-glow) / 0.08)',
  },
  warn: {
    color: 'var(--color-status-warn)',
    borderColor: 'rgb(var(--color-status-warn-glow) / 0.35)',
    background: 'rgb(var(--color-status-warn-glow) / 0.08)',
  },
  err: {
    color: 'var(--color-status-err)',
    borderColor: 'rgb(var(--color-status-err-glow) / 0.35)',
    background: 'rgb(var(--color-status-err-glow) / 0.08)',
  },
  info: {
    color: 'var(--color-status-info)',
    borderColor: 'rgb(var(--color-status-info-glow) / 0.35)',
    background: 'rgb(var(--color-status-info-glow) / 0.08)',
  },
  stalled: {
    color: 'var(--color-status-stalled)',
    borderColor: 'rgb(var(--color-status-stalled-glow) / 0.35)',
    background: 'rgb(var(--color-status-stalled-glow) / 0.08)',
  },
  ghost: {
    color: 'var(--color-fg-disabled)',
    borderColor: 'var(--color-border-strong)',
    background: 'transparent',
  },
}

interface SizeStyle {
  height: string
  padding: string
  fontSize: string
}

const SIZE_STYLE: Record<ChipSize, SizeStyle> = {
  sm: { height: '14px', padding: '0 5px', fontSize: '9px' },
  default: { height: '18px', padding: '0 7px', fontSize: '10px' },
  lg: { height: '22px', padding: '0 9px', fontSize: '11px' },
}

const MONO_STACK =
  'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'

const KIND_ANNOUNCE: Record<Exclude<ChipKind, 'neutral' | 'ghost'>, string> = {
  brass: 'highlighted',
  ok: 'passing',
  warn: 'warning',
  err: 'failing',
  info: 'info',
  stalled: 'stalled',
}

/** Pure: assemble the screen-reader label. Exported for tests + for
 *  callers that want to wire their own aria-label outside the host. */
export function chipAriaLabel(props: ChipProps, content: string): string {
  if (props.ariaLabel) return props.ariaLabel
  const kind = props.kind
  if (kind && kind in KIND_ANNOUNCE) {
    return `${content} (${KIND_ANNOUNCE[kind as keyof typeof KIND_ANNOUNCE]})`
  }
  return content
}

function plainText(children: ComponentChildren): string {
  // Best-effort flattening for the aria-label. Component children that
  // aren't strings/numbers fall back to '' (the visible chip still
  // shows them; aria-label just loses non-text branches).
  if (children == null) return ''
  if (typeof children === 'string') return children
  if (typeof children === 'number') return String(children)
  if (Array.isArray(children)) return children.map(plainText).join('')
  return ''
}

export function Chip(props: ChipProps): VNode {
  const kind = props.kind ?? 'neutral'
  const size = props.size ?? 'default'
  const ks = KIND_STYLE[kind]
  const ss = SIZE_STYLE[size]

  const showDot =
    props.dot === true && kind !== 'neutral' && kind !== 'ghost'

  const containerStyle = {
    display: 'inline-flex',
    alignItems: 'center',
    gap: '4px',
    height: ss.height,
    padding: ss.padding,
    fontFamily: MONO_STACK,
    fontSize: ss.fontSize,
    lineHeight: 1,
    color: ks.color,
    border: `1px solid ${ks.borderColor}`,
    background: ks.background,
    borderRadius: '2px',
    letterSpacing: '0.04em',
    textTransform: 'uppercase' as const,
    fontWeight: 500,
    whiteSpace: 'nowrap' as const,
  }

  const dotStyle = {
    display: 'inline-block',
    width: '5px',
    height: '5px',
    borderRadius: '50%',
    background: ks.color,
    flexShrink: 0,
  }

  const announce = chipAriaLabel(props, plainText(props.children))
  const role = kind !== 'neutral' && kind !== 'ghost' ? 'status' : undefined

  return html`
    <span
      role=${role}
      data-testid=${props.testId}
      data-kind=${kind}
      data-size=${size}
      title=${props.title}
      aria-label=${announce}
      style=${containerStyle}
    >
      ${showDot ? html`<span aria-hidden="true" style=${dotStyle}></span>` : null}
      ${props.children}
    </span>
  `
}
