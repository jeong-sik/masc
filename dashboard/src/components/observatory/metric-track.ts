// Observatory Metric Track (RFC-MASC-006 Phase 2a+2b)
// Renders tool call success rate over time as an SVG line on shared time axis.
// Phase 2b: mousemove updates cursor-store, CursorLine renders across track.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { ToolQualityHourlyPoint } from '../../api/dashboard'
import { setCursorFromEvent, clearCursor } from './cursor-store'
import { CursorLine } from './cursor-line'

interface Props {
  points: ToolQualityHourlyPoint[]
  windowStart: number
  windowEnd: number
}

function hourToMs(hour: string): number | null {
  const parsed = Date.parse(hour.includes('T') ? hour : `${hour}:00:00Z`)
  return Number.isNaN(parsed) ? null : parsed
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

  const polyline = windowed
    .map(({ point, ts }) => {
      const x = ((ts - windowStart) / span) * viewBoxWidth
      const y = viewBoxHeight - (point.success_rate / 100) * viewBoxHeight
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })
    .join(' ')

  const lastRate = windowed[windowed.length - 1]?.point.success_rate ?? null
  const lastRateColor =
    lastRate == null ? 'text-text-dim'
      : lastRate >= 97 ? 'text-emerald-400'
      : lastRate >= 90 ? 'text-text-strong'
      : 'text-red-400'

  return html`
    <div class="flex items-center gap-3">
      <div class="w-24 shrink-0">
        <div class="text-[11px] font-semibold text-text-muted">도구 성공률</div>
        ${lastRate != null ? html`
          <div class="text-[13px] font-mono font-semibold ${lastRateColor}">
            ${lastRate.toFixed(1)}%
          </div>
        ` : html`<div class="text-[10px] text-text-dim">데이터 없음</div>`}
      </div>
      <div
        ref=${trackRef}
        class="relative flex-1 h-12 rounded-md bg-bg-1/40 border border-card-border/50 cursor-crosshair"
        onMouseMove=${(e: MouseEvent) => {
          if (trackRef.current) setCursorFromEvent(e, trackRef.current, windowStart, windowEnd)
        }}
        onMouseLeave=${clearCursor}
      >
        ${windowed.length === 0 ? html`
          <div class="absolute inset-0 flex items-center justify-center text-[10px] text-text-dim">
            hourly_trend 데이터 부족
          </div>
        ` : html`
          <svg
            viewBox="0 0 ${viewBoxWidth} ${viewBoxHeight}"
            preserveAspectRatio="none"
            class="absolute inset-0 w-full h-full"
          >
            <line x1="0" y1="${viewBoxHeight * 0.03}" x2="${viewBoxWidth}" y2="${viewBoxHeight * 0.03}" stroke="currentColor" stroke-dasharray="2 4" class="text-emerald-500/30" stroke-width="0.5" />
            <line x1="0" y1="${viewBoxHeight * 0.1}" x2="${viewBoxWidth}" y2="${viewBoxHeight * 0.1}" stroke="currentColor" stroke-dasharray="2 4" class="text-amber-500/30" stroke-width="0.5" />
            <polyline
              points=${polyline}
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              class="text-accent"
              vector-effect="non-scaling-stroke"
            />
            ${windowed.map(({ point, ts }) => {
              const x = ((ts - windowStart) / span) * viewBoxWidth
              const y = viewBoxHeight - (point.success_rate / 100) * viewBoxHeight
              return html`
                <circle
                  cx="${x.toFixed(1)}"
                  cy="${y.toFixed(1)}"
                  r="1.5"
                  fill="currentColor"
                  class="text-accent"
                >
                  <title>${point.hour} · ${point.success_rate.toFixed(1)}% (${point.calls} calls)</title>
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
