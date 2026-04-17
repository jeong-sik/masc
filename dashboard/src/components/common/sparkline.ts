// Sparkline — inline Canvas 2D sparkline chart.
// Draws a filled area, polyline stroke, and a dot at the latest data point.
//
// Reference UI pattern (Grafana / Datadog stat panels): a canvas-only
// sparkline is INVISIBLE to assistive tech — AT users get nothing. We
// expose a default aria-label with "first → latest (min / max)" stats
// so screen readers still get the narrative. Callers that use the
// sparkline purely as decoration next to a numeric stat can pass
// `ariaHidden=true` to avoid redundant read-outs.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'

interface SparklineProps {
  values: number[]
  width?: number
  height?: number
  color?: string
  class?: string
  /** Override the auto-generated accessible label. Useful when the
      surrounding context already tells the story and you want a
      shorter narrative. */
  ariaLabel?: string
  /** Mark as purely decorative — AT will skip it. Use when a numeric
      label sits right next to the sparkline and they'd otherwise be
      read twice ("42 — Sparkline: 42 → 58 …"). */
  ariaHidden?: boolean
  /** `data-testid` for E2E hooks. */
  testId?: string
}

/** Stats derived from the series — exposed for callers that want to
    render their own trend badges AND for unit tests (no canvas needed). */
export interface SparklineStats {
  first: number
  latest: number
  min: number
  max: number
  range: number
  /** latest - first; 0 when series is flat. */
  delta: number
}

/** Pure: compute summary stats from a values array. Returns null if
    the series is too short to form a sparkline (< 2 points). */
export function sparklineStats(values: number[]): SparklineStats | null {
  if (values.length < 2) return null
  const first = values[0]!
  const latest = values[values.length - 1]!
  let min = first
  let max = first
  for (const v of values) {
    if (v < min) min = v
    if (v > max) max = v
  }
  return { first, latest, min, max, range: max - min, delta: latest - first }
}

/** Pure: build a default screen-reader label from the stats. Matches
    the Grafana "first → latest (min / max)" convention so AT users get
    the trend AND the bounds. */
export function sparklineAriaLabel(values: number[]): string {
  const s = sparklineStats(values)
  if (s === null) return 'Sparkline (insufficient data)'
  const fmt = (n: number) => Number.isInteger(n) ? String(n) : n.toFixed(2)
  return `Sparkline: ${fmt(s.first)} → ${fmt(s.latest)} (min ${fmt(s.min)}, max ${fmt(s.max)})`
}

export function Sparkline({
  values,
  width = 120,
  height = 28,
  color = '#22d3ee',
  class: cx,
  ariaLabel,
  ariaHidden,
  testId,
}: SparklineProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas || values.length < 2) return

    const dpr = typeof window !== 'undefined' ? (window.devicePixelRatio || 1) : 1
    canvas.width = width * dpr
    canvas.height = height * dpr
    canvas.style.width = `${width}px`
    canvas.style.height = `${height}px`

    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    const padY = 3
    const min = Math.min(...values)
    const max = Math.max(...values)
    const range = max - min || 1

    function toX(i: number): number {
      return (i / (values.length - 1)) * width
    }

    function toY(v: number): number {
      return height - padY - ((v - min) / range) * (height - padY * 2)
    }

    // Filled area
    ctx.beginPath()
    ctx.moveTo(toX(0), height)
    for (let i = 0; i < values.length; i++) {
      ctx.lineTo(toX(i), toY(values[i]!))
    }
    ctx.lineTo(toX(values.length - 1), height)
    ctx.closePath()

    // Parse color for fill opacity
    ctx.fillStyle = color.startsWith('#')
      ? `${color}18`
      : color.replace(/[\d.]+\)$/, '0.08)')
    ctx.fill()

    // Polyline stroke
    ctx.beginPath()
    ctx.moveTo(toX(0), toY(values[0]!))
    for (let i = 1; i < values.length; i++) {
      ctx.lineTo(toX(i), toY(values[i]!))
    }
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'
    ctx.stroke()

    // Dot at latest data point
    const lastIdx = values.length - 1
    const lastVal = values[lastIdx]!
    ctx.beginPath()
    ctx.arc(toX(lastIdx), toY(lastVal), 2.5, 0, Math.PI * 2)
    ctx.fillStyle = color
    ctx.fill()
  }, [values, width, height, color])

  if (values.length < 2) return null

  const cls = cx ? `block ${cx}` : 'block'
  const label = ariaHidden === true ? undefined : (ariaLabel ?? sparklineAriaLabel(values))
  return html`<canvas
    ref=${canvasRef}
    class=${cls}
    role="img"
    aria-label=${label}
    aria-hidden=${ariaHidden === true ? 'true' : undefined}
    data-testid=${testId}
  />`
}
