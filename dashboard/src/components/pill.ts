// Pill — atomic primitive ported from design-system v0.4 primitives.html
// (`<span class="pill is-{kind}">…</span>`). The SPEC defines a 16px
// capsule with 8 stateful kinds (running/paused + ok/warn/err/info/
// stalled + neutral). Distinct from Chip (sharper 2px corners, used
// for static labels): Pill is for *stateful* surfaces — a thing whose
// state may transition (running → paused, ok → warn).
//
// Why not import design-system/source_styles/primitives.css directly:
// - SPEC selectors expect `--{ok,warn,err,info,stalled}-glow` channels
//   that dashboard's variables.css does not yet define. Importing
//   would render the tinted backgrounds unstyled.
// - Visual fidelity here is ~75% of SPEC: foreground hue carried; SPEC
//   translucent glow background replaced with a flat elevated surface.
//   Public API is intentionally identical so a future cycle can swap
//   the internals to `<span class="pill is-{kind}">` once the token
//   gap is closed.
//
// Usage: `<${Pill} kind="running">RUNNING<//>` — the host DOM is a
// span with role="status" when a stateful kind is present (so screen
// readers announce state changes), no role for neutral.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'

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

// Foreground derived from dashboard tokens (see SPEC mapping note
// above). Background stays flat-elevated where SPEC would use a
// tinted glow — keeps pills readable while glow tokens are missing.
const KIND_STYLE: Record<PillKind, KindStyle> = {
  neutral: {
    color: 'var(--color-fg-secondary)',
    background: 'var(--color-bg-elevated)',
  },
  running: {
    color: 'var(--color-accent-fg)',
    background: 'var(--color-bg-elevated)',
  },
  paused: {
    color: 'var(--color-fg-muted)',
    background: 'var(--color-bg-elevated)',
  },
  ok: {
    color: 'var(--color-status-ok)',
    background: 'var(--color-bg-elevated)',
  },
  warn: {
    color: 'var(--color-status-warn)',
    background: 'var(--color-bg-elevated)',
  },
  err: {
    color: 'var(--color-status-err)',
    background: 'var(--color-bg-elevated)',
  },
  info: {
    color: 'var(--color-status-info)',
    background: 'var(--color-bg-elevated)',
  },
  stalled: {
    color: 'var(--color-status-stalled)',
    background: 'var(--color-bg-elevated)',
  },
}

const MONO_STACK =
  'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'

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
