import { describe, it, expect } from 'vitest'
import type { Keeper } from '../types'
import { keeperRecencyMs, compareByRecency, mostRecentlyActiveKeeper } from './keeper-recency'

// Fixed reference clock so relative (`*_ago_s`) conversions are deterministic.
const NOW = Date.parse('2026-07-01T12:00:00.000Z')

function k(name: string, fields: Partial<Keeper> = {}): Keeper {
  return { name, ...fields } as Keeper
}

describe('keeperRecencyMs', () => {
  it('prefers last_activity_at over other absolute fields', () => {
    const keeper = k('a', {
      last_activity_at: '2026-07-01T11:00:00.000Z',
      updated_at: '2026-06-01T00:00:00.000Z',
      last_heartbeat: '2026-05-01T00:00:00.000Z',
    })
    expect(keeperRecencyMs(keeper, NOW)).toBe(Date.parse('2026-07-01T11:00:00.000Z'))
  })

  it('falls back through updated_at → last_heartbeat → created_at', () => {
    expect(keeperRecencyMs(k('a', { updated_at: '2026-06-01T00:00:00.000Z' }), NOW))
      .toBe(Date.parse('2026-06-01T00:00:00.000Z'))
    expect(keeperRecencyMs(k('a', { last_heartbeat: '2026-05-01T00:00:00.000Z' }), NOW))
      .toBe(Date.parse('2026-05-01T00:00:00.000Z'))
    expect(keeperRecencyMs(k('a', { created_at: '2026-04-01T00:00:00.000Z' }), NOW))
      .toBe(Date.parse('2026-04-01T00:00:00.000Z'))
  })

  it('converts last_activity_ago_s against nowMs when no absolute field exists', () => {
    // 300s ago → NOW - 300_000
    expect(keeperRecencyMs(k('a', { last_activity_ago_s: 300 }), NOW)).toBe(NOW - 300_000)
  })

  it('uses last_turn_ago_s only when last_activity_ago_s is absent', () => {
    expect(keeperRecencyMs(k('a', { last_turn_ago_s: 60 }), NOW)).toBe(NOW - 60_000)
    // last_activity_ago_s wins when both present
    expect(keeperRecencyMs(k('a', { last_activity_ago_s: 10, last_turn_ago_s: 999 }), NOW))
      .toBe(NOW - 10_000)
  })

  it('returns -Infinity when no recency signal is present', () => {
    expect(keeperRecencyMs(k('a'), NOW)).toBe(Number.NEGATIVE_INFINITY)
  })

  it('ignores unparseable ISO strings and continues resolution', () => {
    // bad last_activity_at → skip to updated_at
    expect(keeperRecencyMs(k('a', { last_activity_at: 'not-a-date', updated_at: '2026-06-01T00:00:00.000Z' }), NOW))
      .toBe(Date.parse('2026-06-01T00:00:00.000Z'))
  })
})

describe('compareByRecency', () => {
  it('orders most-recent first', () => {
    const older = k('older', { last_activity_at: '2026-07-01T10:00:00.000Z' })
    const newer = k('newer', { last_activity_at: '2026-07-01T11:30:00.000Z' })
    expect(compareByRecency(newer, older, NOW)).toBeLessThan(0)
    expect([older, newer].sort((a, b) => compareByRecency(a, b, NOW)).map(x => x.name))
      .toEqual(['newer', 'older'])
  })

  it('breaks ties by name for stable ordering (including no-recency keepers)', () => {
    const b = k('b')
    const a = k('a')
    expect(compareByRecency(a, b, NOW)).toBeLessThan(0)
    expect([b, a].sort((x, y) => compareByRecency(x, y, NOW)).map(x => x.name)).toEqual(['a', 'b'])
  })

  it('mixes absolute and relative fields on one epoch-ms scale', () => {
    const abs = k('abs', { last_activity_at: '2026-07-01T11:59:00.000Z' }) // 60s ago
    const rel = k('rel', { last_activity_ago_s: 30 }) // 30s ago → more recent
    expect([abs, rel].sort((a, b) => compareByRecency(a, b, NOW)).map(x => x.name))
      .toEqual(['rel', 'abs'])
  })
})

describe('mostRecentlyActiveKeeper', () => {
  it('returns null for an empty list', () => {
    expect(mostRecentlyActiveKeeper([], NOW)).toBeNull()
  })

  it('picks the most recently active keeper, not the array-first one', () => {
    const list = [
      k('albini', { last_activity_ago_s: 3600 }), // 1h ago, alphabetically first
      k('zed', { last_activity_ago_s: 5 }), // most recent
      k('mara', { last_activity_ago_s: 120 }),
    ]
    expect(mostRecentlyActiveKeeper(list, NOW)?.name).toBe('zed')
  })

  it('is deterministic across equal-recency inputs (name tiebreak)', () => {
    const list = [k('c'), k('a'), k('b')]
    expect(mostRecentlyActiveKeeper(list, NOW)?.name).toBe('a')
  })
})
