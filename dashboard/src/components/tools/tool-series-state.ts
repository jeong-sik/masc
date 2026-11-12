// Tool call series — which window the Tools page charts, and the load of it.
//
// The window and the tool filter are what the viewer picked. A loaded series
// is kept with the request it answered. It is shown only while its window is
// still the picked one: a 30-day answer is not an answer for the 24-hour
// window the viewer has switched to. After the tool filter alone changes, the
// series of the previous filter stays until the new one arrives, so the table
// and the button the viewer pressed are not torn down and rebuilt.

import { computed, effect, signal, untracked } from '@preact/signals'
import { fetchToolMetricsSeries, type ToolMetricsSeriesRequest } from '../../api'
import type {
  ToolMetricsSeriesBucket,
  ToolMetricsSeriesResponse,
} from '../../api/schemas/tool-metrics-series'
import { createManagedAsyncResource } from '../../lib/async-state'
import { subscribeToolSeriesStream } from '../../api/tool-metrics-series-stream'
import type { MetricReading } from '../../lib/metric-series'

export const SERIES_WINDOWS = {
  day: { label: '24시간 · 시간별', sinceHours: 24, bucket: 'hour' },
  week: { label: '7일 · 시간별', sinceHours: 168, bucket: 'hour' },
  month: { label: '30일 · 일별', sinceHours: 720, bucket: 'day' },
} as const

export type SeriesWindowKey = keyof typeof SERIES_WINDOWS

/** The order the window chips are shown in. */
export const SERIES_WINDOW_ORDER: readonly SeriesWindowKey[] = ['day', 'week', 'month']

/** The server keeps 30 days of tool calls. Mounted charts consume snapshots. */
export const selectedWindow = signal<SeriesWindowKey>('day')
export const selectedTool = signal<string | null>(null)

/** Minutes east of UTC. `getTimezoneOffset` counts minutes west, so it is negated. */
export function currentUtcOffsetMin(now: { getTimezoneOffset(): number } = new Date()): number {
  const east = -now.getTimezoneOffset()
  return east === 0 ? 0 : east
}

const viewerUtcOffsetMin = signal(currentUtcOffsetMin())
const refreshRevision = signal(0)
let mounted = 0
let stopMounted: (() => void) | null = null

export function seriesRequest(
  windowKey: SeriesWindowKey,
  tool: string | null,
  utcOffsetMin: number,
): ToolMetricsSeriesRequest {
  const window = SERIES_WINDOWS[windowKey]
  return { sinceHours: window.sinceHours, bucket: window.bucket, utcOffsetMin, tool }
}

function sameWindow(a: ToolMetricsSeriesRequest, b: ToolMetricsSeriesRequest): boolean {
  return a.sinceHours === b.sinceHours && a.bucket === b.bucket && a.utcOffsetMin === b.utcOffsetMin
}

function pickedRequest(): ToolMetricsSeriesRequest {
  return seriesRequest(selectedWindow.value, selectedTool.value, viewerUtcOffsetMin.value)
}

interface LoadedSeries {
  readonly request: ToolMetricsSeriesRequest
  readonly series: ToolMetricsSeriesResponse
}

const seriesResource = createManagedAsyncResource<LoadedSeries>()

/**
 * The loaded series, only while it answers the window now picked. Its `tool`
 * field names the filter it answered; it differs from the picked tool until
 * the series of the picked tool arrives.
 */
export const visibleSeries = computed<ToolMetricsSeriesResponse | null>(() => {
  const loaded = seriesResource.state.value.data
  return loaded !== null && sameWindow(loaded.request, pickedRequest()) ? loaded.series : null
})
export const seriesLoading = computed(() => seriesResource.state.value.loading)
export const seriesError = computed<string | null>(() => seriesResource.state.value.error)

export async function loadToolSeries(): Promise<void> {
  if (mounted > 0) {
    refreshRevision.value = refreshRevision.peek() + 1
    return
  }
  const request = pickedRequest()
  await seriesResource.load(async signal => ({
    request,
    series: await fetchToolMetricsSeries(request, { signal }),
  }))
}

export function selectWindow(key: SeriesWindowKey): void {
  selectedWindow.value = key
  if (mounted === 0) void loadToolSeries()
}

export function selectTool(tool: string | null): void {
  selectedTool.value = tool
  if (mounted === 0) void loadToolSeries()
}

/** One native query lifetime for all mounted chart readers. Root metric
 * invalidations are consumed by the server stream, so they cause no GET here. */
export function subscribeToolSeriesRefresh(): () => void {
  mounted += 1
  if (mounted === 1) {
    // No stream owner observes authority changes while every chart is gone.
    // A new mount must await its own query before displaying retained data.
    seriesResource.reset()
    const updateOffset = () => { viewerUtcOffsetMin.value = currentUtcOffsetMin() }
    const visibleOffset = () => { if (document.visibilityState === 'visible') updateOffset() }
    window.addEventListener('focus', updateOffset)
    document.addEventListener('visibilitychange', visibleOffset)
    const stopQuery = effect(() => {
      refreshRevision.value
      const request = pickedRequest()
      return untracked(() => {
        seriesResource.cancel()
        const markLoading = () => {
          seriesResource.state.value = { ...seriesResource.state.peek(), loading: true, error: null }
        }
        markLoading()
        return subscribeToolSeriesStream(request, {
          onReset: reason => {
            if (reason === 'authority') seriesResource.reset()
            markLoading()
          },
          onFrame: series => { seriesResource.reset({ request, series }) },
          onError: error => {
            seriesResource.state.value = { ...seriesResource.state.peek(), loading: false, error: error.message }
          },
        })
      })
    })
    stopMounted = () => {
      stopQuery()
      seriesResource.cancel()
      window.removeEventListener('focus', updateOffset)
      document.removeEventListener('visibilitychange', visibleOffset)
    }
  }
  let released = false
  return () => {
    if (released) return
    released = true
    mounted -= 1
    if (mounted === 0) { stopMounted?.(); stopMounted = null }
  }
}

/**
 * Whether the window covers the bucket from its first second to its last.
 * The buckets at either end are usually cut short by the window. A cut-short
 * bucket holds fewer calls than a whole one, so drawn in a chart it reads as a
 * drop that did not happen.
 */
export function isWholeBucket(series: ToolMetricsSeriesResponse, bucket: ToolMetricsSeriesBucket): boolean {
  const { since, until, bucket_seconds } = series.window
  return bucket.start >= since && bucket.start + bucket_seconds <= until
}

/** How many buckets the charts leave out because the window cuts them short. */
export function cutShortBucketCount(series: ToolMetricsSeriesResponse): number {
  return series.buckets.filter(bucket => !isWholeBucket(series, bucket)).length
}

/** One value per whole bucket. A bucket in which no call ran gives null, a gap in the chart. */
export function bucketReadings(
  series: ToolMetricsSeriesResponse,
  pick: (bucket: ToolMetricsSeriesBucket) => number | null,
): MetricReading[] {
  return series.buckets
    .filter(bucket => isWholeBucket(series, bucket))
    .map(bucket => ({ ts: bucket.start, value: pick(bucket) }))
}
