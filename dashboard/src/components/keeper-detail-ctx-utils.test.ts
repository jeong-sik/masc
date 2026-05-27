import { describe, it, expect } from 'vitest'
import { formatDurationCompound } from '../lib/format-time'
import { autonomyHint } from './keeper-detail-ctx-utils'

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

describe('formatDurationCompound', () => {
  it('formats seconds under 60', () => {
    expect(formatDurationCompound(0)).toBe('0초')
    expect(formatDurationCompound(30)).toBe('30초')
    expect(formatDurationCompound(59)).toBe('59초')
  })

  it('formats minutes under 3600', () => {
    expect(formatDurationCompound(60)).toBe('1분')
    expect(formatDurationCompound(120)).toBe('2분')
    expect(formatDurationCompound(3599)).toBe('59분')
  })

  it('formats hours with remaining minutes', () => {
    expect(formatDurationCompound(3600)).toBe('1시간 0분')
    expect(formatDurationCompound(3660)).toBe('1시간 1분')
    expect(formatDurationCompound(7384)).toBe('2시간 3분')
  })
})
