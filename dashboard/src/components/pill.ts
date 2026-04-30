// Pill — atomic primitive ported from design-system v0.4 primitives.html
// (`<span class="pill is-{kind}">…</span>`). The SPEC defines a 16px
// capsule with 8 stateful kinds (running/paused + ok/warn/err/info/
// stalled + neutral). Distinct from Chip (sharper 2px corners, used
// for static labels): Pill is for *stateful* surfaces — a thing whose
// state may transition (running → paused, ok → warn).
//
// SPEC fidelity: matches design-system/source_styles/primitives.css
// `.pill.is-{kind}` selectors. Translucent kind-tinted backgrounds at
// 0.12 alpha for the six stateful kinds (running + ok/warn/err/info/
// stalled); paused and neutral keep the flat elevated surface (SPEC:
// paused is a muted state with no chrome, neutral has no semantic
// kind to tint).
//
// Token dependencies (added by PR-DS-Glow / #11163 + this PR):
//   --color-status-{ok,warn,err,info,stalled}-glow   rgb-triplets
//   --color-accent-glow                               rgb-triplet
// The dashboard runtime triplets decompose the bright Tailwind-400/500
// semantic colors; SPEC source tokens.css uses muted hues but the
// dashboard prefers visual consistency with the live surface.
//
// Usage: `<${Pill} kind="running">RUNNING<//>` — the host DOM is a
// span with role="status" when a stateful kind is present (so screen
// readers announce state changes), no role for neutral.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

export type PillKind =
  | 'neutral'
  | 'running'
  | 'paused'
  | 'ok'
  | 'warn'
  | 'err'
  | 'info'
  | 'stalled'

export interface PillProps {
  children: ComponentChildren
  /** State tone. `undefined` ≡ `neutral`. */
  kind?: PillKind
  /** Render a 5px leading dot in the kind color. Auto-suppressed when
   *  kind is undefined or 'neutral' (no semantic state to flag). */
  dot?: boolean
  /** Forwarded to data-testid. */
  testId?: string
  /** Override the auto aria-label. */
  ariaLabel?: string
  /** Optional native `title` attribute for hover tooltips. */
  title?: string
}

interface KindStyle {
  color: string
  background: string
}

// Foreground/background pairs match SPEC primitives.css `.pill.is-{kind}`
// selectors (see header comment).  Translucent kind-tinted backgrounds
// at 0.12 alpha; neutral and paused keep the elevated surface because
// the SPEC defines them as chromeless states.
const KIND_STYLE: Record<PillKind, KindStyle> = {
  neutral: {
    color: 'var(--color-fg-secondary)',
    background: 'var(--color-bg-elevated)',
  },
  running: {
    color: 'var(--color-accent-fg)',
    background: 'rgb(var(--color-accent-glow) / 0.12)',
  },
  paused: {
    color: 'var(--color-fg-muted)',
    background: 'var(--color-bg-elevated)',
  },
  ok: {
    color: 'var(--color-status-ok)',
    background: 'rgb(var(--color-status-ok-glow) / 0.12)',
  },
  warn: {
    color: 'var(--color-status-warn)',
    background: 'rgb(var(--color-status-warn-glow) / 0.12)',
  },
  err: {
    color: 'var(--color-status-err)',
    background: 'rgb(var(--color-status-err-glow) / 0.12)',
  },
  info: {
    color: 'var(--color-status-info)',
    background: 'rgb(var(--color-status-info-glow) / 0.12)',
  },
  stalled: {
    color: 'var(--color-status-stalled)',
    background: 'rgb(var(--color-status-stalled-glow) / 0.12)',
  },
}


const KIND_ANNOUNCE: Record<Exclude<PillKind, 'neutral'>, string> = {
  running: 'running',
  paused: 'paused',
  ok: 'ok',
  warn: 'warning',
  err: 'failing',
  info: 'info',
  stalled: 'stalled',
}

/** Pure: assemble the screen-reader label. Exported so callers can
 *  wire their own aria-label outside the host (e.g. a wrapper button). */
export function pillAriaLabel(props: PillProps, content: string): string {
  if (props.ariaLabel) return props.ariaLabel
  const kind = props.kind
  if (kind && kind !== 'neutral') {
    return `${content} (${KIND_ANNOUNCE[kind]})`
  }
  return content
}

function plainText(children: ComponentChildren): string {
  if (children == null) return ''
  if (typeof children === 'string') return children
  if (typeof children === 'number') return String(children)
  if (Array.isArray(children)) return children.map(plainText).join('')
  return ''
}

export function Pill(props: PillProps): VNode {
  const kind = props.kind ?? 'neutral'
  const ks = KIND_STYLE[kind]

  const showDot = props.dot === true && kind !== 'neutral'

  const containerStyle = {
    display: 'inline-flex',
    alignItems: 'center',
    gap: '4px',
    height: '16px',
    padding: '0 8px',
    fontFamily: MONO_STACK,
    fontSize: '10px',
    lineHeight: 1,
    color: ks.color,
    background: ks.background,
    borderRadius: '999px',
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

  const announce = pillAriaLabel(props, plainText(props.children))
  const role = kind !== 'neutral' ? 'status' : undefined

  return html`
    <span
      role=${role}
      data-testid=${props.testId}
      data-kind=${kind}
      title=${props.title}
      aria-label=${announce}
      style=${containerStyle}
    >
      ${showDot ? html`<span aria-hidden="true" style=${dotStyle}></span>` : null}
      ${props.children}
    </span>
  `
}
