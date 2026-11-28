import { describe, it, expect } from 'vitest'
import {
  formatElapsed, formatDuration, formatDurationCompound, formatDurationMs,
  formatElapsedCompact, formatDelta, formatCompactAge,
  formatRelativeSec, formatRelativeUntilSec, formatTimeAgo,
  formatRelativeTime, formatScheduledTime,
} from './format-time'

describe('formatElapsed', () => {
  it('formats seconds', () => { expect(formatElapsed(30)).toBe('30초') })
  it('formats minutes', () => { expect(formatElapsed(120)).toBe('2분') })
  it('formats hours', () => { expect(formatElapsed(7200)).toBe('2시간') })
  it('returns 정보 없음 for null', () => { expect(formatElapsed(null)).toBe('정보 없음') })
  it('returns 정보 없음 for undefined', () => { expect(formatElapsed(undefined)).toBe('정보 없음') })
  it('returns 정보 없음 for NaN', () => { expect(formatElapsed(NaN)).toBe('정보 없음') })
})

describe('formatDuration', () => {
  it('formats seconds', () => { expect(formatDuration(45)).toBe('45초') })
  it('formats minutes', () => { expect(formatDuration(180)).toBe('3분') })
  it('formats hours', () => { expect(formatDuration(7200)).toBe('2시간') })
  it('formats days', () => { expect(formatDuration(172800)).toBe('2일') })
  it('returns 확인 필요 for null', () => { expect(formatDuration(null)).toBe('확인 필요') })
  it('returns 확인 필요 for negative', () => { expect(formatDuration(-1)).toBe('확인 필요') })
  it('returns 확인 필요 for NaN', () => { expect(formatDuration(NaN)).toBe('확인 필요') })
})

describe('formatDurationCompound', () => {
  it('formats sub-minute as seconds', () => { expect(formatDurationCompound(45)).toBe('45초') })
  it('formats sub-hour as whole minutes (no seconds)', () => { expect(formatDurationCompound(92)).toBe('1분') })
  it('formats hours with remainder minutes', () => { expect(formatDurationCompound(9000)).toBe('2시간 30분') })
  it('keeps a zero-minute remainder explicit', () => { expect(formatDurationCompound(7200)).toBe('2시간 0분') })
  it('returns 확인 필요 for negative', () => { expect(formatDurationCompound(-1)).toBe('확인 필요') })
  it('returns 확인 필요 for NaN', () => { expect(formatDurationCompound(NaN)).toBe('확인 필요') })
})

describe('formatDurationMs', () => {
  it('formats minutes', () => { expect(formatDurationMs(5 * 60_000)).toBe('5분') })
  it('formats hours', () => { expect(formatDurationMs(2 * 3600_000)).toBe('2시간') })
  it('formats hours with remainder minutes', () => { expect(formatDurationMs(150 * 60_000)).toBe('2시간 30분') })
  it('formats days', () => { expect(formatDurationMs(48 * 3600_000)).toBe('2일') })
  it('formats days with remainder hours', () => { expect(formatDurationMs(27 * 3600_000)).toBe('1일 3시간') })
  it('clamps negative to 0', () => { expect(formatDurationMs(-1000)).toBe('0분') })
})

describe('formatElapsedCompact', () => {
  it('formats seconds', () => { expect(formatElapsedCompact(30)).toBe('30s') })
  it('formats minutes and seconds', () => { expect(formatElapsedCompact(125)).toBe('2m 5s') })
  it('formats hours and minutes', () => { expect(formatElapsedCompact(7500)).toBe('2h 5m') })
  it('returns empty for null', () => { expect(formatElapsedCompact(null)).toBe('') })
})

describe('formatDelta', () => {
  it('formats positive with plus', () => { expect(formatDelta(0.5)).toBe('+0.5000') })
  it('formats negative without plus', () => { expect(formatDelta(-0.3)).toBe('-0.3000') })
  it('formats zero with plus', () => { expect(formatDelta(0)).toBe('+0.0000') })
  it('uses custom decimals', () => { expect(formatDelta(1.234, 2)).toBe('+1.23') })
})

describe('formatCompactAge', () => {
  it('shows 방금 for sub-minute ages', () => {
    expect(formatCompactAge(0)).toBe('방금')
    expect(formatCompactAge(19)).toBe('방금')
    expect(formatCompactAge(59)).toBe('방금')
  })
  it('formats minutes without a 전 suffix', () => {
    expect(formatCompactAge(60)).toBe('1분')
    expect(formatCompactAge(41 * 60)).toBe('41분')
  })
  it('formats hours and days', () => {
    expect(formatCompactAge(2 * 3600)).toBe('2시간')
    expect(formatCompactAge(86400)).toBe('1일')
  })
  it('clamps negative to 방금', () => { expect(formatCompactAge(-5)).toBe('방금') })
  it('returns 정보 없음 for non-finite input', () => { expect(formatCompactAge(Infinity)).toBe('정보 없음') })
})

describe('relative time finite guards', () => {
  it('returns 정보 없음 for non-finite relative deltas', () => {
    expect(formatRelativeSec(Infinity)).toBe('정보 없음')
    expect(formatRelativeUntilSec(Number.NaN)).toBe('정보 없음')
  })

  it('returns 정보 없음 for invalid timestamps instead of throwing', () => {
    expect(formatTimeAgo('not-a-date')).toBe('정보 없음')
  })
})

// Local wall-clock times, so each case reads the same in any time zone.
const at = (day: number, hour: number, minute = 0, second = 0) =>
  new Date(2026, 10, day, hour, minute, second).getTime()

describe('formatRelativeTime', () => {
  it('reads a calendar day in whole local days, not from UTC midnight', () => {
    const now = at(28, 15)
    expect(formatRelativeTime('2026-11-28', now)).toBe('오늘')
    expect(formatRelativeTime('2026-11-27', now)).toBe('어제')
    expect(formatRelativeTime('2026-11-24', now)).toBe('4일 전')
  })

  it('reads a calendar day by the local date just after midnight', () => {
    const now = at(28, 0, 30)
    expect(formatRelativeTime('2026-11-28', now)).toBe('오늘')
    expect(formatRelativeTime('2026-11-27', now)).toBe('어제')
  })

  it('reads an instant in seconds, minutes, hours and days', () => {
    const now = at(28, 15)
    expect(formatRelativeTime(new Date(at(28, 14, 59, 30)).toISOString(), now)).toBe('방금 전')
    expect(formatRelativeTime(new Date(at(28, 14, 57)).toISOString(), now)).toBe('3분 전')
    expect(formatRelativeTime(new Date(at(28, 13)).toISOString(), now)).toBe('2시간 전')
    expect(formatRelativeTime(new Date(at(25, 15)).toISOString(), now)).toBe('3일 전')
  })

  it('takes unix seconds and unix milliseconds alike', () => {
    const now = at(28, 15)
    const fiveMinutesAgoMs = at(28, 14, 55)
    expect(formatRelativeTime(fiveMinutesAgoMs, now)).toBe('5분 전')
    expect(formatRelativeTime(fiveMinutesAgoMs / 1000, now)).toBe('5분 전')
  })

  it('reads an event just ahead of the local clock as now, and one further ahead as ahead', () => {
    const now = at(28, 15)
    expect(formatRelativeTime(new Date(at(28, 15, 0, 12)).toISOString(), now)).toBe('방금 전')
    expect(formatRelativeTime(new Date(at(28, 15, 10)).toISOString(), now)).toBe('10분 후')
    expect(formatRelativeTime('2026-11-29', now)).toBe('오늘')
    expect(formatRelativeTime('2026-12-01', now)).toBe('3일 후')
  })

  it('says 없음 without a time and shows text that is no time as written', () => {
    const now = at(28, 15)
    expect(formatRelativeTime(null, now)).toBe('없음')
    expect(formatRelativeTime('', now)).toBe('없음')
    expect(formatRelativeTime(Number.NaN, now)).toBe('없음')
    expect(formatRelativeTime('2026-02-30', now)).toBe('2026-02-30')
    expect(formatRelativeTime('not-a-date', now)).toBe('not-a-date')
  })
})

describe('formatScheduledTime', () => {
  it('reads a time ahead of now as ahead, and a passed one as past', () => {
    const now = at(28, 15)
    expect(formatScheduledTime(new Date(at(28, 15, 0, 20)).toISOString(), now)).toBe('20초 후')
    expect(formatScheduledTime(new Date(at(28, 17)).toISOString(), now)).toBe('2시간 후')
    expect(formatScheduledTime(new Date(at(28, 14, 58)).toISOString(), now)).toBe('2분 전')
    expect(formatScheduledTime('2026-11-29', now)).toBe('내일')
    expect(formatScheduledTime('2026-12-01', now)).toBe('3일 후')
    expect(formatScheduledTime('2026-11-27', now)).toBe('어제')
  })
})
