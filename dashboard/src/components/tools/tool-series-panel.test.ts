import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'
import {
  ToolSeriesView,
  callSeries,
  failureRatePercent,
  latencySeries,
  type ToolSeriesViewProps,
} from './tool-series-panel'
import { SERIES_WINDOW_ORDER } from './tool-series-state'

const container = document.createElement('div')
afterEach(() => render(null, container))

const busy = {
  call_count: 10,
  failure_count: 2,
  deferred_count: 0,
  total_ms: 5000,
  p50_ms: 300,
  p95_ms: 900,
  max_ms: 1200,
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

const series: ToolMetricsSeriesResponse = {
  generated_at: 7200,
  window: { since: 0, until: 7200, bucket: 'hour', bucket_seconds: 3600, utc_offset_min: 0 },
  tool: null,
  total: busy,
  buckets: [
    { start: 0, ...idle },
    { start: 3600, ...busy },
  ],
  top_by_time: [
    { name: 'tool_execute', public_names: ['Execute'], ...busy },
    { name: 'tool_read_file', public_names: ['Read'], ...busy, call_count: 3 },
  ],
}

function view(overrides: Partial<ToolSeriesViewProps> = {}): ToolSeriesViewProps {
  return {
    series,
    loading: false,
    error: null,
    windowKey: 'day',
    tool: null,
    onWindow: vi.fn(),
    onTool: vi.fn(),
    ...overrides,
  }
}

function mount(props: ToolSeriesViewProps): void {
  render(html`<${ToolSeriesView} ...${props} />`, container)
}

function toolButtons(): HTMLButtonElement[] {
  return Array.from(container.querySelectorAll<HTMLButtonElement>('tbody button'))
}

describe('chart series', () => {
  it('draws failures beside calls, from the same buckets', () => {
    const [calls, failures] = callSeries(series)
    expect(calls?.readings.map(reading => reading.value)).toEqual([0, 10])
    expect(failures?.readings.map(reading => reading.value)).toEqual([0, 2])
  })

  it('leaves a gap in latency where no call ran', () => {
    const [p95, p50] = latencySeries(series)
    expect(p95?.readings.map(reading => reading.value)).toEqual([null, 900])
    expect(p50?.readings.map(reading => reading.value)).toEqual([null, 300])
  })

  it('places each reading at the start of its bucket', () => {
    expect(callSeries(series)[0]?.readings.map(reading => reading.ts)).toEqual([0, 3600])
  })
})

describe('failureRatePercent', () => {
  it('is the share of failed calls', () => {
    expect(failureRatePercent(4, 1)).toBe(25)
  })

  it('is not a number when nothing ran', () => {
    expect(failureRatePercent(0, 0)).toBeNull()
  })
})

describe('ToolSeriesView', () => {
  it('lists the tools that spent the most time, one row each', () => {
    mount(view())
    expect(toolButtons().map(button => button.textContent)).toEqual(['tool_execute', 'tool_read_file'])
  })

  it('picks a tool when its name is pressed', () => {
    const props = view()
    mount(props)
    toolButtons()[1]?.click()
    expect(props.onTool).toHaveBeenCalledWith('tool_read_file')
  })

  it('clears the filter when the picked tool is pressed again', () => {
    const props = view({ tool: 'tool_execute' })
    mount(props)
    toolButtons()[0]?.click()
    expect(props.onTool).toHaveBeenCalledWith(null)
  })

  it('picks a window when its chip is pressed', () => {
    const props = view()
    mount(props)
    const chips = container.querySelectorAll<HTMLButtonElement>('[role="tab"]')
    chips[SERIES_WINDOW_ORDER.indexOf('month')]?.click()
    expect(props.onWindow).toHaveBeenCalledWith('month')
  })

  it('draws no table before an answer has arrived', () => {
    mount(view({ series: null, loading: true }))
    expect(container.querySelector('table')).toBeNull()
  })

  it('draws no table, and still the window chips, when the load failed', () => {
    mount(view({ series: null, error: 'server unavailable' }))
    expect(container.querySelector('table')).toBeNull()
    expect(container.querySelectorAll('[role="tab"]')).toHaveLength(SERIES_WINDOW_ORDER.length)
  })

  it('keeps the last answer on screen next to a failed refresh', () => {
    mount(view({ error: 'server unavailable' }))
    expect(toolButtons()).toHaveLength(2)
  })
})
