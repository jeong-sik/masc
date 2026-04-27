// Spark — atomic primitive ported from design-system v0.4
// primitives.html (`<span class="spark"><i style="height:N%"></i> × N
// </span>`). The SPEC defines a tiny bar-chart trend visualization:
// a row of 12-24 vertical bars 2px wide, gap 1px, container 16px tall,
// each bar's height encoding a value 0..100. The last bar brightens
// to the accent color to signal "now". Used inside KPI strips,
// section-head tails, and provider tables to give a metric a quick
// trend cue without spending a full chart-cell on it.
//
// Distinct from existing dashboard primitives:
//
//   Sparkline (common/sparkline.ts) — Grafana-style canvas area chart
//     (filled area + polyline + dot). Continuous numeric trend, AT
//     reads first→latest (min/max). Different visual genre.
//   HeartbeatStrip (common/heartbeat-strip.ts) — Uptime-Kuma row of
//     status bars (up/down/unknown). Categorical state, not numeric
//     trend. Bars are full-height; SPEC Spark bars vary by value.
//   Bar (this repo) — single 4px progress bar. Shows "how full" for
//     one value, not a series.
//
// SPEC mapping (primitives.css `.spark`):
//   .spark             — inline-flex, items-end, gap 1px, height 16px
//   .spark > i         — block, width 2px, min-height 1px,
//                         background var(--color-fg-muted) (default)
//   .spark.is-brass>i  — background var(--brass-2)
//   .spark.is-ok>i     — background var(--ok)
//   .spark.is-err>i    — background var(--err)
//   .spark.is-warn>i   — background var(--warn)
//   last bar           — accent fg + 3px glow shadow ("now" signal)

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export type SparkKind = 'default' | 'brass' | 'ok' | 'warn' | 'err'

export interface SparkProps {
  /** Series values, each clamped to [0, 100] on render. SPEC expects
   *  12–24 entries; fewer renders fewer bars (still readable), more
   *  renders all of them (container scrolls? — SPEC is fixed 16px so
   *  taller series simply use more horizontal space). */
  values: number[]
  /** Bar tone (last bar always uses accent regardless of kind). */
  kind?: SparkKind
  /** Suppress the "now" accent + glow on the last bar. Use when the
   *  series itself isn't time-ordered (e.g. histogram of a property
   *  distribution rather than a trend). Default false. */
  noNowAccent?: boolean
  /** Override the auto aria-label. Default mentions count + range. */
  ariaLabel?: string
  /** Mark as decorative — assistive tech skips it. Use when a numeric
   *  label sits adjacent and reading both would be redundant. */
  ariaHidden?: boolean
  /** Forwarded to data-testid. */
  testId?: string
}

const BAR_COLOR: Record<SparkKind, string> = {
  default: 'var(--color-fg-muted)',
  brass: 'var(--color-accent-fg-dim)',
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
}

/** Pure: clamp to [0, 100]. NaN → 0 so a malformed datum doesn't
 *  silently sink the entire row to display:none. */
export function sparkClamp(v: number): number {
  if (Number.isNaN(v)) return 0
  if (v < 0) return 0
  if (v > 100) return 100
  return v
}

/** Pure: compute the auto aria-label from the series. Mirrors the
 *  Sparkline (canvas) primitive's convention so callers can replace
 *  one with the other without retraining their AT users. */
export function sparkAriaLabel(values: number[]): string {
  if (values.length === 0) return 'Spark (no data)'
  let min = values[0]!
  let max = values[0]!
  for (const v of values) {
    if (v < min) min = v
    if (v > max) max = v
  }
  const fmt = (n: number) => Number.isInteger(n) ? String(n) : n.toFixed(1)
  return `Spark: ${values.length} samples, min ${fmt(min)}, max ${fmt(max)}, latest ${fmt(values[values.length - 1]!)}`
}

export function Spark(props: SparkProps): VNode {
  const kind = props.kind ?? 'default'
  const barColor = BAR_COLOR[kind]
  const lastIdx = props.values.length - 1

  const containerStyle = {
    display: 'inline-flex',
    alignItems: 'flex-end' as const,
    gap: '1px',
    height: '16px',
  }

  const label = props.ariaHidden === true
    ? undefined
    : (props.ariaLabel ?? sparkAriaLabel(props.values))

  const bars = props.values.map((raw, i) => {
    const v = sparkClamp(raw)
    const isLast = i === lastIdx && props.noNowAccent !== true
    const fg = isLast ? 'var(--color-accent-fg)' : barColor
    const shadow = isLast
      ? '0 0 3px rgb(var(--color-accent-glow, 71 184 255) / 0.5)'
      : undefined
    const barStyle = {
      display: 'block',
      width: '2px',
      minHeight: '1px',
      // Use percentage so the SPEC's value→height encoding is honored
      // independently of the host's fixed 16px container.
      height: `${v}%`,
      background: fg,
      borderRadius: '1px',
      boxShadow: shadow,
    }
    return html`<i aria-hidden="true" style=${barStyle}></i>`
  })

  return html`
    <span
      role=${props.ariaHidden === true ? undefined : 'img'}
      data-testid=${props.testId}
      data-kind=${kind}
      aria-label=${label}
      aria-hidden=${props.ariaHidden === true ? 'true' : undefined}
      style=${containerStyle}
    >
      ${bars}
    </span>
  `
}
