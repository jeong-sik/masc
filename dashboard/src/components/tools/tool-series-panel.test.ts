import { html } from 'htm/preact'
import { render } from 'preact'
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import type { ToolMetricsSeriesResponse } from '../../api/schemas/tool-metrics-series'
import {
  ToolSeriesView,
  FAILURE_CLASS_LINES,
  callSeries,
  failureClassSeries,
  formatFailureClasses,
  failureRatePercent,
  failureRateSeries,
  latencySeries,
  formatResultBytes,
  longCallLine,
  resultBytesSeries,
  timeSeries,
  unsizedCallCount,
  type ToolSeriesViewProps,
} from './tool-series-panel'
import { SERIES_WINDOW_ORDER } from './tool-series-state'

const container = document.createElement('div')
// A focused element is `document.activeElement` only while it is in the document.
beforeAll(() => document.body.append(container))
afterAll(() => container.remove())
afterEach(() => render(null, container))

// One of the ten calls ran 200 s, so 200 s of the 300 s spent were inside a long call.
const busy = {
  call_count: 10,
  failure_count: 2,
  failure_classes: {
    dependency_unavailable: 2,
    policy_rejection: 0,
    runtime_failure: 0,
    workflow_rejection: 0,
    operator_cancelled: 0,
  },
  failure_unclassified_count: 0,
  deferred_count: 0,
  total_ms: 300_000,
  p50_ms: 300,
  p95_ms: 900,
  max_ms: 200_000,
  long_count: 1,
  long_total_ms: 200_000,
  result_observed_count: 10,
  result_bytes_total: 5_242_880,
  result_bytes_max: 2_097_152,
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

const series: ToolMetricsSeriesResponse = {
  generated_at: 7200,
  window: { since: 0, until: 7200, bucket: 'hour', bucket_seconds: 3600, utc_offset_min: 0 },
  tool: null,
  long_call_ms: 60_000,
  total: busy,
  buckets: [
    { start: 0, ...idle },
    { start: 3600, ...busy },
  ],
  top_by_time: [
    { name: 'tool_execute', public_names: ['Execute'], ...busy },
    {
      name: 'tool_read_file',
      public_names: ['Read'],
      ...busy,
      call_count: 3,
      total_ms: 900,
      max_ms: 500,
      long_count: 0,
      long_total_ms: 0,
      result_observed_count: 3,
      result_bytes_total: 900,
      result_bytes_max: 500,
    },
  ],
  by_caller: [
    { caller: 'keeper-flaky', ...busy, failure_count: 2 },
    { caller: 'keeper-quiet', ...busy, call_count: 1, failure_count: 0, failure_classes: idle.failure_classes },
  ],
  caller_unobserved_count: 3,
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

/** Each stat tile's value under its label. */
function tileValues(): Record<string, string | null> {
  return Object.fromEntries(
    Array.from(container.querySelectorAll('.kpi-cell')).map(tile => [
      tile.querySelector('.kpi-label')?.textContent ?? '',
      tile.querySelector('.kpi-value')?.textContent ?? null,
    ]),
  )
}

/** The column titles of the table of tools, which is the first table. */
function toolTableHeader(): Array<string | null> {
  return Array.from(container.querySelector('table')?.querySelectorAll('thead th') ?? []).map(cell => cell.textContent)
}

/** The text of one column of the table of tools, one entry per row. */
function tableColumn(index: number): Array<string | undefined> {
  return Array.from(container.querySelector('table')?.querySelectorAll('tbody tr') ?? []).map(
    row => row.querySelectorAll('td')[index]?.textContent ?? undefined,
  )
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
  it('draws each failure class on its own line, and the unrecorded failures apart', () => {
    const lines = failureClassSeries(series)
    expect(lines.map(line => line.name)).toEqual([
      '외부 의존 불가',
      '인자·권한 거절',
      '내부 오류',
      '업무 규칙 거절',
      '운영자 취소',
      '종류 미기록',
    ])
    // The idle bucket first, then the busy one: two failures, both of one class.
    expect(lines[0]?.readings.map(reading => reading.value)).toEqual([0, 2])
    expect(lines[1]?.readings.map(reading => reading.value)).toEqual([0, 0])
    expect(lines[5]?.readings.map(reading => reading.value)).toEqual([0, 0])
    expect(lines[5]?.dashed).toBe(true)
  })

  it('has a line for every class the server sends', () => {
    expect(FAILURE_CLASS_LINES.map(line => line.key).sort()).toEqual(Object.keys(busy.failure_classes).sort())
  })

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

  it('draws the time inside long calls beside the time spent, on the same axis', () => {
    const [spent, inLongCalls] = timeSeries(series)
    expect(spent?.readings.map(reading => reading.value)).toEqual([0, 300_000])
    expect(inLongCalls?.name).toBe('1분 이상 걸린 시간')
    expect(inLongCalls?.readings.map(reading => reading.value)).toEqual([0, 200_000])
  })

  it('names the long-call line from the answer, not from a constant of the page', () => {
    expect(timeSeries({ ...series, long_call_ms: 90_000 })[1]?.name).toBe('90초 이상 걸린 시간')
  })
})

describe('result bytes', () => {
  it('writes a size in the largest unit that keeps it under a thousand and some', () => {
    expect(formatResultBytes(0)).toBe('0 B')
    expect(formatResultBytes(812)).toBe('812 B')
    expect(formatResultBytes(1_024)).toBe('1.0 KB')
    expect(formatResultBytes(4_915)).toBe('4.8 KB')
    expect(formatResultBytes(5_242_880)).toBe('5.0 MB')
    expect(formatResultBytes(1_395_864_371)).toBe('1.3 GB')
  })

  it('draws the bytes of each bucket, and a gap where no call ran', () => {
    const [bytes] = resultBytesSeries(series)
    expect(bytes?.name).toBe('결과 바이트 합계')
    expect(bytes?.readings.map(reading => reading.value)).toEqual([null, 5_242_880])
  })

  it('leaves a gap in a bucket that holds calls without a size, rather than draw a drop', () => {
    const partial: ToolMetricsSeriesResponse = {
      ...series,
      buckets: [
        { start: 0, ...busy, result_observed_count: 4, result_bytes_total: 1_000 },
        { start: 3600, ...busy },
      ],
    }
    expect(resultBytesSeries(partial)[0]?.readings.map(reading => reading.value)).toEqual([null, 5_242_880])
  })

  it('draws a bucket whose calls all returned nothing as zero bytes, not as a gap', () => {
    const empty: ToolMetricsSeriesResponse = {
      ...series,
      buckets: [{ start: 0, ...busy, result_bytes_total: 0, result_bytes_max: 0 }, { start: 3600, ...idle }],
    }
    expect(resultBytesSeries(empty)[0]?.readings.map(reading => reading.value)).toEqual([0, null])
  })

  it('counts the calls of the window that have no size', () => {
    expect(unsizedCallCount(series)).toBe(0)
    expect(unsizedCallCount({ ...series, total: { ...busy, result_observed_count: 4 } })).toBe(6)
  })
})

describe('longCallLine', () => {
  it('says whole minutes as minutes and any other line as seconds', () => {
    expect(longCallLine(60_000)).toBe('1분')
    expect(longCallLine(120_000)).toBe('2분')
    expect(longCallLine(90_000)).toBe('90초')
  })
})

describe('formatFailureClasses', () => {
  it('names each class that failed, with the unclassified ones last, and a dash when none failed', () => {
    const classes = { ...busy.failure_classes, dependency_unavailable: 2, runtime_failure: 1 }
    expect(formatFailureClasses({ ...busy, failure_classes: classes, failure_unclassified_count: 3 })).toBe(
      '외부 의존 불가 2회 · 내부 오류 1회 · 종류 미기록 3회',
    )
    expect(formatFailureClasses(idle)).toBe('-')
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
  it('draws the calls, the failure rate, the failure classes, the time spent and the latency, one chart each', () => {
    mount(view())
    const charts = Array.from(container.querySelectorAll('figure[aria-label]')).map(figure =>
      figure.getAttribute('aria-label'),
    )
    expect(charts).toEqual([
      '구간별 호출 수',
      '구간별 실패율',
      '구간별 실패 종류',
      '구간별 실행 시간 합계',
      '구간별 지연 p50 / p95',
      '구간별 결과 바이트 합계',
    ])
  })

  it('says how many failures recorded no class, and keeps the note out when none is missing', () => {
    mount(view())
    expect(container.textContent).not.toContain('종류가 없어서')
    mount(view({ series: { ...series, total: { ...series.total, failure_unclassified_count: 1 } } }))
    expect(container.textContent).toContain('종류가 없어서')
  })

  it('lists the tools that spent the most time, one row each', () => {
    mount(view())
    expect(toolButtons().map(button => button.textContent)).toEqual(['tool_execute', 'tool_read_file'])
  })

  it('lists the Keepers whose calls failed most, one row each, under the tools', () => {
    mount(view())
    const table = container.querySelectorAll('table')[1]
    const rows = Array.from(table?.querySelectorAll('tbody tr') ?? [])
    expect(rows.map(row => row.querySelectorAll('td')[0]?.textContent)).toEqual(['keeper-flaky', 'keeper-quiet'])
    expect(rows.map(row => row.querySelectorAll('td')[2]?.textContent)).toEqual(['2', '0'])
  })

  it('says how many calls have no caller only when some do not', () => {
    mount(view())
    expect(container.textContent).toContain('호출 3건은 부른 Keeper를 기록하지 않아')
    mount(view({ series: { ...series, caller_unobserved_count: 0 } }))
    expect(container.textContent).not.toContain('부른 Keeper를 기록하지 않아')
  })

  it('draws no Keeper table when no call has a caller, and still says so', () => {
    mount(view({ series: { ...series, by_caller: [] } }))
    expect(container.querySelectorAll('table')).toHaveLength(1)
    expect(container.textContent).toContain('부른 Keeper를 기록하지 않아')
    mount(view({ series: { ...series, by_caller: [], caller_unobserved_count: 0 } }))
    expect(container.querySelectorAll('table')).toHaveLength(1)
    expect(container.textContent).not.toContain('부른 Keeper를 기록하지 않아')
  })

  it('shows how many calls ran a minute or more, and the time they took', () => {
    mount(view())
    const tiles = tileValues()
    expect(tiles['1분 이상 걸린 호출']).toBe('1회')
    expect(tiles['1분 이상 걸린 시간']).toBe('3.3m')
  })

  it('shows the bytes the calls returned and the largest result', () => {
    mount(view())
    const tiles = tileValues()
    expect(tiles['결과 바이트 합계']).toBe('5.0 MB')
    expect(tiles['가장 큰 결과']).toBe('2.0 MB')
  })

  it('shows a dash, not zero bytes, when no call in the window has a size', () => {
    mount(view({ series: { ...series, total: { ...busy, result_observed_count: 0, result_bytes_total: 0, result_bytes_max: null } } }))
    const tiles = tileValues()
    expect(tiles['결과 바이트 합계']).toBe('-')
    expect(tiles['가장 큰 결과']).toBe('-')
  })

  it('puts the bytes of each tool in the table', () => {
    mount(view())
    const header = toolTableHeader()
    expect(header.slice(8)).toEqual(['결과 바이트 합계', '가장 큰 결과'])
    expect(tableColumn(8)).toEqual(['5.0 MB', '900 B'])
    expect(tableColumn(9)).toEqual(['2.0 MB', '500 B'])
  })

  it('says how many calls have no size only when some do not', () => {
    mount(view())
    expect(container.textContent).not.toContain('크기가 없어서')
    mount(view({ series: { ...series, total: { ...busy, result_observed_count: 4 } } }))
    expect(container.textContent).toContain('이 구간 호출 10회 중 6회는 크기가 없어서')
  })

  it('shows no long call as zero calls and no time', () => {
    mount(view({ series: { ...series, total: { ...series.total, long_count: 0, long_total_ms: 0 } } }))
    const tiles = tileValues()
    expect(tiles['1분 이상 걸린 호출']).toBe('0회')
    expect(tiles['1분 이상 걸린 시간']).toBe('0ms')
  })

  it('puts the long calls of each tool in the table, and a dash where it had none', () => {
    mount(view())
    const header = toolTableHeader()
    expect(header[4]).toBe('1분 이상 걸린 호출')
    expect(tableColumn(4)).toEqual(['1회 · 3.3m', '-'])
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
