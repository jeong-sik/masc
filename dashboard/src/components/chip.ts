// Chip — atomic primitive ported from design-system v0.4 primitives.html
// (`<span class="chip is-{kind}">…</span>`). The SPEC defines 8 kinds ×
// 3 sizes + a leading dot variant; this implementation matches the
// public API but renders via inline style + Tailwind tokens that the
// dashboard already owns.
//
// Why not import design-system/source_styles/primitives.css directly:
// - The SPEC selectors expect raw status tokens (`--err`, `--info`,
//   `--stalled`, `--idle`) and `*-glow` channels that dashboard's
//   variables.css does not yet define. Importing primitives.css today
//   would render the chips unstyled or partially broken.
// - Visual fidelity here is ~75% of SPEC: foreground + border carry
//   the kind hue, but the SPEC's translucent glow background is
//   replaced with a flat surface. Public API is intentionally identical
//   so a future cycle can swap the internals to `<span class="chip
//   is-{kind}">` once the token gap is closed (issue tracked in PR
//   description).
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

// Foreground + border derived from dashboard tokens (see SPEC mapping
// note above). Background stays flat where SPEC would use a translucent
// glow — keeps chips readable while the glow tokens are still missing.
const KIND_STYLE: Record<ChipKind, KindStyle> = {
  neutral: {
    color: 'var(--color-fg-secondary)',
    borderColor: 'var(--color-border-default)',
    background: 'var(--color-bg-elevated)',
  },
  brass: {
    color: 'var(--color-accent-fg)',
    borderColor: 'var(--color-accent-fg-dim)',
    background: 'var(--color-bg-elevated)',
  },
  ok: {
    color: 'var(--color-status-ok)',
    borderColor: 'var(--color-status-ok)',
    background: 'var(--color-bg-elevated)',
  },
  warn: {
    color: 'var(--color-status-warn)',
    borderColor: 'var(--color-status-warn)',
    background: 'var(--color-bg-elevated)',
  },
  err: {
    color: 'var(--color-status-err)',
    borderColor: 'var(--color-status-err)',
    background: 'var(--color-bg-elevated)',
  },
  info: {
    color: 'var(--color-status-info)',
    borderColor: 'var(--color-status-info)',
    background: 'var(--color-bg-elevated)',
  },
  stalled: {
    color: 'var(--color-status-stalled)',
    borderColor: 'var(--color-status-stalled)',
    background: 'var(--color-bg-elevated)',
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
