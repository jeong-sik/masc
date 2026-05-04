// Surf — atomic primitive ported from design-system v0.4 primitives.html
// (`<div class="surf-{kind}">…</div>`). The SPEC defines a "soft tinted
// surface" — bg + border + fg color tuple — used wherever a card/row/
// banner needs to read as a status without being a status badge. SPEC
// kinds: ok / warn / err / info / stalled / brass / idle.
//
// Why a new atom: dashboard duplicates this pattern across the
// codebase with drifting hardcoded values:
//
//   keeper-chat-panel.ts  rgba(239,68,68,0.24) + rgba(127,29,29,0.24)
//                          — SPEC surf-err reconstructed from rgba
//                          literals.
//   auth-status RemoteWarningBanner  bg-[var(--warn-10)] +
//                          border-[var(--warn-20)] —
//                          SPEC surf-warn reconstructed from token
//                          subset.
//   handoff-timeline / excuse-patterns / harness-health / keeper-tool-
//   telemetry  text-only `text-[var(--bad-light)]` — *no surface*.
//
// Surf consolidates these into a single SSOT atom. The SPEC calls for
// kind-specific tokens (--{kind}-soft / --{kind}-border / --{kind}-fg)
// that dashboard partially defines (--ok-soft / --warn-soft only). To
// avoid blocking on the missing tokens, this primitive renders through
// the *-glow channels added in #11163 + alpha composition:
//
//   background: rgb(var(--color-status-{kind}-glow) / 0.12)
//   border:     1px solid rgb(var(--color-status-{kind}-glow) / 0.35)
//   color:      var(--color-status-{kind})
//
// Visual fidelity ~90% of SPEC: the kind hue carries through bg /
// border / fg in the same proportions as `.surf-{kind}`, only the
// alpha values differ slightly from SPEC's per-kind soft/border/fg
// tokens. A future cycle that adds the SPEC tokens directly (closing
// the soft/border/fg gap) can swap KIND_STYLE to those without
// touching any callsite.
//
// Distinct from sibling primitives:
//
//   Chip (chip.ts)   — small inline label with the same kind tones.
//                      Surf is a *block surface*, not a chip.
//   Pill (pill.ts)   — stateful capsule. Surf is *static*, not a state
//                      transition surface.
//   Band (band.ts)   — 2px decorative strip at top of a card. Surf is
//                      a *body surface*, not a strip.
//   ErrorPanel       — modal-like dropdown. Surf is *inline*, not
//                      overlay.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'

export type SurfKind =
  | 'ok'
  | 'warn'
  | 'err'
  | 'info'
  | 'stalled'
  | 'brass'

export interface SurfProps {
  /** State tone. SPEC supports `idle` too (border-strong + fg-muted)
   *  but Surf treats idle as "no surface needed" — callers should drop
   *  the wrapper rather than render a Surf with kind=idle. */
  kind: SurfKind
  /** Children — banner copy, alert message, status row body. */
  children: ComponentChildren
  /** Optional native `role` for assistive tech. Common: "alert" for
   *  attention-grabbing surfaces, "status" for low-priority updates,
   *  undefined for purely decorative bg. */
  role?: 'alert' | 'status'
  /** Override the default 12px padding. Some callers want a tighter
   *  inline strip (auth banner) or a roomier card body (chat error). */
  padding?: 'tight' | 'default' | 'loose'
  /** Drop the rounded-[var(--r-1)] corner — used when Surf sits inside a parent
   *  that already provides the radius (e.g. inside a Card). */
  flat?: boolean
  /** Forwarded to data-testid. */
  testId?: string
  /** Extra style overrides (margin, custom inline tweaks). The
   *  primitive owns bg/border/color — caller should NOT override
   *  those, only layout-adjacent properties. */
  class?: string
}

interface KindStyle {
  background: string
  borderColor: string
  color: string
}

const KIND_STYLE: Record<SurfKind, KindStyle> = {
  ok: {
    background: 'rgb(var(--color-status-ok-glow) / 0.12)',
    borderColor: 'rgb(var(--color-status-ok-glow) / 0.35)',
    color: 'var(--color-status-ok)',
  },
  warn: {
    background: 'rgb(var(--color-status-warn-glow) / 0.12)',
    borderColor: 'rgb(var(--color-status-warn-glow) / 0.35)',
    color: 'var(--color-status-warn)',
  },
  err: {
    background: 'rgb(var(--color-status-err-glow) / 0.12)',
    borderColor: 'rgb(var(--color-status-err-glow) / 0.35)',
    color: 'var(--color-status-err)',
  },
  info: {
    background: 'rgb(var(--color-status-info-glow) / 0.12)',
    borderColor: 'rgb(var(--color-status-info-glow) / 0.35)',
    color: 'var(--color-status-info)',
  },
  stalled: {
    background: 'rgb(var(--color-status-stalled-glow) / 0.12)',
    borderColor: 'rgb(var(--color-status-stalled-glow) / 0.35)',
    color: 'var(--color-status-stalled)',
  },
  brass: {
    background: 'rgb(var(--color-accent-glow) / 0.12)',
    borderColor: 'rgb(var(--color-accent-glow) / 0.35)',
    color: 'var(--color-accent-fg)',
  },
}

const PADDING_BY_VARIANT = {
  tight: '8px 12px',
  default: '12px 16px',
  loose: '16px 20px',
}

export function Surf(props: SurfProps): VNode {
  const ks = KIND_STYLE[props.kind]
  const padding = PADDING_BY_VARIANT[props.padding ?? 'default']

  const surfStyle = {
    background: ks.background,
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: ks.borderColor,
    color: ks.color,
    borderRadius: props.flat === true ? '0' : 'var(--r-2)',
    padding,
  }

  return html`
    <div
      role=${props.role}
      data-testid=${props.testId}
      data-kind=${props.kind}
      class=${props.class}
      style=${surfStyle}
    >
      ${props.children}
    </div>
  `
}
