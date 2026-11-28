import uPlot from 'uplot'
import { describe, expect, it } from 'vitest'
import { LEGEND_TIME_STAMP, TIME_AXIS_STAMPS } from './uplot-time'

const MINUTE = 60
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

// Local time, so the texts are the same on a runner in any zone.
const SEVEN_PM = new Date(2026, 10, 25, 19, 0, 7)
const MIDNIGHT = new Date(2026, 10, 26, 0, 0, 0)
const NOON = new Date(2026, 10, 26, 12, 0, 0)

/** The row uPlot takes for ticks `step` seconds apart: the first whose smallest step fits. */
function rowFor(step: number): readonly (string | number | null)[] {
  return TIME_AXIS_STAMPS.find((row) => step >= Number(row[0]))!
}

/** A tick's text for `at`, with the addition of column `rollover` when one is given. */
function tick(step: number, at: Date, rollover?: 2 | 4 | 6): string {
  const row = rowFor(step)
  const addition = rollover === undefined ? '' : String(row[rollover])
  return uPlot.fmtDate(`${String(row[1])}${addition}`)(at)
}

describe('components/primitives uplot time notation', () => {
  it('writes the legend\'s time year first and on the 24-hour clock', () => {
    const stamp = uPlot.fmtDate(LEGEND_TIME_STAMP)

    expect(stamp(SEVEN_PM)).toBe('2026-11-25 19:00')
    expect(stamp(MIDNIGHT)).toBe('2026-11-26 00:00')
    expect(stamp(NOON)).toBe('2026-11-26 12:00')
  })

  it('writes a tick as the legend writes that part of the time', () => {
    expect(tick(10 * MINUTE, SEVEN_PM)).toBe('19:00')
    expect(tick(3 * HOUR, MIDNIGHT)).toBe('00:00')
    expect(tick(3 * HOUR, NOON)).toBe('12:00')
    expect(tick(DAY, SEVEN_PM)).toBe('11-25')
    expect(tick(30 * DAY, SEVEN_PM)).toBe('2026-11')
    expect(tick(365 * DAY, SEVEN_PM)).toBe('2026')
    expect(tick(10, SEVEN_PM)).toBe(':07')
  })

  it('adds the date under the first tick and under a tick on a new day', () => {
    // Column 2 is the first tick and a new year, column 4 a new day, column 6 a new minute.
    expect(tick(3 * HOUR, SEVEN_PM, 2)).toBe('19:00\n2026-11-25')
    expect(tick(3 * HOUR, MIDNIGHT, 4)).toBe('00:00\n11-26')
    expect(tick(DAY, SEVEN_PM, 2)).toBe('11-25\n2026')
    expect(tick(10, SEVEN_PM, 2)).toBe(':07\n2026-11-25 19:00')
    expect(tick(10, SEVEN_PM, 6)).toBe(':07\n19:00')
  })

  it('serves every step from a year down to a millisecond, widest first', () => {
    const steps = TIME_AXIS_STAMPS.map((row) => Number(row[0]))

    expect(steps).toEqual([...steps].sort((a, b) => b - a))
    expect(steps[0]).toBe(365 * DAY)
    expect(steps[steps.length - 1]).toBe(0.001)
    // Nine columns a row, the last telling uPlot to add the second line to the tick's text.
    expect(TIME_AXIS_STAMPS.every((row) => row.length === 9 && row[8] === 1)).toBe(true)
  })
})
