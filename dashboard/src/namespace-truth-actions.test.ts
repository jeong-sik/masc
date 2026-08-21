import { describe, expect, it } from 'vitest'
import {
  WARMUP_POLL_CAP_MS,
  WARMUP_POLL_DELAYS_MS,
  warmupPollDelayFor,
} from './namespace-truth-actions'

describe('warmupPollDelayFor — Phase 2 Action 6 exponential backoff', () => {
  it('returns the published schedule for 1..N', () => {
    WARMUP_POLL_DELAYS_MS.forEach((expected, idx) => {
      expect(warmupPollDelayFor(idx + 1)).toBe(expected)
    })
  })

  it('caps at WARMUP_POLL_CAP_MS for attempts past the schedule length', () => {
    expect(warmupPollDelayFor(WARMUP_POLL_DELAYS_MS.length + 1))
      .toBe(WARMUP_POLL_CAP_MS)
    expect(warmupPollDelayFor(WARMUP_POLL_DELAYS_MS.length + 5))
      .toBe(WARMUP_POLL_CAP_MS)
  })

  it('schedule is monotonically non-decreasing', () => {
    for (let i = 1; i < WARMUP_POLL_DELAYS_MS.length; i++) {
      const prev = WARMUP_POLL_DELAYS_MS[i - 1] ?? 0
      const curr = WARMUP_POLL_DELAYS_MS[i] ?? 0
      expect(curr).toBeGreaterThanOrEqual(prev)
    }
  })

  it('returns first delay for invalid attempt values (0, negative, NaN)', () => {
    const first = WARMUP_POLL_DELAYS_MS[0]!
    expect(warmupPollDelayFor(0)).toBe(first)
    expect(warmupPollDelayFor(-3)).toBe(first)
    expect(warmupPollDelayFor(Number.NaN)).toBe(first)
  })

  it('cap is at least as large as the largest scheduled delay', () => {
    const max = Math.max(...WARMUP_POLL_DELAYS_MS)
    expect(WARMUP_POLL_CAP_MS).toBeGreaterThanOrEqual(max)
  })
})
