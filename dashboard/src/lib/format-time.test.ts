import { describe, it, expect } from 'vitest'
import {
  formatElapsed, formatDuration, formatDurationMs,
  formatElapsedCompact, formatDelta, formatCompactAge,
  formatRelativeSec, formatRelativeUntilSec, formatTimeAgo,
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
