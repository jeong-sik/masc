// How a chart writes a time: its x axis and its legend in one notation.
//
// uPlot's own axis writes "7pm" over "11/25/26": month before day, the year
// in two digits. The legend beside it wrote "2026-11-25 7:00pm". Both now
// write the date year first and the time on the 24-hour clock, where
// midnight and noon read "00:00" and "12:00" and not "12am" and "12pm".

import type uPlot from 'uplot'

const MINUTE = 60
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

const DATE = '{YYYY}-{MM}-{DD}'
const MONTH_DAY = '{MM}-{DD}'
const CLOCK = '{HH}:{mm}'

/** uPlot's stamp for the time in a legend. */
export const LEGEND_TIME_STAMP = `${DATE} ${CLOCK}`

/**
 * uPlot's stamps for the ticks of an axis of times in seconds, widest step
 * first. A row is the smallest step it serves, then a tick's text, then what
 * a tick adds on a second line when its year, month, day, hour, minute or
 * second is not the tick's before it; the first tick counts as a new year.
 * The closing 1 has the addition follow the tick's text, where 0 would have
 * it take the text's place.
 */
export const TIME_AXIS_STAMPS: uPlot.Axis.TimeValuesConfig = [
  [365 * DAY, '{YYYY}', null, null, null, null, null, null, 1],
  [28 * DAY, '{YYYY}-{MM}', null, null, null, null, null, null, 1],
  [DAY, MONTH_DAY, '\n{YYYY}', null, null, null, null, null, 1],
  [HOUR, CLOCK, `\n${DATE}`, null, `\n${MONTH_DAY}`, null, null, null, 1],
  [MINUTE, CLOCK, `\n${DATE}`, null, `\n${MONTH_DAY}`, null, null, null, 1],
  [1, ':{ss}', `\n${DATE} ${CLOCK}`, null, `\n${MONTH_DAY} ${CLOCK}`, null, `\n${CLOCK}`, null, 1],
  [0.001, ':{ss}.{fff}', `\n${DATE} ${CLOCK}`, null, `\n${MONTH_DAY} ${CLOCK}`, null, `\n${CLOCK}`, null, 1],
]
