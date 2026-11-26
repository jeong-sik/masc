import { describe, expect, it } from 'vitest'
import { isWindowCurrentlySpent, type QuotaUtilizationLike } from './quota-window'

const NOW = 1_700_000_500

function win(utilization: QuotaUtilizationLike, resets_at: number | null, observed_at: number) {
  return { utilization, resets_at, observed_at }
}

describe('isWindowCurrentlySpent (gating_reading mirror)', () => {
  it('a non-spent reading is never currently spent', () => {
    expect(isWindowCurrentlySpent(win({ unit: 'fraction', value: 0.4 }, NOW + 3600, NOW - 60), NOW)).toBe(false)
  })

  it('a spent reading without resets_at refuses now', () => {
    expect(isWindowCurrentlySpent(win({ unit: 'credit_balance', remaining: 0 }, null, NOW - 60), NOW)).toBe(true)
  })

  it('a spent reading whose reset is still ahead refuses now', () => {
    expect(isWindowCurrentlySpent(win({ unit: 'fraction', value: 1 }, NOW + 3600, NOW - 60), NOW)).toBe(true)
  })

  it('a spent reading seen at or after its own reset still refuses now', () => {
    expect(isWindowCurrentlySpent(win({ unit: 'fraction', value: 1 }, NOW - 400, NOW - 100), NOW)).toBe(true)
    expect(isWindowCurrentlySpent(win({ unit: 'fraction', value: 1 }, NOW - 400, NOW - 400), NOW)).toBe(true)
  })

  it('a stale spent reading (taken before its reset, which has passed) does not refuse now', () => {
    expect(isWindowCurrentlySpent(win({ unit: 'fraction', value: 1 }, NOW - 400, NOW - 500), NOW)).toBe(false)
  })
})
