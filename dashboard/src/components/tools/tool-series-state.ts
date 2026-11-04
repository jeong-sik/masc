// Tool call series — which window the Tools page charts, and the load of it.
//
// The window and the tool filter are what the viewer picked. A loaded series
// is kept with the request it answered, and it is shown only while that
// request is still the picked one: a 30-day answer is not an answer for the
// 24-hour window the viewer has switched to.

import { computed, signal } from '@preact/signals'
import { fetchToolMetricsSeries, type ToolMetricsSeriesRequest } from '../../api'
import type {
  ToolMetricsSeriesBucket,
  ToolMetricsSeriesResponse,
} from '../../api/schemas/tool-metrics-series'
import { createManagedAsyncResource } from '../../lib/async-state'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import type { MetricReading } from '../../lib/metric-series'

export const SERIES_WINDOWS = {
  day: { label: '24시간 · 시간별', sinceHours: 24, bucket: 'hour' },
  week: { label: '7일 · 시간별', sinceHours: 168, bucket: 'hour' },
  month: { label: '30일 · 일별', sinceHours: 720, bucket: 'day' },
} as const

export type SeriesWindowKey = keyof typeof SERIES_WINDOWS

/** The order the window chips are shown in. */
export const SERIES_WINDOW_ORDER: readonly SeriesWindowKey[] = ['day', 'week', 'month']

/** The server keeps 30 days of tool calls; a series answer is cached for 30 s. */
export const TOOL_SERIES_REFRESH_MS = 60_000

export const selectedWindow = signal<SeriesWindowKey>('day')
export const selectedTool = signal<string | null>(null)

/** Minutes east of UTC. `getTimezoneOffset` counts minutes west, so it is negated. */
export function currentUtcOffsetMin(now: { getTimezoneOffset(): number } = new Date()): number {
  const east = -now.getTimezoneOffset()
  return east === 0 ? 0 : east
}

export function seriesRequest(
  windowKey: SeriesWindowKey,
  tool: string | null,
  utcOffsetMin: number,
): ToolMetricsSeriesRequest {
  const window = SERIES_WINDOWS[windowKey]
  return { sinceHours: window.sinceHours, bucket: window.bucket, utcOffsetMin, tool }
}

export function seriesKey(request: ToolMetricsSeriesRequest): string {
  return JSON.stringify([request.sinceHours, request.bucket, request.utcOffsetMin, request.tool])
}

function pickedRequest(): ToolMetricsSeriesRequest {
  return seriesRequest(selectedWindow.value, selectedTool.value, currentUtcOffsetMin())
}

interface LoadedSeries {
  readonly key: string
  readonly series: ToolMetricsSeriesResponse
}

const seriesResource = createManagedAsyncResource<LoadedSeries>()

/** The loaded series, only while it answers the window and tool now picked. */
export const visibleSeries = computed<ToolMetricsSeriesResponse | null>(() => {
  const loaded = seriesResource.state.value.data
  return loaded !== null && loaded.key === seriesKey(pickedRequest()) ? loaded.series : null
})
export const seriesLoading = computed(() => seriesResource.state.value.loading)
export const seriesError = computed<string | null>(() => seriesResource.state.value.error)

export async function loadToolSeries(): Promise<void> {
  const request = pickedRequest()
  const key = seriesKey(request)
  await seriesResource.load(async signal => ({
    key,
    series: await fetchToolMetricsSeries(request, { signal }),
  }))
}

export function selectWindow(key: SeriesWindowKey): void {
  selectedWindow.value = key
  void loadToolSeries()
}

export function selectTool(tool: string | null): void {
  selectedTool.value = tool
  void loadToolSeries()
}

/** Load once, then again every [TOOL_SERIES_REFRESH_MS] while the page is visible. */
export function subscribeToolSeriesRefresh(): () => void {
  void loadToolSeries()
  return setupVisibleAutoRefresh(() => {
    void loadToolSeries()
  }, TOOL_SERIES_REFRESH_MS)
}

/** One value per bucket. A bucket in which no call ran gives null, a gap in the chart. */
export function bucketReadings(
  series: ToolMetricsSeriesResponse,
  pick: (bucket: ToolMetricsSeriesBucket) => number | null,
): MetricReading[] {
  return series.buckets.map(bucket => ({ ts: bucket.start, value: pick(bucket) }))
}
