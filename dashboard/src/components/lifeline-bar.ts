// Lifeline bar — ECG-style heartbeat visualizer for fleet activity.
//
// Ported from design-system v0.4 cb-group-a (preview/cb-group-a.jsx
// LifelineBeat / LifelineStacked + cb-shared.jsx Heartbeat). Two
// primitives in one module:
//
//   Heartbeat   — atomic SVG polyline (decorative). Stateless: caller
//                 drives `phase` (0..1) from a setInterval / signal /
//                 data source. The trailing accent dot pulses on its
//                 own via SVG <animate>.
//
//   LifelineBar — composite tile: "LIFELINE" label + Heartbeat + BPM
//                 caption. Same surface treatment as KpiCell so a
//                 fleet status row can mix Kpi cells and a lifeline.
//
// The original css selectors (.cb-lifeline / .cb-board) are not in
// scope for the dashboard — re-implementation against the dashboard
// token set + htm/preact + Tailwind utility-only convention.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

const HEARTBEAT_SEGMENTS = 60
const HEARTBEAT_DEFAULT_WIDTH = 320
const HEARTBEAT_DEFAULT_HEIGHT = 32

/** Build the SVG polyline `points` string for an ECG-style heartbeat
 *  trace. Pure: same `(phase, width, height)` always yields the same
 *  string. Exposed for tests + for callers that want to drop the
 *  trace into their own `<svg>` (e.g. a stacked lifeline that arrays
 *  many traces in one viewBox). */
export function heartbeatPoints(
  phase: number,
  width: number = HEARTBEAT_DEFAULT_WIDTH,
  height: number = HEARTBEAT_DEFAULT_HEIGHT,
): string {
  const points: string[] = []
  for (let i = 0; i <= HEARTBEAT_SEGMENTS; i++) {
    const t = i / HEARTBEAT_SEGMENTS
    const x = t * width
    let y = height / 2 + Math.sin((t + phase) * 6) * 1.5
    const s = (i + Math.floor(phase * 60)) % 12
    if (s === 3) y -= height * 0.35
    if (s === 4) y += height * 0.4
    if (s === 5) y -= height * 0.15
    points.push(`${x.toFixed(1)},${y.toFixed(1)}`)
  }
  return points.join(' ')
}

export interface HeartbeatProps {
  /** 0..1 — animates the trace. Caller drives via setInterval / signal. */
  phase?: number
  width?: number
  height?: number
  /** Stroke + dot color. Defaults to the brass accent token. */
  color?: string
  /** Skip the trailing pulsing dot — use when the trace is meant to
   *  be a static snapshot, not a live indicator. */
  withoutPulseDot?: boolean
}

export function Heartbeat({
  phase = 0,
  width = HEARTBEAT_DEFAULT_WIDTH,
  height = HEARTBEAT_DEFAULT_HEIGHT,
  color = 'var(--color-accent-brass)',
  withoutPulseDot = false,
}: HeartbeatProps): VNode {
  const points = heartbeatPoints(phase, width, height)
  return html`
    <svg
      viewBox=${`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      aria-hidden="true"
      focusable="false"
      style=${{ width: `${width}px`, height: `${height}px`, display: 'block' }}
    >
      <polyline
        points=${points}
        fill="none"
        stroke=${color}
        stroke-width="1.2"
      />
      ${withoutPulseDot
        ? null
        : html`
            <circle cx=${width - 2} cy=${height / 2} r="2" fill=${color}>
              <animate attributeName="r" values="2;3.5;2" dur="1.4s" repeatCount="indefinite" />
            </circle>
          `}
    </svg>
  `
}


const surfaceStyle = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border-base)',
  borderRadius: '3px',
}

const labelStyle = {
  fontSize: 'var(--font-size-3xs)',
  color: 'var(--color-fg-disabled)',
  letterSpacing: '0.08em',
  textTransform: 'uppercase' as const,
  fontWeight: 600,
}

const captionStyle = {
  fontSize: 'var(--font-size-3xs)',
  color: 'var(--color-fg-muted)',
  letterSpacing: '0.06em',
  textTransform: 'uppercase' as const,
  fontWeight: 500,
}

export interface LifelineBarProps {
  /** Short slug rendered on the left, e.g. "LIFELINE". */
  label?: string
  /** 0..1 — driven by the caller. */
  phase?: number
  /** Display BPM number ("72"). When omitted, only the trace shows. */
  bpm?: number | string
  /** Window string rendered next to BPM ("60s"). */
  window?: string
  /** Heartbeat trace size. */
  width?: number
  height?: number
  /** Override the trace color — defaults to the brass accent token. */
  color?: string
  /** Optional aria-label for the bar (defaults to a composed sentence). */
  ariaLabel?: string
}

export function LifelineBar({
  label = 'LIFELINE',
  phase = 0,
  bpm,
  window = '60s',
  width = HEARTBEAT_DEFAULT_WIDTH,
  height = HEARTBEAT_DEFAULT_HEIGHT,
  color,
  ariaLabel,
}: LifelineBarProps): VNode {
  const composedLabel = ariaLabel
    ?? (bpm !== undefined
      ? `${label} heartbeat at ${bpm} BPM, ${window} window`
      : `${label} heartbeat, ${window} window`)

  return html`
    <div
      role="img"
      aria-label=${composedLabel}
      style=${{
        ...surfaceStyle,
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--spacing-group)',
        padding: `var(--spacing-element) var(--spacing-group)`,
        fontFamily: MONO_STACK,
      }}
    >
      <span aria-hidden="true" style=${labelStyle}>${label}</span>
      <${Heartbeat} phase=${phase} width=${width} height=${height} color=${color} />
      ${bpm !== undefined
        ? html`
            <span aria-hidden="true" style=${captionStyle}>
              <span style=${{
                color: 'var(--color-fg-primary)',
                fontWeight: 700,
                fontVariantNumeric: 'tabular-nums',
                marginRight: '4px',
              }}>${bpm}</span>
              BPM · ${window}
            </span>
          `
        : null}
    </div>
  `
}
