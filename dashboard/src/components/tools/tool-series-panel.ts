// Tool call series panel — hourly or daily totals of the retained tool calls,
// drawn as calls, failure rate, failures by class, time spent (and the part of it inside calls
// that ran a minute or more), latency and result bytes, with the tools that spent the most time.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type { ToolMetricsFailureClassCounts, ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'
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

const MS_PER_SECOND = 1_000
const MS_PER_MINUTE = 60_000
const MS_PER_HOUR = 3_600_000
const PERCENT = 100
const BYTES_PER_KIB = 1_024
const BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB
const BYTES_PER_GIB = BYTES_PER_MIB * BYTES_PER_KIB

/** "812 B", "4.8 KB", "62.4 MB", "1.3 GB": the size of what the calls returned. */
export function formatResultBytes(bytes: number): string {
  if (bytes < BYTES_PER_KIB) return `${Math.round(bytes)} B`
  if (bytes < BYTES_PER_MIB) return `${(bytes / BYTES_PER_KIB).toFixed(1)} KB`
  if (bytes < BYTES_PER_GIB) return `${(bytes / BYTES_PER_MIB).toFixed(1)} MB`
  return `${(bytes / BYTES_PER_GIB).toFixed(1)} GB`
}

/** A total over calls that have a size, or "-" when none does. */
function formatObservedBytes(observedCount: number, bytes: number): string {
  return observedCount === 0 ? '-' : formatResultBytes(bytes)
}

export function formatTotalTime(ms: number): string {
  return ms < MS_PER_HOUR ? formatMsCompact(ms) : `${(ms / MS_PER_HOUR).toFixed(1)}h`
}

function formatCount(count: number): string {
  return `${Math.round(count).toLocaleString()}회`
}

/** The line a call counts as long from, as the server counted it: "1분", or "90초" when it is not whole minutes. */
export function longCallLine(thresholdMs: number): string {
  return thresholdMs % MS_PER_MINUTE === 0
    ? `${thresholdMs / MS_PER_MINUTE}분`
    : `${thresholdMs / MS_PER_SECOND}초`
}

function longCallLabel(series: ToolMetricsSeriesResponse): string {
  return `${longCallLine(series.long_call_ms)} 이상 걸린 호출`
}

function longTimeLabel(series: ToolMetricsSeriesResponse): string {
  return `${longCallLine(series.long_call_ms)} 이상 걸린 시간`
}

/** "12회 · 3.4h": how many calls ran that long and the time they took. */
function formatLongCalls(count: number, ms: number): string {
  return `${formatCount(count)} · ${formatTotalTime(ms)}`
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

type FailureClassKey = keyof ToolMetricsFailureClassCounts

interface FailureClassLine {
  readonly key: FailureClassKey
  readonly name: string
  readonly color: string
  readonly dashed?: boolean
}

/**
 * One line per class of `Tool_result.tool_failure_class`, in a fixed order and
 * color so a class keeps its line from one window to the next. A class the
 * server adds has no line until it is listed here; the panel test compares
 * this list with the keys the server sends.
 */
export const FAILURE_CLASS_LINES: readonly FailureClassLine[] = [
  { key: 'dependency_unavailable', name: '외부 의존 불가', color: 'var(--color-status-warn)' },
  { key: 'policy_rejection', name: '인자·권한 거절', color: 'var(--color-status-info)' },
  { key: 'runtime_failure', name: '내부 오류', color: 'var(--color-status-err)' },
  { key: 'workflow_rejection', name: '업무 규칙 거절', color: 'var(--color-accent-fg)' },
  { key: 'operator_cancelled', name: '운영자 취소', color: 'var(--color-status-idle)' },
]

const UNCLASSIFIED_LINE_NAME = '종류 미기록'

/**
 * Failed calls per bucket, one line for each class they recorded and a dashed
 * line for the failures that recorded none. Together the lines add up to the
 * failure line of the call chart.
 */
export function failureClassSeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    ...FAILURE_CLASS_LINES.map(line => ({
      name: line.name,
      color: line.color,
      readings: bucketReadings(series, bucket => bucket.failure_classes[line.key]),
    })),
    {
      name: UNCLASSIFIED_LINE_NAME,
      color: 'var(--color-fg-muted)',
      dashed: true,
      readings: bucketReadings(series, bucket => bucket.failure_unclassified_count),
    },
  ]
}

/**
 * Time spent per bucket, and the part of it that went into calls running the
 * long-call line or more. Both are times, so they share one axis, and the
 * second line never rises above the first.
 */
export function timeSeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    { name: '실행 시간 합계', color: 'var(--color-accent-fg)', readings: bucketReadings(series, bucket => bucket.total_ms) },
    {
      name: longTimeLabel(series),
      color: 'var(--color-status-warn)',
      dashed: true,
      readings: bucketReadings(series, bucket => bucket.long_total_ms),
    },
  ]
}

/**
 * Result bytes per bucket. A bucket that holds a call stored before sizes were
 * kept sums fewer calls than it ran, so drawn it would read as a drop that did
 * not happen: it is a gap, like a bucket with no call.
 */
export function resultBytesSeries(series: ToolMetricsSeriesResponse): MetricChartSeries[] {
  return [
    {
      name: '결과 바이트 합계',
      color: 'var(--color-accent-fg)',
      readings: bucketReadings(series, bucket =>
        bucket.call_count > 0 && bucket.result_observed_count === bucket.call_count ? bucket.result_bytes_total : null,
      ),
    },
  ]
}

/** How many of the window's calls have no recorded size. */
export function unsizedCallCount(series: ToolMetricsSeriesResponse): number {
  return series.total.call_count - series.total.result_observed_count
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
  const unsized = unsizedCallCount(series)
  return html`
    <div class="grid grid-cols-[repeat(5,minmax(0,1fr))] gap-3 max-[520px]:grid-cols-[repeat(2,minmax(0,1fr))]">
      <${StatTile} label="호출" value=${formatCount(total.call_count)} status="brass" />
      <${StatTile} label="실패" value=${formatCount(total.failure_count)} status="brass" />
      <${StatTile} label="실패율" value=${formatFailureRate(total.call_count, total.failure_count)} status="brass" />
      <${StatTile} label="실행 시간 합계" value=${formatTotalTime(total.total_ms)} status="brass" />
      <${StatTile} label=${longCallLabel(series)} value=${formatCount(total.long_count)} status="brass" />
      <${StatTile} label=${longTimeLabel(series)} value=${formatTotalTime(total.long_total_ms)} status="brass" />
      <${StatTile} label="지연 p50" value=${formatMsCompact(total.p50_ms, '-')} status="brass" />
      <${StatTile} label="지연 p95" value=${formatMsCompact(total.p95_ms, '-')} status="brass" />
      <${StatTile} label="결과 바이트 합계" value=${formatObservedBytes(total.result_observed_count, total.result_bytes_total)} status="brass" />
      <${StatTile} label="가장 큰 결과" value=${total.result_bytes_max === null ? '-' : formatResultBytes(total.result_bytes_max)} status="brass" />
    </div>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 호출 수" unit="회" formatValue=${formatCount} series=${callSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 실패율" unit="%" formatValue=${formatPercent} series=${failureRateSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 실패 종류" unit="회" formatValue=${formatCount} series=${failureClassSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 실행 시간 합계" unit="ms" formatValue=${formatTotalTime} series=${timeSeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 지연 p50 / p95" unit="ms" formatValue=${(ms: number) => formatMsCompact(ms)} series=${latencySeries(series)} />
      <//>
      <${DetailCard}>
        <${ObservedMetricChart} label="구간별 결과 바이트 합계" unit="B" formatValue=${formatResultBytes} series=${resultBytesSeries(series)} />
      <//>
    </div>
    ${total.failure_unclassified_count > 0
      ? html`<p class="text-2xs text-[var(--color-fg-muted)]">실패 종류는 기록하기 시작한 뒤의 호출만 가려요. 이 구간 실패 ${formatCount(total.failure_count)} 중 ${formatCount(total.failure_unclassified_count)}는 종류가 없어서 '${UNCLASSIFIED_LINE_NAME}' 선에 따로 그렸어요.</p>`
      : null}
    ${unsized > 0
      ? html`<p class="text-2xs text-[var(--color-fg-muted)]">결과 바이트는 크기를 기록하기 시작한 뒤의 호출만 더해요. 이 구간 호출 ${formatCount(total.call_count)} 중 ${formatCount(unsized)}는 크기가 없어서 합계와 가장 큰 결과에 들어 있지 않고, 그런 호출이 든 구간은 그래프에서 뺐어요.</p>`
      : null}
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
            <th scope="col">시간 합계</th><th scope="col">${longCallLabel(series)}</th>
            <th scope="col">p50</th><th scope="col">p95</th><th scope="col">최대</th>
            <th scope="col">결과 바이트 합계</th><th scope="col">가장 큰 결과</th>
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
              <td>${row.long_count === 0 ? '-' : formatLongCalls(row.long_count, row.long_total_ms)}</td>
              <td>${formatMsCompact(row.p50_ms, '-')}</td>
              <td>${formatMsCompact(row.p95_ms, '-')}</td>
              <td>${formatMsCompact(row.max_ms, '-')}</td>
              <td>${formatObservedBytes(row.result_observed_count, row.result_bytes_total)}</td>
              <td>${row.result_bytes_max === null ? '-' : formatResultBytes(row.result_bytes_max)}</td>
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
