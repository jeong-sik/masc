// Observatory Metric Track — keeper-v2 monitor-more design (ObservatoryPanel).
// Design vocabulary: .ob-track > .ob-track-k + .ob-lane, with the success-rate
// polyline drawn in .ob-svg (position absolute inset 0, non-scaling stroke).
// Live-only additions stay inside the svg: z-score anomaly overlays and the
// 97%/90% guide lines. Hover cursor lives on the parent .ob-panel
// (observatory.ts), not per track.

import { html } from 'htm/preact'
import type { ToolQualityHourlyPoint } from '../../api/dashboard'
import { detectAnomalies } from './anomaly-utils'
import { hourToMs } from './observatory-utils'

interface Props {
  points: ToolQualityHourlyPoint[]
  windowStart: number
  windowEnd: number
}

export function MetricTrack({ points, windowStart, windowEnd }: Props) {
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

  return html`
    <div class="ob-track">
      <span class="ob-track-k mono">success %</span>
      <div
        class="ob-lane"
        role="group"
        aria-label="도구 성공률 트렌드"
      >
        ${windowed.length === 0 ? html`
          <div class="absolute inset-0 flex items-center justify-center text-3xs text-text-dim">
            hourly_trend 데이터 부족
          </div>
        ` : html`
          <svg
            viewBox="0 0 ${viewBoxWidth} ${viewBoxHeight}"
            preserveAspectRatio="none"
            class="ob-svg"
            role="img"
            aria-label="시간대별 메트릭 트렌드 차트"
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
                  fill="${r.zScore < 0 ? 'var(--bad-12)' : 'var(--warn-soft)'}"
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
                  class=${r.isAnomaly ? (r.zScore < 0 ? 'text-[var(--bad-light)]' : 'text-[var(--color-status-warn)]') : ''}
                  stroke=${r.isAnomaly ? 'currentColor' : 'none'}
                  stroke-width=${r.isAnomaly ? '0.5' : '0'}
                >
                  <title>${r.point.hour} · ${r.point.success_rate.toFixed(1)}% (${r.point.calls} calls)${r.isAnomaly ? ` · z=${r.zScore.toFixed(2)}` : ''}</title>
                </circle>
              `
            })}
          </svg>
        `}
      </div>
    </div>
  `
}
