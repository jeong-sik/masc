// What a chart legend reads, and how wide its values are.
//
// uPlot's legend follows the crosshair. With the pointer off the chart it asks
// every series for the value at no point, which read "없음" beside a drawn
// line. The legend reads the latest point then: one time for all its series,
// so a series with no value at that time still reads "없음". Each value also
// keeps the width of its widest text, so the series after it stay where they
// are while the pointer moves.

/** The legend's name for the time. */
export const LEGEND_TIME_LABEL = '시각'

/** uPlot's own stamp for a time series' legend value. */
export const LEGEND_TIME_STAMP = '{YYYY}-{MM}-{DD} {h}:{mm}{aa}'

/** What the legend says for a point that has no value. */
export const LEGEND_NO_VALUE = '없음'

/** What uPlot keeps of the pointer for one chart: the offset from the left of
 *  its plotting area, negative off it, and the last mouse event the chart got
 *  itself. A chart that only follows another chart's crosshair has no event. */
interface ChartPointer {
  readonly left?: number
  readonly event?: unknown
}

/** Whether the pointer is on one of the charts. */
export function pointerOnAny(charts: readonly ChartPointer[]): boolean {
  return charts.some((chart) => chart.event != null && chart.left !== undefined && chart.left >= 0)
}

/** The point a legend reads: the crosshair's when the chart has one, and the
 *  latest one with the pointer on no chart of its crosshair group. With the
 *  pointer on another chart, at a time this chart draws no crosshair for, it
 *  reads none: the latest values would pass for that time's. */
export function legendPointIndex(crosshairIdx: number | null, pointerOnGroup: boolean, pointCount: number): number | null {
  if (crosshairIdx != null) return crosshairIdx
  if (pointerOnGroup || pointCount === 0) return null
  return pointCount - 1
}

/** A chart's columns: the times in seconds, then one column of values per series. */
type LegendData = ArrayLike<ArrayLike<number | null | undefined>>

/** The text of a series' legend value at a point. Series 0 is the time; series
 *  N is `valueText`'s series N - 1. A point with no value reads as none. */
export function legendText(
  data: LegendData,
  seriesIdx: number,
  pointIdx: number | null,
  timeText: (seconds: number) => string,
  valueText: (specIdx: number, raw: number) => string,
): string {
  const raw = pointIdx === null ? null : data[seriesIdx]?.[pointIdx]
  if (raw == null || Number.isNaN(raw)) return LEGEND_NO_VALUE
  return seriesIdx === 0 ? timeText(raw) : valueText(seriesIdx - 1, raw)
}

/** From here up a character takes two columns of a fixed-width face: Hangul,
 *  kana, CJK. A narrow symbol up there only reserves a column too many. */
const FIRST_WIDE_CODE_POINT = 0x1100

/** The columns a text takes in the legend's fixed-width face. */
export function displayColumns(text: string): number {
  let columns = 0
  for (const character of text) {
    columns += (character.codePointAt(0) ?? 0) >= FIRST_WIDE_CODE_POINT ? 2 : 1
  }
  return columns
}

/** For each series, the columns of the widest text its legend value shows:
 *  at any of the points, or at none. */
export function legendValueColumns(
  seriesCount: number,
  pointCount: number,
  textAt: (seriesIdx: number, pointIdx: number) => string,
): readonly number[] {
  const atNoPoint = displayColumns(LEGEND_NO_VALUE)
  return Array.from({ length: seriesCount }, (_, seriesIdx) => {
    let widest = atNoPoint
    for (let pointIdx = 0; pointIdx < pointCount; pointIdx += 1) {
      widest = Math.max(widest, displayColumns(textAt(seriesIdx, pointIdx)))
    }
    return widest
  })
}

/** Gives the legend value of series N, under `chartRoot`, a width of
 *  `columns[N]`. Row N of the legend is series N. uPlot leaves the time's row
 *  out of the other kinds of legend (one that does not follow the crosshair,
 *  one with several values a series), which the chart component does not build. */
export function reserveLegendValueWidths(chartRoot: Element, columns: readonly number[]): void {
  chartRoot.querySelectorAll('.u-legend .u-series').forEach((row, seriesIdx) => {
    const cell = row.querySelector<HTMLElement>('.u-value')
    const width = columns[seriesIdx]
    if (cell && width !== undefined) cell.style.minWidth = `${width}ch`
  })
}
