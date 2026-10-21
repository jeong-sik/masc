import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { metricCoordinate, summarizeMetricSeries, type MetricReading } from '../../lib/metric-series'

export interface MetricChartSeries {
  readonly name: string
  readonly color: string
  readonly readings: readonly MetricReading[]
  readonly dashed?: boolean
}

function timeLabel(ts: number): string {
  return new Date(ts * 1000).toLocaleString()
}

/** Timestamp-based plot plus the same original values as an accessible table. */
export function ObservedMetricChart({ label, unit, series, formatValue }: {
  label: string
  unit: string
  series: readonly MetricChartSeries[]
  formatValue: (value: number) => string
}) {
  const [tableOpen, setTableOpen] = useState(false)
  const summaries = series.map(row => ({ ...row, ...summarizeMetricSeries(row.readings) }))
  const times = summaries.flatMap(series => series.rows.map(row => row.ts))
  const start = times.reduce((min, value) => Math.min(min, value), Infinity)
  const end = times.reduce((max, value) => Math.max(max, value), -Infinity)
  const peak = summaries.reduce((max, series) => Math.max(max, series.maximum ?? 0), 0)
  const observed = summaries.reduce((sum, series) => sum + series.observed, 0)
  const width = 320, height = 90, pad = 5
  const coordinate = (row: { ts: number; value: number }) => {
    const point = metricCoordinate(row, [start, end], peak)
    return { x: pad + point.x * (width - pad * 2), y: height - pad - point.y * (height - pad * 2) }
  }
  return html`
    <figure class="m-0 min-w-0" aria-label=${label}>
      <div class="flex justify-between gap-2 text-3xs text-[var(--color-fg-secondary)] tabular-nums mb-1">
        <span>0 → ${observed > 0 ? formatValue(peak) : '미관측'}</span>
        <span>로컬 시간축 · 현재 불러온 기록</span>
      </div>
      ${observed > 0 ? html`
        <svg viewBox=${`0 0 ${width} ${height}`} width="100%" height=${height}
          preserveAspectRatio="none" role="img" aria-label=${`${label} · 결측은 연결하지 않음. 원본 관측값은 아래 표에서 확인.`}>
          <title>${label}</title>
          ${[0, 0.5, 1].map(level => html`
            <line x1=${pad} x2=${width - pad} y1=${height - pad - level * (height - pad * 2)}
              y2=${height - pad - level * (height - pad * 2)} stroke="var(--color-border-default)" stroke-width="0.5" />
          `)}
          ${summaries.map(series => series.segments.map(segment => html`
            ${segment.length > 1 ? html`
              <polyline points=${segment.map(row => { const p = coordinate(row); return `${p.x},${p.y}` }).join(' ')}
                fill="none" stroke=${series.color} stroke-width="1.75" vector-effect="non-scaling-stroke"
                stroke-dasharray=${series.dashed ? '5 3' : undefined} />
            ` : null}
            ${(segment.length === 1 ? segment : [segment[0]!, segment[segment.length - 1]!]).map(row => {
              const p = coordinate(row)
              // A round-capped zero-length stroke stays circular when the
              // responsive viewBox stretches only the horizontal coordinate.
              return html`<path d=${`M ${p.x} ${p.y} h 0`} fill="none" stroke=${series.color}
                stroke-width="4" stroke-linecap="round" vector-effect="non-scaling-stroke">
                <title>${series.name} · ${timeLabel(row.ts)} · ${formatValue(row.value)}</title>
              </path>`
            })}
          `))}
        </svg>
      ` : html`<p class="text-xs text-[var(--color-fg-secondary)]">관측된 값이 없습니다.</p>`}
      ${times.length > 0 ? html`
        <div class="flex flex-wrap justify-between gap-1 text-3xs text-[var(--color-fg-secondary)] tabular-nums">
          <span>${timeLabel(start)}</span><span>${timeLabel(end)}</span>
        </div>
      ` : null}
      <figcaption class="mt-2 space-y-1 text-3xs text-[var(--color-fg-secondary)]">
        ${summaries.map(series => html`
          <div>
            <span style=${`color:${series.color}`}>${series.dashed ? '┄' : '━'} ${series.name}</span>
            · 관측 ${series.observed}/${series.rows.length} · 미관측 ${series.missing}
            <div class="tabular-nums">최신 ${series.latest === null ? '미관측' : formatValue(series.latest)}
              · 최소 ${series.minimum === null ? '미관측' : formatValue(series.minimum)}
              · 최대 ${series.maximum === null ? '미관측' : formatValue(series.maximum)}</div>
          </div>
        `)}
      </figcaption>
      <details class="mt-2 text-3xs text-[var(--color-fg-secondary)]"
        onToggle=${(event: Event) => setTableOpen((event.currentTarget as HTMLDetailsElement).open)}>
        <summary class="cursor-pointer">원본 관측값</summary>
        ${tableOpen ? html`<div class="max-h-60 overflow-auto mt-1">
          <table class="w-full text-left tabular-nums">
            <caption class="text-left">${label} · 결측은 미관측으로 표시</caption>
            <thead><tr><th scope="col">시각</th><th scope="col">계열</th><th scope="col">값 (${unit})</th></tr></thead>
            <tbody>${summaries.flatMap(series => series.rows.map((row, index) => html`
              <tr key=${`${series.name}:${index}`}><td>${timeLabel(row.ts)}</td><td>${series.name}</td>
                <td>${row.value === null ? '미관측' : String(row.value)}</td></tr>
            `))}</tbody>
          </table>
        </div>` : null}
      </details>
    </figure>
  `
}
