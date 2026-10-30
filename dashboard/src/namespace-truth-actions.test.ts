import { describe, expect, it } from 'vitest'
import {
  WARM_RETRY_CAP_MS,
  WARM_RETRY_DELAYS_MS,
  warmRetryDelayFor,
} from './namespace-truth-actions'

describe('warmRetryDelayFor — Phase 2 Action 6 exponential backoff', () => {
  it('returns the published schedule for 1..N', () => {
    WARM_RETRY_DELAYS_MS.forEach((expected, idx) => {
      expect(warmRetryDelayFor(idx + 1)).toBe(expected)
    })
  })

  it('caps at WARM_RETRY_CAP_MS for attempts past the schedule length', () => {
    expect(warmRetryDelayFor(WARM_RETRY_DELAYS_MS.length + 1))
      .toBe(WARM_RETRY_CAP_MS)
    expect(warmRetryDelayFor(WARM_RETRY_DELAYS_MS.length + 5))
      .toBe(WARM_RETRY_CAP_MS)
  })

  it('schedule is monotonically non-decreasing', () => {
    for (let i = 1; i < WARM_RETRY_DELAYS_MS.length; i++) {
      const prev = WARM_RETRY_DELAYS_MS[i - 1] ?? 0
      const curr = WARM_RETRY_DELAYS_MS[i] ?? 0
      expect(curr).toBeGreaterThanOrEqual(prev)
    }
  })

  it('returns first delay for invalid attempt values (0, negative, NaN)', () => {
    const first = WARM_RETRY_DELAYS_MS[0]!
    expect(warmRetryDelayFor(0)).toBe(first)
    expect(warmRetryDelayFor(-3)).toBe(first)
    expect(warmRetryDelayFor(Number.NaN)).toBe(first)
  })

  it('cap is at least as large as the largest scheduled delay', () => {
    const max = Math.max(...WARM_RETRY_DELAYS_MS)
    expect(WARM_RETRY_CAP_MS).toBeGreaterThanOrEqual(max)
  })
})
