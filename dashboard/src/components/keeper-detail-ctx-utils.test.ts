import { describe, it, expect } from 'vitest'
import { formatDurationCompound } from '../lib/format-time'

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
