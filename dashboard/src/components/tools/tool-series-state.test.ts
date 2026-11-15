import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'

const { fetchToolMetricsSeries, subscribeToolSeriesStream } = vi.hoisted(() => ({
  fetchToolMetricsSeries: vi.fn(), subscribeToolSeriesStream: vi.fn(),
}))

vi.mock('../../api', () => ({ fetchToolMetricsSeries }))
vi.mock('../../api/tool-metrics-series-stream', () => ({ subscribeToolSeriesStream }))

type State = typeof import('./tool-series-state')
let state: State

const busy = {
  call_count: 4,
  failure_count: 1,
  failure_classes: {
    dependency_unavailable: 1,
    policy_rejection: 0,
    runtime_failure: 0,
    workflow_rejection: 0,
    operator_cancelled: 0,
  },
  failure_unclassified_count: 0,
  deferred_count: 0,
  total_ms: 400,
  p50_ms: 80,
  p95_ms: 150,
  max_ms: 150,
  long_count: 0,
  long_total_ms: 0,
  result_observed_count: 4,
  result_bytes_total: 4_000,
  result_bytes_max: 2_000,
}
const idle = {
  call_count: 0,
  failure_count: 0,
  failure_classes: {
    dependency_unavailable: 0,
    policy_rejection: 0,
    runtime_failure: 0,
    workflow_rejection: 0,
    operator_cancelled: 0,
  },
  failure_unclassified_count: 0,
  deferred_count: 0,
  total_ms: 0,
  p50_ms: null,
  p95_ms: null,
  max_ms: null,
  long_count: 0,
  long_total_ms: 0,
  result_observed_count: 0,
  result_bytes_total: 0,
  result_bytes_max: null,
}

function series(overrides: Partial<ToolMetricsSeriesResponse> = {}): ToolMetricsSeriesResponse {
  return {
    generated_at: 100,
    window: { since: 0, until: 7200, bucket: 'hour', bucket_seconds: 3600, utc_offset_min: 0 },
    tool: null,
    long_call_ms: 60_000,
    total: busy,
    buckets: [
      { start: 0, ...idle },
      { start: 3600, ...busy },
    ],
    top_by_time: [],
    by_caller: [],
    caller_unobserved_count: 0,
    ...overrides,
  }
}

// The state module keeps what was picked and what was loaded at module level.
// A fresh module per case keeps one case's answer from being read by the next.
beforeEach(async () => {
  vi.resetModules()
  fetchToolMetricsSeries.mockReset()
  subscribeToolSeriesStream.mockReset().mockReturnValue(vi.fn())
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

  // A bucket the window cuts short holds fewer calls than a whole one, so a
  // chart that drew it would show a drop that never happened.
  const cutAtBothEnds = series({
    window: { since: 1800, until: 9000, bucket: 'hour', bucket_seconds: 3600, utc_offset_min: 0 },
    buckets: [
      { start: 0, ...busy },
      { start: 3600, ...busy, p95_ms: 10 },
      { start: 7200, ...busy },
    ],
  })

  it('leaves out the buckets the window cuts short at either end', () => {
    expect(state.bucketReadings(cutAtBothEnds, bucket => bucket.p95_ms)).toEqual([{ ts: 3600, value: 10 }])
  })

  it('counts the buckets it left out', () => {
    expect(state.cutShortBucketCount(cutAtBothEnds)).toBe(2)
  })

  it('keeps every bucket of a window that lines up with its buckets', () => {
    expect(state.cutShortBucketCount(series())).toBe(0)
    expect(state.bucketReadings(series(), bucket => bucket.call_count)).toHaveLength(2)
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

  // Rebuilding the table when a tool button is pressed drops the keyboard
  // focus with the button, so the previous filter's answer stays until the
  // picked tool's answer arrives.
  it('keeps the previous filter\'s answer on screen until the picked tool\'s answer arrives', async () => {
    const all = series()
    const execute = series({ tool: 'tool_execute', total: { ...busy, call_count: 9 } })
    fetchToolMetricsSeries.mockResolvedValueOnce(all)
    await state.loadToolSeries()

    let finishExecute: () => void = () => {}
    fetchToolMetricsSeries.mockImplementation(
      () => new Promise<ToolMetricsSeriesResponse>(resolve => { finishExecute = () => resolve(execute) }),
    )
    state.selectTool('tool_execute')
    expect(state.visibleSeries.value).toEqual(all)
    expect(state.seriesLoading.value).toBe(true)

    finishExecute()
    await vi.waitFor(() => expect(state.visibleSeries.value).toEqual(execute))
  })

  it('drops an answer that arrives after a later pick was answered', async () => {
    const week = series({ total: { ...busy, call_count: 7 } })
    const month = series({ total: { ...busy, call_count: 30 } })
    const finish: Array<() => void> = []
    fetchToolMetricsSeries.mockImplementation(
      (request: { bucket: string }) =>
        new Promise<ToolMetricsSeriesResponse>(resolve => {
          finish.push(() => resolve(request.bucket === 'day' ? month : week))
        }),
    )
    state.selectWindow('week')
    state.selectWindow('month')
    expect(finish).toHaveLength(2)

    finish[1]?.()
    await vi.waitFor(() => expect(state.visibleSeries.value).toEqual(month))
    finish[0]?.()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(state.visibleSeries.value).toEqual(month)
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
  it('withdraws the previous workspace series after token and authority change between mounts', async () => {
    const store = await import('../../store')
    const { setStoredToken, clearStoredToken } = await import('../../api/core')
    const workspace = (root: string, generation: number) => ({
      projection_diagnostics: { read_completeness: 'complete', read_error: null },
      generated_at: '2026-11-10T00:00:00Z',
      execution_publication_epoch: 'series-remount', execution_publication_generation: generation,
      status: { project: 'series', workspace_root: root }, agents: [], tasks: [], messages: [],
      keepers: [], execution_queue: [], worker_support_briefs: [], continuity_briefs: [],
    })
    expect(store.hydrateExecutionSnapshot(workspace('/workspace-a', 1))).toBe(true)
    const stop = state.subscribeToolSeriesRefresh()
    subscribeToolSeriesStream.mock.calls[0]![1].onFrame(series())
    expect(state.visibleSeries.value).not.toBeNull()
    stop()
    setStoredToken('workspace-b-token', { source: 'manual' })
    expect(store.hydrateExecutionSnapshot(workspace('/workspace-b', 2))).toBe(true)
    expect(store.executionWorkspaceAuthority.peek()?.workspaceRoot).toBe('/workspace-b')
    const remounted = state.subscribeToolSeriesRefresh()
    try {
      expect(state.visibleSeries.value).toBeNull()
      expect(state.seriesLoading.value).toBe(true)
      expect(fetchToolMetricsSeries).not.toHaveBeenCalled()
      subscribeToolSeriesStream.mock.calls[1]![1].onFrame(series({ total: { ...busy, call_count: 99 } }))
      expect(state.visibleSeries.value?.total.call_count).toBe(99)
    } finally { remounted(); clearStoredToken() }
  })

  it('mounts one native query, applies snapshots and releases the last reader without GET', async () => {
    const { publishDashboardObservationChange } = await import('../../lib/observation-refresh')
    const release = vi.fn()
    subscribeToolSeriesStream.mockReturnValue(release)
    const dispose = state.subscribeToolSeriesRefresh()
    const second = state.subscribeToolSeriesRefresh()
    try {
      expect(subscribeToolSeriesStream).toHaveBeenCalledTimes(1)
      const reader = subscribeToolSeriesStream.mock.calls[0]![1]
      reader.onFrame(series())
      expect(state.visibleSeries.value).toEqual(series())
      publishDashboardObservationChange({ topic: 'logs' })
      publishDashboardObservationChange({ topic: 'tool_metrics' })
      expect(subscribeToolSeriesStream).toHaveBeenCalledTimes(1)
      expect(fetchToolMetricsSeries).not.toHaveBeenCalled()
      dispose()
      expect(release).not.toHaveBeenCalled()
    } finally { dispose(); second() }
    expect(release).toHaveBeenCalledTimes(1)
  })

  it('replaces the mounted query on selection and manual refresh, preserves filter data until the next frame', async () => {
    const release = vi.fn()
    subscribeToolSeriesStream.mockReturnValue(release)
    const dispose = state.subscribeToolSeriesRefresh()
    try {
      subscribeToolSeriesStream.mock.calls[0]![1].onFrame(series())
      state.selectTool('tool_execute')
      expect(release).toHaveBeenCalledTimes(1)
      expect(state.visibleSeries.value?.tool).toBeNull()
      expect(subscribeToolSeriesStream.mock.calls[1]![0].tool).toBe('tool_execute')
      subscribeToolSeriesStream.mock.calls[1]![1].onFrame(series({ tool: 'tool_execute' }))
      expect(state.visibleSeries.value?.tool).toBe('tool_execute')
      await state.loadToolSeries()
      expect(subscribeToolSeriesStream).toHaveBeenCalledTimes(3)
      expect(fetchToolMetricsSeries).not.toHaveBeenCalled()
      subscribeToolSeriesStream.mock.calls[2]![1].onReset('authority')
      expect(state.visibleSeries.value).toBeNull()
    } finally { dispose() }
  })
})
