import { describe, expect, it } from 'vitest'
import {
  SCHED_CADENCE,
  SCHED_CADENCE_ORDER,
  SCHED_TERMINAL,
  SCHED_TERMINAL_NORMALIZED,
  cadenceOfRecurrenceKind,
  parseRecurrenceKind,
  type Cadence,
  type RecurrenceKind,
} from './schedule-constants'

describe('parseRecurrenceKind', () => {
  it('accepts the closed backend recurrence set (case/space-insensitive)', () => {
    expect(parseRecurrenceKind('one_shot')).toBe('one_shot')
    expect(parseRecurrenceKind('Interval')).toBe('interval')
    expect(parseRecurrenceKind('  daily ')).toBe('daily')
    expect(parseRecurrenceKind('cron')).toBe('cron')
  })

  it('returns null for anything outside the set — never a permissive default', () => {
    expect(parseRecurrenceKind('lunar')).toBeNull()
    expect(parseRecurrenceKind('')).toBeNull()
    expect(parseRecurrenceKind(null)).toBeNull()
    expect(parseRecurrenceKind(undefined)).toBeNull()
  })
})

describe('cadenceOfRecurrenceKind', () => {
  it('is total over the closed recurrence set', () => {
    const expected: Record<RecurrenceKind, Cadence> = {
      one_shot: 'oneshot',
      interval: 'interval',
      daily: 'scheduled',
      cron: 'scheduled',
    }
    for (const kind of Object.keys(expected) as RecurrenceKind[]) {
      expect(cadenceOfRecurrenceKind(kind)).toBe(expected[kind])
    }
  })
})

describe('cadence display specs', () => {
  it('defines a spec for every cadence in the filter strip order', () => {
    for (const cadence of SCHED_CADENCE_ORDER) {
      expect(SCHED_CADENCE[cadence]).toBeDefined()
      expect(SCHED_CADENCE[cadence].key).toBe(cadence)
    }
    expect(new Set(SCHED_CADENCE_ORDER)).toEqual(new Set<Cadence>(['scheduled', 'interval', 'oneshot']))
  })
})

describe('SCHED_TERMINAL_NORMALIZED', () => {
  it('is the lowercased projection of SCHED_TERMINAL (one source, live casing)', () => {
    expect(SCHED_TERMINAL_NORMALIZED).toEqual(new Set(SCHED_TERMINAL.map(status => status.toLowerCase())))
    expect(SCHED_TERMINAL_NORMALIZED.has('cancelled')).toBe(true)
    expect(SCHED_TERMINAL_NORMALIZED.has('scheduled')).toBe(false)
  })
})
