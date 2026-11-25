// @vitest-environment jsdom

import { describe, expect, it } from 'vitest'
import {
  LEGEND_NO_VALUE,
  displayColumns,
  legendPointIndex,
  legendText,
  legendValueColumns,
  pointerOnAny,
  reserveLegendValueWidths,
} from './uplot-legend'

describe('components/primitives uplot legend', () => {
  it('reads the crosshair\'s point, and the latest one with the pointer on no chart', () => {
    expect(legendPointIndex(3, true, 21)).toBe(3)
    expect(legendPointIndex(0, true, 21)).toBe(0)
    expect(legendPointIndex(null, false, 21)).toBe(20)
    expect(legendPointIndex(null, false, 0)).toBeNull()
  })

  it('reads no point with the pointer on another chart at a time this one has no crosshair for', () => {
    expect(legendPointIndex(null, true, 21)).toBeNull()
  })

  it('finds the pointer on the chart that holds a mouse event inside its plotting area', () => {
    const moved = { type: 'mousemove' }
    // What uPlot keeps for a chart at rest, for one that follows another chart's
    // crosshair, and for one the pointer has left.
    const atRest = { left: -10, event: undefined }
    const following = { left: 240.5, event: null }
    const followingBeforeItsRange = { left: -310.2, event: null }
    const left = { left: -10, event: { type: 'mouseleave' } }

    expect(pointerOnAny([atRest, following, { left: 12, event: moved }])).toBe(true)
    expect(pointerOnAny([{ left: 0, event: moved }])).toBe(true)
    expect(pointerOnAny([atRest, following, followingBeforeItsRange, left])).toBe(false)
    expect(pointerOnAny([{ event: moved }])).toBe(false)
    expect(pointerOnAny([])).toBe(false)
  })

  it('says the time for series 0, the series\' own text for the others, and none for a gap', () => {
    const data = [[1_800_000_000, 1_800_003_600], [57.3, null], [Number.NaN, 4]]
    const timeText = (seconds: number) => `t${seconds}`
    const valueText = (specIdx: number, raw: number) => `s${specIdx}=${raw}`
    const text = (seriesIdx: number, pointIdx: number | null) => legendText(data, seriesIdx, pointIdx, timeText, valueText)

    expect(text(0, 1)).toBe('t1800003600')
    expect(text(1, 0)).toBe('s0=57.3')
    expect(text(2, 1)).toBe('s1=4')
    // A gap in the data, a value that is not a number, no point, a series the data lacks.
    expect(text(1, 1)).toBe(LEGEND_NO_VALUE)
    expect(text(2, 0)).toBe(LEGEND_NO_VALUE)
    expect(text(1, null)).toBe(LEGEND_NO_VALUE)
    expect(text(3, 0)).toBe(LEGEND_NO_VALUE)
  })

  it('reads one time for all series at rest: a series with no value at the latest point says so', () => {
    const data = [[1_800_000_000, 1_800_003_600], [57.3, null], [1, 4]]
    const latest = legendPointIndex(null, false, data[0]!.length)
    const text = (seriesIdx: number) => legendText(data, seriesIdx, latest, (seconds) => `t${seconds}`, (_, raw) => String(raw))

    // Not 57.3, the series' last value: that one is the earlier time's.
    expect([text(0), text(1), text(2)]).toEqual(['t1800003600', LEGEND_NO_VALUE, '4'])
  })

  it('counts a character from Hangul up as two columns and the rest as one', () => {
    expect(displayColumns('57.30 %')).toBe(7)
    expect(displayColumns('2026-11-25 10:00pm')).toBe(18)
    expect(displayColumns(LEGEND_NO_VALUE)).toBe(4)
    expect(displayColumns('')).toBe(0)
    // A narrow symbol up there takes a column too many; one outside the BMP counts once.
    expect(displayColumns('3 → 4')).toBe(6)
    expect(displayColumns('𝟘')).toBe(2)
  })

  it('takes the widest text of each series over all points, and no less than the text for no value', () => {
    const texts = [
      ['2026-11-25 7:00pm', '2026-11-25 10:00pm', '2026-11-26 12:00am'],
      ['100 %', '57.30 %', '9 %'],
      ['1', '2', '3'],
    ]

    // The third series never has a gap, yet reads "없음" with the pointer on
    // another chart before its first point.
    expect(legendValueColumns(3, 3, (seriesIdx, pointIdx) => texts[seriesIdx]![pointIdx]!)).toEqual([18, 7, 4])
    expect(legendValueColumns(2, 0, () => 'unused')).toEqual([4, 4])
  })

  it('gives each series\' value the width of its widest text', () => {
    const root = document.createElement('div')
    root.innerHTML = `
      <table class="u-legend"><tbody>
        <tr class="u-series"><th><div class="u-label">시각</div></th><td class="u-value">없음</td></tr>
        <tr class="u-series"><th><div class="u-label">A</div></th><td class="u-value">1</td></tr>
        <tr class="u-series"><th><div class="u-label">B</div></th><td class="u-value">2</td></tr>
      </tbody></table>`

    reserveLegendValueWidths(root, [18, 7])

    const widths = [...root.querySelectorAll<HTMLElement>('.u-value')].map((cell) => cell.style.minWidth)
    // No width is known for the third series: it keeps its own.
    expect(widths).toEqual(['18ch', '7ch', ''])
  })
})
