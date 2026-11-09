// Tool call series panel — hourly or daily totals of the retained tool calls,
// drawn as calls, failure rate, time spent and latency, with the tools that spent the most time.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type { ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'
import { formatMsCompact } from '../../lib/format-number'
import { FilterChips } from '../common/filter-chips'
import { ObservedMetricChart, type MetricChartSeries } from '../common/observed-metric-chart'
import { StatTile } from '../common/stat-tile'
import { DetailCard } from '../keeper-detail-kpi'
import {
  SERIES_WINDOWS,
  SERIES_WINDOW_ORDER,
  bucketReadings,
  cutShortBucketCount,
  selectTool,
  selectWindow,
  selectedTool,
  selectedWindow,
  seriesError,
  seriesLoading,
  subscribeToolSeriesRefresh,
  visibleSeries,
  type SeriesWindowKey,
} from './tool-series-state'

const MS_PER_HOUR = 3_600_000
const PERCENT = 100

export function formatTotalTime(ms: number): string {
  return ms < MS_PER_HOUR ? formatMsCompact(ms) : `${(ms / MS_PER_HOUR).toFixed(1)}h`
}

function formatCount(count: number): string {
  return `${Math.round(count).toLocaleString()}회`
}

/** Share of failed calls, or null when nothing ran. */
export function failureRatePercent(callCount: number, failureCount: number): number | null {
  return callCount === 0 ? null : (failureCount / callCount) * PERCENT
}

function formatPercent(percent: number): string {
  return `${percent.toFixed(1)}%`
}

function formatFailureRate(callCount: number, failureCount: number): string {
  const rate = failureRatePercent(callCount, failureCount)
  return rate === null ? '-' : formatPercent(rate)
}

export function callSeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    { name: '호출', color: 'var(--color-accent-fg)', readings: bucketReadings(series, bucket => bucket.call_count) },
    {
      name: '실패',
      color: 'var(--color-status-warn)',
      dashed: true,
      readings: bucketReadings(series, bucket => bucket.failure_count),
    },
  ]
}

/**
 * Share of failed calls per bucket. Failures are a small part of the calls, so
 * on the call chart's axis their line lies flat; on this one a bucket in which
 * calls failed in bulk stands out. A bucket with no call is a gap, not 0%.
 */
export function failureRateSeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    {
      name: '실패율',
      color: 'var(--color-status-warn)',
      readings: bucketReadings(series, bucket => failureRatePercent(bucket.call_count, bucket.failure_count)),
    },
  ]
}

export function timeSeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    { name: '실행 시간 합계', color: 'var(--color-accent-fg)', readings: bucketReadings(series, bucket => bucket.total_ms) },
  ]
}

/** p50 and p95 per bucket. A bucket with no call is a gap, not zero. */
export function latencySeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    { name: 'p95', color: 'var(--color-accent-fg)', readings: bucketReadings(series, bucket => bucket.p95_ms) },
    {
      name: 'p50',
      color: 'var(--color-status-ok)',
      dashed: true,
      readings: bucketReadings(series, bucket => bucket.p50_ms),
    },
  ]
}

const WINDOW_CHIPS = SERIES_WINDOW_ORDER.map(key => ({ key, label: SERIES_WINDOWS[key].label }))

export interface ToolSeriesViewProps {
  readonly series: ToolMetricsSeriesResponse | null
  readonly loading: boolean
  readonly error: string | null
  readonly windowKey: SeriesWindowKey
  readonly tool: string | null
  readonly onWindow: (key: SeriesWindowKey) => void
  readonly onTool: (tool: string | null) => void
}

function ToolSeriesCharts({ series }: { series: ToolMetricsSeriesResponse }) {
  const total = series.total
  const cutShort = cutShortBucketCount(series)
  return html`
    <div class="grid grid-cols-[repeat(6,minmax(0,1fr))] gap-3 max-[1100px]:grid-cols-[repeat(3,minmax(0,1fr))] max-[520px]:grid-cols-[repeat(2,minmax(0,1fr))]">
      <${StatTile} label="호출" value=${formatCount(total.call_count)} status="brass" />
      <${StatTile} label="실패" value=${formatCount(total.failure_count)} status="brass" />
      <${StatTile} label="실패율" value=${formatFailureRate(total.call_count, total.failure_count)} status="brass" />
      <${StatTile} label="실행 시간 합계" value=${formatTotalTime(total.total_ms)} status="brass" />
      <${StatTile} label="지연 p50" value=${formatMsCompact(total.p50_ms, '-')} status="brass" />
      <${StatTile} label="지연 p95" value=${formatMsCompact(total.p95_ms, '-')} status="brass" />
    </div>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 호출 수" unit="회" formatValue=${formatCount} series=${callSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 실패율" unit="%" formatValue=${formatPercent} series=${failureRateSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 실행 시간 합계" unit="ms" formatValue=${formatTotalTime} series=${timeSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 지연 p50 / p95" unit="ms" formatValue=${(ms: number) => formatMsCompact(ms)} series=${latencySeries(series)} />
      <//>
    </div>
    ${cutShort > 0
      ? html`<p class="text-2xs text-[var(--color-fg-muted)]">처음과 끝의 덜 찬 구간은 그래프에서 뺐어요. 위 합계와 아래 표에는 들어 있어요.</p>`
      : null}
  `
}

function ToolSeriesTable({ series, tool, onTool }: {
  series: ToolMetricsSeriesResponse
  tool: string | null
  onTool: (tool: string | null) => void
}) {
  if (series.top_by_time.length === 0) return html`<p class="muted">이 구간에 기록된 호출이 없습니다.</p>`
  return html`
    <div class="overflow-auto">
      <table class="w-full text-left tabular-nums text-2xs">
        <caption class="text-left mb-1 text-[var(--color-fg-muted)]">시간을 가장 많이 쓴 도구</caption>
        <thead>
          <tr>
            <th scope="col">도구</th><th scope="col">호출</th><th scope="col">실패</th>
            <th scope="col">시간 합계</th><th scope="col">p50</th><th scope="col">p95</th><th scope="col">최대</th>
          </tr>
        </thead>
        <tbody>
          ${series.top_by_time.map(row => html`
            <tr key=${row.name}>
              <td>
                <button type="button" class="font-mono cursor-pointer text-left ${row.name === tool ? 'text-[var(--color-accent-fg)]' : ''}"
                  aria-pressed=${row.name === tool}
                  title=${row.public_names.join(', ')}
                  onClick=${() => onTool(row.name === tool ? null : row.name)}>${row.name}</button>
              </td>
              <td>${row.call_count.toLocaleString()}</td>
              <td>${row.failure_count.toLocaleString()}</td>
              <td>${formatTotalTime(row.total_ms)}</td>
              <td>${formatMsCompact(row.p50_ms, '-')}</td>
              <td>${formatMsCompact(row.p95_ms, '-')}</td>
              <td>${formatMsCompact(row.max_ms, '-')}</td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

export function ToolSeriesView({ series, loading, error, windowKey, tool, onWindow, onTool }: ToolSeriesViewProps) {
  // The series of the previous tool filter stays on screen, dimmed, until the
  // series of the picked one arrives.
  const settling = series !== null && series.tool !== tool
  return html`
    <div class="flex flex-col gap-3">
      <${FilterChips} chips=${WINDOW_CHIPS} value=${windowKey} onChange=${onWindow} />
      ${tool !== null ? html`
        <div class="flex items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
          <span>도구 <span class="font-mono text-[var(--color-fg-secondary)]">${tool}</span> 만 보는 중</span>
          <button type="button" class="cursor-pointer underline" onClick=${() => onTool(null)}>전체 도구 보기</button>
        </div>
      ` : null}
      ${error !== null ? html`<p class="text-xs text-[var(--color-status-warn)]">통계를 불러오지 못했습니다: ${error}</p>` : null}
      ${series === null
        ? (loading && error === null ? html`<p class="muted">통계를 불러오는 중입니다.</p>` : null)
        : html`
            <div class="flex flex-col gap-3 ${settling ? 'opacity-60' : ''}" aria-busy=${settling}>
              <${ToolSeriesCharts} series=${series} />
              <${ToolSeriesTable} series=${series} tool=${tool} onTool=${onTool} />
            </div>
          `}
    </div>
  `
}

/** The panel on the Tools page: reads the picked window and keeps its series fresh. */
export function ToolSeriesPanel() {
  useEffect(() => subscribeToolSeriesRefresh(), [])
  return html`
    <${ToolSeriesView}
      series=${visibleSeries.value}
      loading=${seriesLoading.value}
      error=${seriesError.value}
      windowKey=${selectedWindow.value}
      tool=${selectedTool.value}
      onWindow=${selectWindow}
      onTool=${selectTool}
    />
  `
}
