import { describe, it, expect, vi } from 'vitest'

// Mock modules with lucide-preact icons that cause test-env errors
vi.mock('./common/feedback-state', () => ({
  LoadingState: () => null,
  ErrorState: () => null,
  EmptyState: () => null,
}))
vi.mock('./common/time-ago', () => ({ TimeAgo: () => null }))
vi.mock('../api/dashboard-cascade', () => ({
  fetchCascadeStrategyTrace: vi.fn(async () => ({ events: [], updated_at: '' })),
}))

import {
  cascadeKindTone,
  formatBackoff,
  barWidthPct,
} from './cascade-waterfall'

describe('cascadeKindTone', () => {
  it('returns ok tone for ordered', () => {
    const t = cascadeKindTone('ordered')
    expect(t.label).toBe('순차')
    expect(t.color).toContain('ok')
  })

  it('returns warn tone for filtered_empty', () => {
    const t = cascadeKindTone('filtered_empty')
    expect(t.label).toBe('필터 소진')
    expect(t.color).toContain('warn')
  })

  it('returns bad tone for exhausted', () => {
    const t = cascadeKindTone('exhausted')
    expect(t.label).toBe('모두 소진')
    expect(t.color).toContain('bad')
  })

  it('returns muted tone for unknown kinds', () => {
    const t = cascadeKindTone('unknown_kind')
    expect(t.label).toBe('unknown_kind')
    expect(t.color).toContain('fg-muted')
  })
})

describe('formatBackoff', () => {
  it('returns - for zero', () => {
    expect(formatBackoff(0)).toBe('-')
  })

  it('returns - for negative', () => {
    expect(formatBackoff(-1)).toBe('-')
  })

  it('returns ms for sub-second', () => {
    expect(formatBackoff(500)).toBe('500ms')
  })

  it('returns seconds for >=1000ms', () => {
    expect(formatBackoff(1000)).toBe('1.0s')
    expect(formatBackoff(2500)).toBe('2.5s')
  })
})

describe('barWidthPct', () => {
  it('returns 0 for zero value', () => {
    expect(barWidthPct(0, 10)).toBe(0)
  })

  it('returns 0 for zero max', () => {
    expect(barWidthPct(5, 0)).toBe(0)
  })

  it('returns 100 for value >= max', () => {
    expect(barWidthPct(10, 10)).toBe(100)
    expect(barWidthPct(20, 10)).toBe(100)
  })

  it('returns proportional percentage', () => {
    expect(barWidthPct(5, 10)).toBe(50)
    expect(barWidthPct(3, 12)).toBe(25)
  })

  it('rounds to integer', () => {
    // 1/3 ~ 33.3% → rounded to 33
    expect(barWidthPct(1, 3)).toBe(33)
  })
})
