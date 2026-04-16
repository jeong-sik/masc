import { describe, it, expect } from 'vitest'
import {
  formatElapsed,
  formatDuration,
  formatDurationMs,
  formatElapsedCompact,
  formatTimeAgoEn,
  formatDelta,
} from './format-time'

// ── formatElapsed ─────────────────────────────────────────────

describe('formatElapsed', () => {
  it('returns 정보 없음 for null/undefined', () => {
    expect(formatElapsed(null)).toBe('정보 없음')
    expect(formatElapsed(undefined)).toBe('정보 없음')
  })

  it('returns 정보 없음 for NaN/Infinity', () => {
    expect(formatElapsed(NaN)).toBe('정보 없음')
    expect(formatElapsed(Infinity)).toBe('정보 없음')
  })

  it('formats seconds', () => {
    expect(formatElapsed(0)).toBe('0초')
    expect(formatElapsed(30)).toBe('30초')
    expect(formatElapsed(59)).toBe('59초')
  })

  it('formats minutes', () => {
    expect(formatElapsed(60)).toBe('1분')
    expect(formatElapsed(90)).toBe('2분')
    expect(formatElapsed(3599)).toBe('60분')
  })

  it('formats hours', () => {
    expect(formatElapsed(3600)).toBe('1시간')
    expect(formatElapsed(7200)).toBe('2시간')
  })
})

// ── formatDuration ────────────────────────────────────────────

describe('formatDuration', () => {
  it('returns 확인 필요 for null/undefined', () => {
    expect(formatDuration(null)).toBe('확인 필요')
    expect(formatDuration(undefined)).toBe('확인 필요')
  })

  it('returns 확인 필요 for negative', () => {
    expect(formatDuration(-1)).toBe('확인 필요')
  })

  it('formats seconds', () => {
    expect(formatDuration(0)).toBe('0초')
    expect(formatDuration(45)).toBe('45초')
  })

  it('formats minutes', () => {
    expect(formatDuration(60)).toBe('1분')
    expect(formatDuration(180)).toBe('3분')
  })

  it('formats hours', () => {
    expect(formatDuration(3600)).toBe('1시간')
    expect(formatDuration(7200)).toBe('2시간')
  })

  it('formats days', () => {
    expect(formatDuration(86400)).toBe('1일')
    expect(formatDuration(172800)).toBe('2일')
  })
})

// ── formatDurationMs ──────────────────────────────────────────

describe('formatDurationMs', () => {
  it('clamps negative to 0', () => {
    expect(formatDurationMs(-1000)).toBe('0분')
  })

  it('formats minutes', () => {
    expect(formatDurationMs(60_000)).toBe('1분')
    expect(formatDurationMs(150_000)).toBe('2분')
  })

  it('formats hours without remainder', () => {
    expect(formatDurationMs(3_600_000)).toBe('1시간')
  })

  it('formats hours with minutes', () => {
    expect(formatDurationMs(5_400_000)).toBe('1시간 30분')
  })

  it('formats days without remainder', () => {
    expect(formatDurationMs(86_400_000)).toBe('1일')
  })

  it('formats days with hours', () => {
    expect(formatDurationMs(104_400_000)).toBe('1일 5시간')
  })
})

// ── formatElapsedCompact ──────────────────────────────────────

describe('formatElapsedCompact', () => {
  it('returns empty for null/undefined', () => {
    expect(formatElapsedCompact(null)).toBe('')
    expect(formatElapsedCompact(undefined)).toBe('')
  })

  it('formats seconds', () => {
    expect(formatElapsedCompact(0)).toBe('0s')
    expect(formatElapsedCompact(30)).toBe('30s')
  })

  it('formats minutes and seconds', () => {
    expect(formatElapsedCompact(90)).toBe('1m 30s')
    expect(formatElapsedCompact(125)).toBe('2m 5s')
  })

  it('formats hours and minutes', () => {
    expect(formatElapsedCompact(3600)).toBe('1h 0m')
    expect(formatElapsedCompact(5400)).toBe('1h 30m')
  })
})

// ── formatTimeAgoEn ───────────────────────────────────────────

describe('formatTimeAgoEn', () => {
  it('returns unknown for empty string', () => {
    expect(formatTimeAgoEn('')).toBe('unknown')
    expect(formatTimeAgoEn('  ')).toBe('unknown')
  })

  it('returns never for never', () => {
    expect(formatTimeAgoEn('never')).toBe('never')
  })

  it('returns just now for recent timestamp', () => {
    const iso = new Date(Date.now() - 10_000).toISOString()
    expect(formatTimeAgoEn(iso)).toBe('just now')
  })

  it('returns Xm ago for minutes', () => {
    const iso = new Date(Date.now() - 5 * 60_000).toISOString()
    expect(formatTimeAgoEn(iso)).toBe('5m ago')
  })

  it('returns Xh ago for hours', () => {
    const iso = new Date(Date.now() - 3 * 3600_000).toISOString()
    expect(formatTimeAgoEn(iso)).toBe('3h ago')
  })

  it('returns Xd ago for days', () => {
    const iso = new Date(Date.now() - 2 * 86400_000).toISOString()
    expect(formatTimeAgoEn(iso)).toBe('2d ago')
  })
})

// ── formatDelta ───────────────────────────────────────────────

describe('formatDelta', () => {
  it('prefixes positive with +', () => {
    expect(formatDelta(1.5)).toBe('+1.5000')
  })

  it('handles zero', () => {
    expect(formatDelta(0)).toBe('+0.0000')
  })

  it('handles negative without extra sign', () => {
    expect(formatDelta(-2.3)).toBe('-2.3000')
  })

  it('respects decimal places', () => {
    expect(formatDelta(1.234, 2)).toBe('+1.23')
    expect(formatDelta(-0.5, 1)).toBe('-0.5')
  })
})
