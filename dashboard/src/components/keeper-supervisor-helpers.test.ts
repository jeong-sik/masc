import { describe, expect, it } from 'vitest'
import {
  CRASH_CATEGORY_KEYS,
  categorizeCrashReason,
  filterCrashLog,
  groupCrashCohorts,
} from './keeper-supervisor-helpers'
import type { KeeperSupervisorCrashLogEntry } from '../types'

describe('categorizeCrashReason', () => {
  it('classifies known prefixes', () => {
    expect(categorizeCrashReason('heartbeat_timeout')).toBe('heartbeat')
    expect(categorizeCrashReason('turn_execution_failed')).toBe('turn')
    expect(categorizeCrashReason('fiber_panic')).toBe('fiber')
    expect(categorizeCrashReason('exception_unhandled')).toBe('exception')
  })

  it('prefers exact match when backend emits category name directly', () => {
    expect(categorizeCrashReason('heartbeat')).toBe('heartbeat')
    expect(categorizeCrashReason('turn')).toBe('turn')
    expect(categorizeCrashReason('fiber')).toBe('fiber')
    expect(categorizeCrashReason('exception')).toBe('exception')
    // 'other' is the fallback, not a real category to match
    expect(categorizeCrashReason('other')).toBe('other')
  })

  it('falls back to other for unknown / empty / nullish reasons', () => {
    expect(categorizeCrashReason('mystery')).toBe('other')
    expect(categorizeCrashReason('')).toBe('other')
    expect(categorizeCrashReason(null)).toBe('other')
    expect(categorizeCrashReason(undefined)).toBe('other')
  })

  it('exposes a stable category key list including all branches', () => {
    expect(CRASH_CATEGORY_KEYS).toEqual([
      'heartbeat', 'turn', 'fiber', 'exception', 'other',
    ])
  })
})

describe('groupCrashCohorts', () => {
  it('returns empty object for empty input', () => {
    expect(groupCrashCohorts([])).toEqual({})
  })

  it('tallies cohorts and omits zero categories', () => {
    const log: KeeperSupervisorCrashLogEntry[] = [
      { ts: 1, reason: 'heartbeat_timeout' },
      { ts: 2, reason: 'heartbeat_lost' },
      { ts: 3, reason: 'turn_execution_failed' },
      { ts: 4, reason: 'unknown' },
      { ts: 5 },
    ]
    expect(groupCrashCohorts(log)).toEqual({
      heartbeat: 2,
      turn: 1,
      other: 2,
    })
  })
})

describe('filterCrashLog', () => {
  const log: KeeperSupervisorCrashLogEntry[] = [
    { ts: 1, reason: 'heartbeat_timeout' },
    { ts: 2, reason: 'turn_execution_failed' },
    { ts: 3, reason: 'fiber_panic' },
    { ts: 4, reason: 'heartbeat_lost' },
  ]

  it('returns a copy of the full log when category is "all"', () => {
    const out = filterCrashLog(log, 'all')
    expect(out).toEqual(log)
    expect(out).not.toBe(log)
  })

  it('filters by category and preserves order', () => {
    expect(filterCrashLog(log, 'heartbeat').map((e) => e.ts)).toEqual([1, 4])
    expect(filterCrashLog(log, 'fiber').map((e) => e.ts)).toEqual([3])
  })

  it('returns an empty array when no entries match', () => {
    expect(filterCrashLog(log, 'exception')).toEqual([])
  })

  it('does not mutate the input', () => {
    const before = log.slice()
    filterCrashLog(log, 'heartbeat')
    expect(log).toEqual(before)
  })
})
