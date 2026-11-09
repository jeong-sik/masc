import { html } from 'htm/preact'
import { render } from 'preact'
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import type { ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'
import {
  ToolSeriesView,
  callSeries,
  failureRatePercent,
  failureRateSeries,
  latencySeries,
  type ToolSeriesViewProps,
} from './tool-series-panel'
import { SERIES_WINDOW_ORDER } from './tool-series-state'

const container = document.createElement('div')
// A focused element is `document.activeElement` only while it is in the document.
beforeAll(() => document.body.append(container))
afterAll(() => container.remove())
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

describe('picking a tool', () => {
  // The second row: without row keys the filtered table would reuse the first
  // row's element and drop the pressed one.
  const picked = 'tool_read_file'
  const pickedOnly: ToolMetricsSeriesResponse = {
    ...series,
    tool: picked,
    top_by_time: series.top_by_time.filter(row => row.name === picked),
  }

  // A keyboard user pressed the button. Rebuilding the table while the filtered
  // series loads would remove it and send the focus to the page.
  it('keeps the pressed button, with its focus, while the filtered series loads and after', () => {
    mount(view())
    const pressed = toolButtons().find(button => button.textContent === picked)
    expect(pressed).toBeDefined()
    pressed?.focus()

    mount(view({ tool: picked, loading: true }))
    expect(toolButtons().find(button => button.textContent === picked)).toBe(pressed)
    expect(document.activeElement).toBe(pressed)
    expect(container.querySelector('[aria-busy]')?.getAttribute('aria-busy')).toBe('true')

    mount(view({ tool: picked, series: pickedOnly }))
    expect(toolButtons()).toEqual([pressed])
    expect(document.activeElement).toBe(pressed)
    expect(container.querySelector('[aria-busy]')?.getAttribute('aria-busy')).toBe('false')
  })
})

describe('chart series', () => {
  it('draws failures beside calls, from the same buckets', () => {
    const [calls, failures] = callSeries(series)
    expect(calls?.readings.map(reading => reading.value)).toEqual([0, 10])
    expect(failures?.readings.map(reading => reading.value)).toEqual([0, 2])
  })

  it('draws the share of failed calls per bucket, and a gap where no call ran', () => {
    const [rate] = failureRateSeries(series)
    expect(rate?.name).toBe('실패율')
    expect(rate?.readings.map(reading => reading.value)).toEqual([null, 20])
  })

  it('reads the rate of a bucket from that bucket, not from the window total', () => {
    const lopsided: ToolMetricsSeriesResponse = {
      ...series,
      buckets: [
        { start: 0, ...busy, call_count: 100, failure_count: 1 },
        { start: 3600, ...busy, call_count: 4, failure_count: 3 },
      ],
    }
    expect(failureRateSeries(lopsided)[0]?.readings.map(reading => reading.value)).toEqual([1, 75])
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
  it('draws the calls, the failure rate, the time spent and the latency, one chart each', () => {
    mount(view())
    const charts = Array.from(container.querySelectorAll('figure[aria-label]')).map(figure =>
      figure.getAttribute('aria-label'),
    )
    expect(charts).toEqual([
      '구간별 호출 수',
      '구간별 실패율',
      '구간별 실행 시간 합계',
      '구간별 지연 p50 / p95',
    ])
  })

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
