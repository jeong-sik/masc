// Shared wire timestamp boundary matching the canonical Ptime parser.
export interface Rfc3339Instant {
  value: number
}

export function parseStrictRfc3339(value: string): Rfc3339Instant | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value)
  if (match === null) return null
  const [, yearText, monthText, dayText, hourText, minuteText, secondText,
    fractionText = '', zone, sign, offsetHourText = '0', offsetMinuteText = '0'] = match
  const year = Number(yearText)
  const month = Number(monthText)
  const day = Number(dayText)
  const hour = Number(hourText)
  const minute = Number(minuteText)
  const second = Number(secondText)
  const offsetHour = Number(offsetHourText)
  const offsetMinute = Number(offsetMinuteText)
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 60
    || offsetHour > 23 || offsetMinute > 59) return null
  const monthBoundary = new Date(0)
  monthBoundary.setUTCFullYear(year, month, 0)
  const daysInMonth = monthBoundary.getUTCDate()
  if (day < 1 || day > daysInMonth) return null
  const civil = new Date(0)
  civil.setUTCFullYear(year, month - 1, day)
  civil.setUTCHours(hour, minute, second, 0)
  const offset = zone === 'Z'
    ? 0
    : (offsetHour * 60 + offsetMinute) * (sign === '+' ? 60 : -60)
  const wholeSeconds = civil.getTime() / 1000 - offset
  const minimum = new Date(0)
  minimum.setUTCFullYear(0, 0, 1)
  minimum.setUTCHours(0, 0, 0, 0)
  const maximumExclusive = new Date(0)
  maximumExclusive.setUTCFullYear(10_000, 0, 1)
  maximumExclusive.setUTCHours(0, 0, 0, 0)
  if (wholeSeconds < minimum.getTime() / 1000
    || wholeSeconds >= maximumExclusive.getTime() / 1000) return null
  const ptimeFraction = fractionText.slice(0, 12)
  const instant = wholeSeconds
    + (ptimeFraction === '' ? 0 : Number(`0.${ptimeFraction}`))
  return { value: instant }
}
