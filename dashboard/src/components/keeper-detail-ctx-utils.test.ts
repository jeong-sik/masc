import { describe, it, expect } from 'vitest'
import { autonomyHint, formatDuration } from './keeper-detail-ctx-utils'

describe('autonomyHint', () => {
  it('returns active hint when count is 0 and proactive enabled', () => {
    expect(autonomyHint(0, true)).toBe('활성 · 미발동')
  })

  it('returns disabled hint when count is 0 and proactive disabled', () => {
    expect(autonomyHint(0, false)).toBe('자율 비활성')
  })

  it('returns disabled hint when count is 0 and proactive undefined', () => {
    expect(autonomyHint(0, undefined)).toBe('자율 비활성')
  })

  it('returns undefined when count is positive', () => {
    expect(autonomyHint(5, true)).toBeUndefined()
    expect(autonomyHint(1, false)).toBeUndefined()
  })

  it('returns disabled hint when count is undefined', () => {
    expect(autonomyHint(undefined, undefined)).toBe('자율 비활성')
  })
})

describe('formatDuration', () => {
  it('formats seconds under 60', () => {
    expect(formatDuration(0)).toBe('0초')
    expect(formatDuration(30)).toBe('30초')
    expect(formatDuration(59)).toBe('59초')
  })

  it('formats minutes under 3600', () => {
    expect(formatDuration(60)).toBe('1분')
    expect(formatDuration(120)).toBe('2분')
    expect(formatDuration(3599)).toBe('59분')
  })

  it('formats hours with remaining minutes', () => {
    expect(formatDuration(3600)).toBe('1시간 0분')
    expect(formatDuration(3660)).toBe('1시간 1분')
    expect(formatDuration(7384)).toBe('2시간 3분')
  })
})
