/**
 * Structured SVG chart renderer (`line`, `bar`, `area`, `pie`) and
 * ```` ```chart ```` JSON fence decoder.
 *
 * Shared by:
 * - `ChatChartBlock` (`src/components/chat/primitives.ts`)
 * - `RichCodePreviewCard` (`src/components/common/rich-code-preview.ts`) for Markdown fences
 * - `ChatArtifactPanel` (`src/components/chat/artifact-panel.ts`)
 */

import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import type { ChatChartBlock } from '../../types/core'

export type StructuredChartType = 'line' | 'bar' | 'area' | 'pie'

const CHART_PALETTE: readonly string[] = [
  'var(--chart-series-1, var(--accent-brass-bright, var(--accent)))',
  'var(--chart-series-2, var(--ok))',
  'var(--chart-series-3, var(--info, var(--accent)))',
  'var(--chart-series-4, var(--warn))',
  'var(--chart-series-5, var(--bad))',
  'var(--chart-series-6, var(--fg-2))',
  'var(--chart-series-7, var(--accent-brass, var(--accent)))',
  'var(--chart-series-8, var(--fg-1))',
]

function normalizeChartType(raw: unknown): StructuredChartType {
  if (typeof raw !== 'string') return 'line'
  const lower = raw.trim().toLowerCase()
  if (lower === 'bar' || lower === 'column') return 'bar'
  if (lower === 'area') return 'area'
  if (lower === 'pie' || lower === 'donut') return 'pie'
  return 'line'
}

/**
 * Parse a ```` ```chart ```` fenced JSON block into a `ChatChartBlock`.
 * Returns `null` on invalid JSON or when required `series` data is missing so
 * callers cleanly fall back to a regular code block.
 */
export function parseChartFenceJson(source: string): ChatChartBlock | null {
  const trimmed = source.trim()
  if (!trimmed.startsWith('{')) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch {
    return null
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null
  const rec = parsed as Record<string, unknown>

  if (!Array.isArray(rec.series) || rec.series.length === 0) return null
  const series: Array<{ label: string; color?: string; values: number[] }> = []
  for (const item of rec.series) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) continue
    const s = item as Record<string, unknown>
    const label = typeof s.label === 'string' && s.label.trim() ? s.label.trim() : `Series ${series.length + 1}`
    if (!Array.isArray(s.values)) continue
    const values = s.values.filter((v): v is number => typeof v === 'number' && Number.isFinite(v))
    if (values.length === 0) continue
    const color = typeof s.color === 'string' && s.color.trim() ? s.color.trim() : undefined
    series.push({ label, color, values })
  }
  if (series.length === 0) return null

  const title = typeof rec.title === 'string' && rec.title.trim() ? rec.title.trim() : 'Chart'
  const chartType = normalizeChartType(rec.chartType ?? rec.chart_type ?? rec.type ?? rec.kind)
  const labels = Array.isArray(rec.labels)
    ? rec.labels.map((l) => String(l))
    : undefined
  const xLabel = typeof rec.xLabel === 'string'
    ? rec.xLabel
    : typeof rec.x_label === 'string'
      ? rec.x_label
      : undefined
  const yLabel = typeof rec.yLabel === 'string'
    ? rec.yLabel
    : typeof rec.y_label === 'string'
      ? rec.y_label
      : undefined
  const yMaxRaw = rec.yMax ?? rec.y_max
  const yMax = typeof yMaxRaw === 'number' && Number.isFinite(yMaxRaw) ? yMaxRaw : undefined

  return {
    t: 'chart',
    chartType,
    title,
    series,
    labels,
    xLabel,
    yLabel,
    yMax,
  }
}

function formatTickValue(value: number): string {
  if (!Number.isFinite(value)) return '0'
  if (Math.abs(value) >= 1000) return `${(value / 1000).toFixed(1)}k`
  if (Number.isInteger(value)) return String(value)
  if (Math.abs(value) >= 10) return value.toFixed(1)
  return value.toFixed(2).replace(/\.?0+$/, '')
}

function seriesColor(series: { color?: string }, index: number): string {
  return series.color?.trim() || CHART_PALETTE[index % CHART_PALETTE.length]!
}

interface HoverReadout {
  readonly label: string
  readonly entries: ReadonlyArray<{ readonly name: string; readonly value: number; readonly color: string }>
}

function PieChartSvg({
  block,
  onHover,
}: {
  readonly block: ChatChartBlock
  readonly onHover: (info: HoverReadout | null) => void
}) {
  // Support either multi-series single-value pie OR single-series multi-slice pie with labels[].
  const slices = useMemo(() => {
    const out: Array<{ label: string; value: number; color: string }> = []
    if (block.series.length === 1 && (block.series[0]?.values.length ?? 0) > 1) {
      const only = block.series[0]!
      only.values.forEach((v, idx) => {
        if (v > 0) {
          out.push({
            label: block.labels?.[idx] ?? `#${idx + 1}`,
            value: v,
            color: CHART_PALETTE[idx % CHART_PALETTE.length]!,
          })
        }
      })
    } else {
      block.series.forEach((s, idx) => {
        const sum = s.values.reduce((acc, v) => acc + Math.max(0, v), 0)
        if (sum > 0) {
          out.push({
            label: s.label,
            value: sum,
            color: seriesColor(s, idx),
          })
        }
      })
    }
    return out
  }, [block])

  const total = slices.reduce((acc, s) => acc + s.value, 0)
  if (total <= 0) {
    return html`<div class="chat-block-chart-empty">표시할 양수 데이터가 없습니다.</div>`
  }

  const cx = 110
  const cy = 90
  const r = 72
  let cursorAngle = -Math.PI / 2

  return html`
    <div class="chat-block-chart-pie-wrap">
      <svg
        viewBox="0 0 220 180"
        class="chat-block-chart-svg is-pie"
        role="img"
        aria-label=${block.title}
        onMouseLeave=${() => onHover(null)}
      >
        ${slices.map((slice, idx) => {
          const frac = slice.value / total
          const sweep = frac * Math.PI * 2
          const startAngle = cursorAngle
          const endAngle = cursorAngle + sweep
          cursorAngle = endAngle

          const pct = Math.round(frac * 1000) / 10
          const onEnter = () => onHover({
            label: `${slice.label} (${pct}%)`,
            entries: [{ name: slice.label, value: slice.value, color: slice.color }],
          })

          if (frac >= 0.9999) {
            return html`
              <circle
                key=${idx}
                cx=${cx}
                cy=${cy}
                r=${r}
                fill=${slice.color}
                onMouseEnter=${onEnter}
              >
                <title>${slice.label}: ${formatTickValue(slice.value)} (${pct}%)</title>
              </circle>
            `
          }

          const x1 = cx + r * Math.cos(startAngle)
          const y1 = cy + r * Math.sin(startAngle)
          const x2 = cx + r * Math.cos(endAngle)
          const y2 = cy + r * Math.sin(endAngle)
          const largeArc = sweep > Math.PI ? 1 : 0
          const d = `M ${cx} ${cy} L ${x1.toFixed(2)} ${y1.toFixed(2)} A ${r} ${r} 0 ${largeArc} 1 ${x2.toFixed(2)} ${y2.toFixed(2)} Z`

          return html`
            <path
              key=${idx}
              d=${d}
              fill=${slice.color}
              stroke="var(--bg-1, var(--color-bg-surface))"
              stroke-width="1.5"
              onMouseEnter=${onEnter}
            >
              <title>${slice.label}: ${formatTickValue(slice.value)} (${pct}%)</title>
            </path>
          `
        })}
      </svg>
      <div class="chat-block-chart-pie-legend">
        ${slices.map((slice, idx) => {
          const pct = Math.round((slice.value / total) * 1000) / 10
          return html`
            <span key=${idx} class="chat-block-chart-legend-item">
              <span class="chat-block-chart-dot" style=${{ background: slice.color }} />
              <span>${slice.label}</span>
              <span class="mono">${formatTickValue(slice.value)} (${pct}%)</span>
            </span>
          `
        })}
      </div>
    </div>
  `
}

export function StructuredChartView({ block }: { readonly block: ChatChartBlock }) {
  const [hover, setHover] = useState<HoverReadout | null>(null)
  const chartType = normalizeChartType(block.chartType)

  if (chartType === 'pie') {
    return html`
      <div class="chat-block-chart" data-chart-type="pie" data-testid="structured-chart">
        <div class="chat-block-chart-head">
          <div class="chat-block-chart-title">${block.title}</div>
          <span class="chat-block-chart-type mono">PIE</span>
        </div>
        ${hover && html`
          <div class="chat-block-chart-readout mono" data-testid="chart-hover-readout">
            ${hover.label}: ${hover.entries.map((e) => formatTickValue(e.value)).join(', ')}
          </div>
        `}
        <${PieChartSvg} block=${block} onHover=${setHover} />
      </div>
    `
  }

  const allValues = block.series.flatMap((s) => s.values)
  const rawMin = allValues.length > 0 ? Math.min(...allValues) : 0
  const rawMax = allValues.length > 0 ? Math.max(...allValues) : 1
  const minVal = chartType === 'bar' ? Math.min(0, rawMin) : Math.min(0, rawMin)
  let maxVal = block.yMax !== undefined ? Math.max(block.yMax, rawMax) : Math.max(0, rawMax)
  if (Math.abs(maxVal - minVal) < 1e-9) {
    maxVal = minVal + 1
  }

  const maxPoints = Math.max(...block.series.map((s) => s.values.length), 1)
  const w = 440
  const h = 190
  const padL = 44
  const padR = 14
  const padT = 14
  const padB = block.labels && block.labels.length > 0 ? 34 : 22
  const innerW = w - padL - padR
  const innerH = h - padT - padB

  const yAt = (v: number): number => padT + innerH - ((v - minVal) / (maxVal - minVal)) * innerH
  const baselineY = yAt(Math.max(minVal, Math.min(0, maxVal)))
  const xAtIndex = (i: number): number => {
    if (chartType === 'bar') {
      return padL + ((i + 0.5) / maxPoints) * innerW
    }
    if (maxPoints <= 1) return padL + innerW / 2
    return padL + (i / (maxPoints - 1)) * innerW
  }

  const yTicks = [minVal, minVal + (maxVal - minVal) * 0.5, maxVal]
  const xStep = Math.max(1, Math.ceil(maxPoints / 6))

  const handlePointHover = (idx: number) => {
    const label = block.labels?.[idx] ?? `#${idx + 1}`
    const entries = block.series
      .filter((s) => idx < s.values.length)
      .map((s, si) => ({
        name: s.label,
        value: s.values[idx]!,
        color: seriesColor(s, si),
      }))
    setHover({ label, entries })
  }

  const groupWidth = innerW / Math.max(maxPoints, 1)
  const barSlotWidth = Math.max(4, (groupWidth * 0.72) / Math.max(block.series.length, 1))

  return html`
    <div class="chat-block-chart" data-chart-type=${chartType} data-testid="structured-chart">
      <div class="chat-block-chart-head">
        <div class="chat-block-chart-title">${block.title}</div>
        <div class="chat-block-chart-legend">
          ${block.series.map((s, si) => html`
            <span key=${s.label} class="chat-block-chart-legend-item">
              <span class="chat-block-chart-dot" style=${{ background: seriesColor(s, si) }} />
              ${s.label}
            </span>
          `)}
          <span class="chat-block-chart-type mono">${chartType.toUpperCase()}</span>
        </div>
      </div>

      ${hover && html`
        <div class="chat-block-chart-readout mono" data-testid="chart-hover-readout">
          <strong>${hover.label}</strong>
          ${hover.entries.map((e, i) => html`
            <span key=${i} class="chat-block-chart-readout-item">
              <span class="chat-block-chart-dot" style=${{ background: e.color }} />
              ${e.name}: ${formatTickValue(e.value)}
            </span>
          `)}
        </div>
      `}

      <svg
        viewBox=${`0 0 ${w} ${h}`}
        class="chat-block-chart-svg"
        role="img"
        aria-label=${block.title}
        onMouseLeave=${() => setHover(null)}
      >
        ${yTicks.map((tick, ti) => {
          const y = yAt(tick)
          return html`
            <g key=${ti}>
              <line
                x1=${padL}
                y1=${y}
                x2=${w - padR}
                y2=${y}
                stroke="var(--line-1, var(--color-border-subtle))"
                stroke-dasharray=${ti === 0 ? undefined : '2 3'}
                stroke-width="1"
              />
              <text
                x=${padL - 6}
                y=${y + 3}
                text-anchor="end"
                font-size="9.5"
                fill="var(--fg-3, var(--color-fg-muted))"
              >
                ${formatTickValue(tick)}
              </text>
            </g>
          `
        })}

        ${minVal < 0 && maxVal > 0 && html`
          <line
            x1=${padL}
            y1=${baselineY}
            x2=${w - padR}
            y2=${baselineY}
            stroke="var(--line-2, var(--color-border-default))"
            stroke-width="1"
          />
        `}

        ${chartType === 'bar'
          ? block.series.map((s, si) => {
              const color = seriesColor(s, si)
              return html`
                <g key=${s.label}>
                  ${s.values.map((v, vi) => {
                    const groupLeft = padL + vi * groupWidth + groupWidth * 0.14
                    const x = groupLeft + si * barSlotWidth
                    const yTop = Math.min(yAt(v), baselineY)
                    const barH = Math.max(1.5, Math.abs(yAt(v) - baselineY))
                    return html`
                      <rect
                        key=${vi}
                        x=${x.toFixed(1)}
                        y=${yTop.toFixed(1)}
                        width=${Math.max(2, barSlotWidth - 1.5).toFixed(1)}
                        height=${barH.toFixed(1)}
                        rx="2"
                        fill=${color}
                        onMouseEnter=${() => handlePointHover(vi)}
                      >
                        <title>${s.label} (${block.labels?.[vi] ?? `#${vi + 1}`}): ${formatTickValue(v)}</title>
                      </rect>
                    `
                  })}
                </g>
              `
            })
          : block.series.map((s, si) => {
              const color = seriesColor(s, si)
              const coords = s.values.map((v, vi) => ({ x: xAtIndex(vi), y: yAt(v), v, vi }))
              const linePts = coords.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')
              const areaPath = chartType === 'area' && coords.length > 0
                ? `M ${coords[0]!.x.toFixed(1)} ${baselineY.toFixed(1)} `
                  + coords.map((p) => `L ${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(' ')
                  + ` L ${coords[coords.length - 1]!.x.toFixed(1)} ${baselineY.toFixed(1)} Z`
                : null

              return html`
                <g key=${s.label}>
                  ${areaPath && html`
                    <path d=${areaPath} fill=${color} fill-opacity="0.18" />
                  `}
                  <polyline
                    fill="none"
                    stroke=${color}
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    points=${linePts}
                  />
                  ${coords.map((p) => html`
                    <circle
                      key=${p.vi}
                      cx=${p.x.toFixed(1)}
                      cy=${p.y.toFixed(1)}
                      r="3.2"
                      fill=${color}
                      onMouseEnter=${() => handlePointHover(p.vi)}
                    >
                      <title>${s.label} (${block.labels?.[p.vi] ?? `#${p.vi + 1}`}): ${formatTickValue(p.v)}</title>
                    </circle>
                  `)}
                </g>
              `
            })}

        ${Array.from({ length: maxPoints }, (_, idx) => {
          if (idx % xStep !== 0 && idx !== maxPoints - 1) return null
          const lbl = block.labels?.[idx]
          if (!lbl) return null
          const x = xAtIndex(idx)
          return html`
            <text
              key=${idx}
              x=${x.toFixed(1)}
              y=${h - 12}
              text-anchor="middle"
              font-size="9.5"
              fill="var(--fg-3, var(--color-fg-muted))"
            >
              ${lbl.length > 10 ? `${lbl.slice(0, 9)}…` : lbl}
            </text>
          `
        })}

        ${block.xLabel && html`
          <text
            x=${w / 2}
            y=${h - 2}
            text-anchor="middle"
            font-size="9"
            fill="var(--fg-3, var(--color-fg-muted))"
          >
            ${block.xLabel}
          </text>
        `}
        ${block.yLabel && html`
          <text
            x=${10}
            y=${padT + innerH / 2}
            text-anchor="middle"
            font-size="9"
            fill="var(--fg-3, var(--color-fg-muted))"
            transform=${`rotate(-90 10 ${padT + innerH / 2})`}
          >
            ${block.yLabel}
          </text>
        `}
      </svg>
    </div>
  `
}
