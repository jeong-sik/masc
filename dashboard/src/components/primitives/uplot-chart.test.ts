// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type uPlot from 'uplot'
import { resetTimeWindowForTests } from '../../core/time-window'
import { UPlotChart, type UPlotSeriesSpec } from './uplot-chart'
import { LEGEND_NO_VALUE, LEGEND_TIME_LABEL, LEGEND_TIME_STAMP } from './uplot-legend'

const HOUR = 3600
const T0 = 1_800_000_000

// The first chart covers ten hours. The second starts six hours in, and its
// second series has no value at the latest point.
const wholeData: uPlot.AlignedData = [[T0, T0 + 5 * HOUR, T0 + 10 * HOUR], [10, 20, 30]]
const lateData: uPlot.AlignedData = [[T0 + 6 * HOUR, T0 + 10 * HOUR], [1, 2], [7, null]]
const wholeSeries: readonly UPlotSeriesSpec[] = [{ label: '사용률', unit: '%' }]
const lateSeries: readonly UPlotSeriesSpec[] = [{ label: '요청' }, { label: '오류' }]

/** A 2D context that draws nothing: uPlot only needs the width of a text back. */
function blankContext(): CanvasRenderingContext2D {
  const held: Record<string | symbol, unknown> = { measureText: (text: string) => ({ width: text.length * 7 }) }
  return new Proxy(held, {
    get: (target, key) => target[key] ?? (() => undefined),
    set: (target, key, value) => {
      target[key] = value
      return true
    },
  }) as unknown as CanvasRenderingContext2D
}

class BlankPath2D {
  moveTo() {}
  lineTo() {}
  rect() {}
  arc() {}
  closePath() {}
  addPath() {}
}

describe('components/primitives uplot chart legend', () => {
  let container: HTMLDivElement
  let timeText: (seconds: number) => string

  /** The legend of chart `index`: each row's label and value, and each value's reserved width. */
  const legend = (index: number) => {
    const rows = [...container.querySelectorAll('.u-legend')[index]!.querySelectorAll('.u-series')]
    return {
      labels: rows.map((row) => row.querySelector('.u-label')?.textContent),
      values: rows.map((row) => row.querySelector('.u-value')?.textContent),
      widths: rows.map((row) => row.querySelector<HTMLElement>('.u-value')?.style.minWidth),
    }
  }

  /** Moves the pointer to `fraction` of the way across the plotting area of chart `index`. */
  const movePointer = (index: number, fraction: number) => {
    const over = container.querySelectorAll<HTMLElement>('.u-over')[index]!
    const clientX = Number.parseFloat(over.style.width) * fraction
    over.dispatchEvent(new MouseEvent('mousemove', { clientX, clientY: 20, bubbles: true }))
  }

  const renderCharts = (first: uPlot.AlignedData) => {
    render(
      html`
        <${UPlotChart} id="whole" title="whole" data=${first} series=${wholeSeries} />
        <${UPlotChart} id="late" title="late" data=${lateData} series=${lateSeries} />
      `,
      container,
    )
  }

  beforeEach(async () => {
    // uPlot watches the pixel ratio through a media query, which jsdom lacks.
    vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
    vi.stubGlobal('Path2D', BlankPath2D)
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(() => blankContext())
    resetTimeWindowForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
    const stamp = (await import('uplot')).default.fmtDate(LEGEND_TIME_STAMP)
    timeText = (seconds) => stamp(new Date(seconds * 1000))
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('reads the latest point with the pointer on no chart, one time for all of a chart\'s series', async () => {
    renderCharts(wholeData)
    await vi.waitFor(() => expect(container.querySelectorAll('.u-legend')).toHaveLength(2))

    expect(legend(0)).toEqual({
      labels: [LEGEND_TIME_LABEL, '사용률'],
      values: [timeText(T0 + 10 * HOUR), '30 %'],
      widths: [expect.stringMatching(/^1[78]ch$/), '4ch'],
    })
    // 오류 has no value at the latest time, and does not borrow the earlier one.
    expect(legend(1).values).toEqual([timeText(T0 + 10 * HOUR), '2', LEGEND_NO_VALUE])
    expect(legend(1).widths).toEqual([expect.stringMatching(/^1[78]ch$/), '4ch', '4ch'])
  })

  it('reads each chart\'s crosshair point, and none on a chart the pointed time comes before', async () => {
    renderCharts(wholeData)
    await vi.waitFor(() => expect(container.querySelectorAll('.u-over')).toHaveLength(2))
    await vi.waitFor(() => expect(Number.parseFloat(container.querySelector<HTMLElement>('.u-over')!.style.width)).toBeGreaterThan(0))

    // 12 minutes in: the second chart has no point for five more hours.
    movePointer(0, 0.02)
    expect(legend(0).values).toEqual([timeText(T0), '10 %'])
    expect(legend(1).values).toEqual([LEGEND_NO_VALUE, LEGEND_NO_VALUE, LEGEND_NO_VALUE])

    // Six and a half hours in: both charts have a point near.
    movePointer(0, 0.65)
    expect(legend(0).values).toEqual([timeText(T0 + 5 * HOUR), '20 %'])
    expect(legend(1).values).toEqual([timeText(T0 + 6 * HOUR), '1', '7'])

    container.querySelector('.u-over')!.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }))
    expect(legend(0).values).toEqual([timeText(T0 + 10 * HOUR), '30 %'])
    expect(legend(1).values).toEqual([timeText(T0 + 10 * HOUR), '2', LEGEND_NO_VALUE])
  })

  it('reads the new latest point, and reserves its width, when the data changes', async () => {
    renderCharts(wholeData)
    await vi.waitFor(() => expect(container.querySelectorAll('.u-legend')).toHaveLength(2))

    renderCharts([[T0, T0 + 5 * HOUR, T0 + 10 * HOUR, T0 + 11 * HOUR], [10, 20, 30, 123.456]])

    await vi.waitFor(() => expect(legend(0).values).toEqual([timeText(T0 + 11 * HOUR), '123.46 %']))
    expect(legend(0).widths[1]).toBe('8ch')
  })
})
