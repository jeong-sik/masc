// Observatory Metric Track (RFC-MASC-006 Phase 2a+2b+3a)
// Renders tool call success rate over time as an SVG line on shared time axis.
// Phase 2b: mousemove updates cursor-store, CursorLine renders across track.
// Phase 3a: z-score anomaly detection, red overlay on outlier data points.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { ToolQualityHourlyPoint } from '../../api/dashboard'
import { setCursorFromEvent, clearCursor } from './cursor-store'
import { CursorLine } from './cursor-line'
import { detectAnomalies } from './anomaly-utils'
import { hourToMs } from './observatory-utils'

interface Props {
  points: ToolQualityHourlyPoint[]
  windowStart: number
  windowEnd: number
}

export function MetricTrack({ points, windowStart, windowEnd }: Props) {
  const trackRef = useRef<HTMLDivElement | null>(null)
  const span = windowEnd - windowStart
  if (span <= 0) return null

  const windowed = points
    .map(p => ({ point: p, ts: hourToMs(p.hour) }))
    .filter((m): m is { point: ToolQualityHourlyPoint; ts: number } =>
      m.ts !== null && m.ts >= windowStart && m.ts <= windowEnd,
    )
    .sort((a, b) => a.ts - b.ts)

  const viewBoxWidth = 1000
  const viewBoxHeight = 60

  const anomalyResults = detectAnomalies(windowed)

  const polyline = windowed
    .map(({ point, ts }) => {
      const x = ((ts - windowStart) / span) * viewBoxWidth
      const y = viewBoxHeight - (point.success_rate / 100) * viewBoxHeight
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })
    .join(' ')

  const anomalyCount = anomalyResults.filter(r => r.isAnomaly).length
  const lastRate = windowed[windowed.length - 1]?.point.success_rate ?? null
  const lastRateColor =
    lastRate == null ? 'text-text-dim'
      : lastRate >= 97 ? 'text-[var(--color-status-ok)]'
      : lastRate >= 90 ? 'text-text-strong'
      : 'text-[var(--bad-light)]'

  return html`
    <div class="flex items-center gap-3">
      <div class="w-24 shrink-0">
        <div class="text-2xs font-semibold text-text-muted">도구 성공률</div>
        ${lastRate != null ? html`
          <div class="text-sm font-mono font-semibold ${lastRateColor}">
            ${lastRate.toFixed(1)}%
          </div>
        ` : html`<div class="text-3xs text-text-dim">데이터 없음</div>`}
        ${anomalyCount > 0 ? html`
          <div class="text-3xs font-mono text-[var(--bad-light)]">${anomalyCount} anomaly</div>
        ` : null}
      </div>
      <div
        ref=${trackRef}
        class="relative flex-1 h-12 rounded bg-bg-1/40 border border-card-border/50 cursor-crosshair"
        onMouseMove=${(e: MouseEvent) => {
          if (trackRef.current) setCursorFromEvent(e, trackRef.current, windowStart, windowEnd)
        }}
        onMouseLeave=${clearCursor}
      >
        ${windowed.length === 0 ? html`
          <div class="absolute inset-0 flex items-center justify-center text-3xs text-text-dim">
            hourly_trend 데이터 부족
          </div>
        ` : html`
          <svg
            viewBox="0 0 ${viewBoxWidth} ${viewBoxHeight}"
            preserveAspectRatio="none"
            class="absolute inset-0 w-full h-full"
          >
            ${anomalyResults.filter(r => r.isAnomaly).map((r, i) => {
              const x = ((r.ts - windowStart) / span) * viewBoxWidth
              const halfW = viewBoxWidth / Math.max(windowed.length, 1) * 0.5
              return html`
                <rect
                  x="${(x - halfW).toFixed(1)}"
                  y="0"
                  width="${(halfW * 2).toFixed(1)}"
                  height="${viewBoxHeight}"
                  fill="${r.zScore < 0 ? 'var(--bad-12)' : 'rgba(245,158,11,0.10)'}"
                  key=${`anomaly-${i}`}
                >
                  <title>z=${r.zScore.toFixed(2)} · ${r.point.success_rate.toFixed(1)}%</title>
                </rect>
              `
            })}
            <line x1="0" y1="${viewBoxHeight * 0.03}" x2="${viewBoxWidth}" y2="${viewBoxHeight * 0.03}" stroke="currentColor" stroke-dasharray="2 4" class="text-[var(--color-status-ok)]/30" stroke-width="0.5" />
            <line x1="0" y1="${viewBoxHeight * 0.1}" x2="${viewBoxWidth}" y2="${viewBoxHeight * 0.1}" stroke="currentColor" stroke-dasharray="2 4" class="text-[var(--color-status-warn)]/30" stroke-width="0.5" />
            <polyline
              points=${polyline}
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              class="text-accent"
              vector-effect="non-scaling-stroke"
            />
            ${anomalyResults.map((r) => {
              const x = ((r.ts - windowStart) / span) * viewBoxWidth
              const y = viewBoxHeight - (r.point.success_rate / 100) * viewBoxHeight
              return html`
                <circle
                  cx="${x.toFixed(1)}"
                  cy="${y.toFixed(1)}"
                  r=${r.isAnomaly ? '3' : '1.5'}
                  fill="currentColor"
                  class=${r.isAnomaly ? (r.zScore < 0 ? 'text-[var(--bad-light)]' : 'text-[var(--color-status-warn)]') : 'text-accent'}
                  stroke=${r.isAnomaly ? 'currentColor' : 'none'}
                  stroke-width=${r.isAnomaly ? '0.5' : '0'}
                >
                  <title>${r.point.hour} · ${r.point.success_rate.toFixed(1)}% (${r.point.calls} calls)${r.isAnomaly ? ` · z=${r.zScore.toFixed(2)}` : ''}</title>
                </circle>
              `
            })}
          </svg>
        `}
        <${CursorLine} />
      </div>
    </div>
  `
}
