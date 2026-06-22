// MASC v2 — primitive component library (ported from prototype primitives.jsx
// + messages.jsx identity leaves). These wrap the vendored v2.css classes
// (.dot2 / .sigil / .chip / .meter) and the converged inline-styled <Pill>.
// Visual identity is 1:1 with the prototype: tone tints come from the same
// design tokens (PILL_TONES), the sigil pulls its slot color from --kp{slot}.

import { html } from 'htm/preact'
import type { JSX } from 'preact'

export type PillTone = 'neutral' | 'ok' | 'warn' | 'bad' | 'volt' | 'info'
export type DotState = 'ok' | 'warn' | 'bad' | 'busy' | 'idle'

interface ToneSpec {
  readonly color: string
  readonly border: string
  readonly bg: string
}

// The converged badge palette — one table replaces the prototype's seven
// forked badge classes. color-mix keeps tints token-derived.
export const PILL_TONES: Readonly<Record<PillTone, ToneSpec>> = {
  neutral: { color: 'var(--text-mid)', border: 'var(--border-main)', bg: 'var(--bg-card)' },
  ok: { color: 'var(--status-ok)', border: 'color-mix(in oklab, var(--status-ok) 45%, transparent)', bg: 'color-mix(in oklab, var(--status-ok) 10%, var(--bg-card))' },
  warn: { color: 'var(--status-warn)', border: 'color-mix(in oklab, var(--status-warn) 45%, transparent)', bg: 'color-mix(in oklab, var(--status-warn) 9%, var(--bg-card))' },
  bad: { color: 'var(--status-bad)', border: 'color-mix(in oklab, var(--status-bad) 42%, transparent)', bg: 'color-mix(in oklab, var(--status-bad) 10%, var(--bg-card))' },
  volt: { color: 'var(--volt-strong)', border: 'var(--volt-dim)', bg: 'var(--volt-wash)' },
  info: { color: 'var(--info)', border: 'color-mix(in oklab, var(--info) 38%, transparent)', bg: 'color-mix(in oklab, var(--info) 9%, var(--bg-card))' },
}

/** Status pip — `.dot2` + tone + optional pulse. */
export function Dot({ state = 'idle', pulse = false }: { state?: DotState; pulse?: boolean }) {
  const cls = ['dot2']
  if (state && state !== 'idle') cls.push(state)
  if (pulse) cls.push('pulse')
  return html`<span class=${cls.join(' ')}></span>`
}

export interface PillProps {
  tone?: PillTone
  mono?: boolean
  dot?: boolean | DotState
  dotPulse?: boolean
  soft?: boolean
  count?: boolean
  title?: string
  style?: JSX.CSSProperties
  children?: unknown
}

/** The converged badge. Inline-styled (the prototype's Pill emits no stable
 * class) so the tone table is the single source of truth. */
export function Pill(props: PillProps) {
  const { tone = 'neutral', mono = false, dot = false, dotPulse = false, soft = false, count = false, title, style, children } = props
  const t = PILL_TONES[tone] ?? PILL_TONES.neutral
  const base: JSX.CSSProperties = {
    display: 'inline-flex',
    alignItems: 'center',
    gap: 6,
    fontFamily: mono ? 'var(--font-mono)' : 'var(--font-ui)',
    fontSize: count ? 10 : 11,
    fontWeight: count ? 600 : 400,
    letterSpacing: mono ? '0.04em' : '0.05em',
    lineHeight: 1.2,
    padding: count ? '1px 7px' : '4px 10px',
    borderRadius: 'var(--radius-pill)',
    border: '1px solid ' + t.border,
    color: t.color,
    background: soft ? 'transparent' : t.bg,
    whiteSpace: 'nowrap',
    ...style,
  }
  const dotState: DotState = dot === true ? (tone === 'neutral' ? 'idle' : (tone as DotState)) : (dot || 'idle')
  return html`
    <span style=${base} title=${title}>
      ${dot ? html`<${Dot} state=${dotState} pulse=${dotPulse} />` : null}
      ${children}
    </span>
  `
}

/** Count badge — numeric tally pill (former .att-count / .kp-att). */
export function CountBadge({ tone = 'bad', children }: { tone?: PillTone; children?: unknown }) {
  return html`<${Pill} tone=${tone} count mono>${children}</${Pill}>`
}

export interface SigilProps {
  slot?: number | string
  size?: number
  heartbeat?: boolean
  title?: string
  fontScale?: number
  children?: unknown
}

/** Slot-colored monogram identity — `.sigil` with --kc from --kp{slot}. */
export function Sigil({ slot = 1, size = 32, heartbeat = false, title, fontScale = 0.4, children }: SigilProps) {
  const kc = typeof slot === 'number' ? `var(--kp${slot})` : slot
  const style: JSX.CSSProperties = {
    // CSS custom property — typed via index escape (preact passes it through).
    ['--kc' as string]: kc,
    width: size,
    height: size,
    fontSize: Math.round(size * fontScale),
  }
  return html`<span class=${'sigil' + (heartbeat ? ' heartbeat' : '')} title=${title} aria-label=${title} style=${style}>${children}</span>`
}

/** Keeper identity badge: color slot + 2-letter sigil (keeper-badge.ts). */
export function SigilBadge({ slot, sigil, size = 18, beat = false, title }: { slot: number; sigil: string; size?: number; beat?: boolean; title?: string }) {
  return html`<${Sigil} slot=${slot} size=${size} heartbeat=${beat} title=${title} fontScale=${0.46}>${sigil}</${Sigil}>`
}

/** Status dot driven by the coarse run/pause/off status (messages.jsx). */
export function StatusDot({ status, pulse = false }: { status: string; pulse?: boolean }) {
  const state: DotState = status === 'run' ? 'ok' : status === 'pause' ? 'warn' : status === 'off' ? 'idle' : (status as DotState)
  return html`<${Dot} state=${state} pulse=${pulse} />`
}

/** Keeper's proposed next action chip (`.chip` + leading arrow). */
export function SuggestionChip({ pre = '→', onClick, children }: { pre?: string; onClick?: () => void; children?: unknown }) {
  return html`<button class="chip" onClick=${onClick}>${pre ? html`<span class="pre">${pre}</span>` : null}${children}</button>`
}

/** Linear meter (`.meter` + optional hot). */
export function Meter({ pct = 0, hot = false }: { pct?: number; hot?: boolean }) {
  return html`<div class=${'meter' + (hot ? ' hot' : '')}><span style=${{ width: Math.max(0, Math.min(100, pct)) + '%' }}></span></div>`
}
