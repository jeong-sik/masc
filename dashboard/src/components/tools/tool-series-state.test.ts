import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'

const { fetchToolMetricsSeries, setupVisibleAutoRefresh, stopRefresh } = vi.hoisted(() => ({
  fetchToolMetricsSeries: vi.fn(),
  setupVisibleAutoRefresh: vi.fn(),
  stopRefresh: vi.fn(),
}))

vi.mock('../../api', () => ({ fetchToolMetricsSeries }))
vi.mock('../../lib/auto-refresh', () => ({ setupVisibleAutoRefresh }))

type State = typeof import('./tool-series-state')
let state: State

const busy = {
  call_count: 4,
  failure_count: 1,
  deferred_count: 0,
  total_ms: 400,
  p50_ms: 80,
  p95_ms: 150,
  max_ms: 150,
}
const idle = {
  call_count: 0,
  failure_count: 0,
  deferred_count: 0,
  total_ms: 0,
  p50_ms: null,
  p95_ms: null,
  max_ms: null,
}

function series(overrides: Partial<ToolMetricsSeriesResponse> = {}): ToolMetricsSeriesResponse {
  return {
    generated_at: 100,
    window: { since: 0, until: 7200, bucket: 'hour', bucket_seconds: 3600, utc_offset_min: 0 },
    tool: null,
    total: busy,
    buckets: [
      { start: 0, ...idle },
      { start: 3600, ...busy },
    ],
    top_by_time: [],
    ...overrides,
  }
}

// The state module keeps what was picked and what was loaded at module level.
// A fresh module per case keeps one case's answer from being read by the next.
beforeEach(async () => {
  vi.resetModules()
  fetchToolMetricsSeries.mockReset()
  setupVisibleAutoRefresh.mockReset()
  setupVisibleAutoRefresh.mockReturnValue(stopRefresh)
  stopRefresh.mockReset()
  state = await import('./tool-series-state')
})

describe('currentUtcOffsetMin', () => {
  it('counts minutes east of UTC, the reverse of getTimezoneOffset', () => {
    expect(state.currentUtcOffsetMin({ getTimezoneOffset: () => -540 })).toBe(540)
    expect(state.currentUtcOffsetMin({ getTimezoneOffset: () => 300 })).toBe(-300)
  })

  it('gives plain zero for UTC', () => {
    expect(Object.is(state.currentUtcOffsetMin({ getTimezoneOffset: () => 0 }), 0)).toBe(true)
  })
})

describe('window presets', () => {
  // The server refuses a window longer than 31 days (Tool_metrics_series.max_window_days).
  it('stay inside the longest window the server accepts', () => {
    const MAX_SERVER_WINDOW_HOURS = 31 * 24
    for (const key of state.SERIES_WINDOW_ORDER) {
      expect(state.SERIES_WINDOWS[key].sinceHours).toBeLessThanOrEqual(MAX_SERVER_WINDOW_HOURS)
    }
  })

  it('build the request the server reads', () => {
    expect(state.seriesRequest('month', 'tool_execute', 540)).toEqual({
      sinceHours: state.SERIES_WINDOWS.month.sinceHours,
      bucket: 'day',
      utcOffsetMin: 540,
      tool: 'tool_execute',
    })
  })
})

describe('bucketReadings', () => {
  it('leaves a gap where the bucket has no value', () => {
    const readings = state.bucketReadings(series(), bucket => bucket.p95_ms)
    expect(readings).toEqual([
      { ts: 0, value: null },
      { ts: 3600, value: 150 },
    ])
  })
})

describe('loading the picked window', () => {
  it('asks for the window and the tool that are picked', async () => {
    fetchToolMetricsSeries.mockResolvedValue(series())
    state.selectedWindow.value = 'week'
    state.selectedTool.value = 'tool_execute'
    await state.loadToolSeries()
    expect(fetchToolMetricsSeries).toHaveBeenCalledTimes(1)
    expect(fetchToolMetricsSeries.mock.calls[0]?.[0]).toEqual(
      state.seriesRequest('week', 'tool_execute', state.currentUtcOffsetMin()),
    )
  })

  it('shows the answer for the picked window', async () => {
    const day = series()
    fetchToolMetricsSeries.mockResolvedValue(day)
    await state.loadToolSeries()
    expect(state.visibleSeries.value).toEqual(day)
  })

  it('hides an answer once another window is picked, until that one is loaded', async () => {
    const day = series()
    const month = series({ tool: null, total: { ...busy, call_count: 99 } })
    fetchToolMetricsSeries.mockResolvedValueOnce(day).mockResolvedValueOnce(month)
    await state.loadToolSeries()
    expect(state.visibleSeries.value).toEqual(day)

    let finishMonth: () => void = () => {}
    fetchToolMetricsSeries.mockReset()
    fetchToolMetricsSeries.mockImplementation(
      () => new Promise<ToolMetricsSeriesResponse>(resolve => { finishMonth = () => resolve(month) }),
    )
    state.selectWindow('month')
    expect(state.visibleSeries.value).toBeNull()
    expect(state.seriesLoading.value).toBe(true)

    finishMonth()
    await vi.waitFor(() => expect(state.visibleSeries.value).toEqual(month))
  })

  it('reloads when a tool is picked and when the filter is cleared', async () => {
    fetchToolMetricsSeries.mockResolvedValue(series())
    state.selectTool('tool_execute')
    await vi.waitFor(() => expect(fetchToolMetricsSeries).toHaveBeenCalledTimes(1))
    expect(fetchToolMetricsSeries.mock.calls[0]?.[0]).toMatchObject({ tool: 'tool_execute' })

    state.selectTool(null)
    await vi.waitFor(() => expect(fetchToolMetricsSeries).toHaveBeenCalledTimes(2))
    expect(fetchToolMetricsSeries.mock.calls[1]?.[0]).toMatchObject({ tool: null })
  })

  it('keeps the last answer on screen and reports the error when a refresh fails', async () => {
    const day = series()
    fetchToolMetricsSeries.mockResolvedValueOnce(day).mockRejectedValueOnce(new Error('server unavailable'))
    await state.loadToolSeries()
    await state.loadToolSeries()
    expect(state.visibleSeries.value).toEqual(day)
    expect(state.seriesError.value).toBe('server unavailable')
  })
})

describe('subscribeToolSeriesRefresh', () => {
  it('loads at once and keeps refreshing until the disposer runs', async () => {
    fetchToolMetricsSeries.mockResolvedValue(series())
    const dispose = state.subscribeToolSeriesRefresh()
    await vi.waitFor(() => expect(fetchToolMetricsSeries).toHaveBeenCalledTimes(1))
    expect(setupVisibleAutoRefresh).toHaveBeenCalledWith(expect.any(Function), state.TOOL_SERIES_REFRESH_MS)

    const refresh = setupVisibleAutoRefresh.mock.calls[0]?.[0] as () => void
    refresh()
    await vi.waitFor(() => expect(fetchToolMetricsSeries).toHaveBeenCalledTimes(2))

    dispose()
    expect(stopRefresh).toHaveBeenCalledTimes(1)
  })
})
