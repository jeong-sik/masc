import { describe, it, expect } from 'vitest'
import {
  swimlaneSegmentColor,
  isTransitionInSegment,
  filterTransitionHistory,
  type TransitionHistoryEntry,
} from './fsm-hub-timeline-panels'

// ── swimlaneSegmentColor ──────────────────────────────────────

describe('swimlaneSegmentColor', () => {
  it('returns alarm color for alarm values', () => {
    expect(swimlaneSegmentColor('Failing')).toBe('bg-[rgba(239,68,68,0.5)]')
    expect(swimlaneSegmentColor('gate_rejected')).toBe('bg-[rgba(239,68,68,0.5)]')
    expect(swimlaneSegmentColor('exhausted')).toBe('bg-[rgba(239,68,68,0.5)]')
    // Overflowed is in ALARM_VALUES, so it returns alarm color (line 55 matches first)
    expect(swimlaneSegmentColor('Overflowed')).toBe('bg-[rgba(239,68,68,0.5)]')
  })

  it('returns idle color for idle-like values', () => {
    expect(swimlaneSegmentColor('idle')).toBe('bg-[var(--white-7)]')
    expect(swimlaneSegmentColor('undecided')).toBe('bg-[var(--white-7)]')
    expect(swimlaneSegmentColor('accumulating')).toBe('bg-[var(--white-7)]')
    expect(swimlaneSegmentColor('Stable')).toBe('bg-[var(--white-7)]')
  })

  it('returns warn color for Compacting', () => {
    expect(swimlaneSegmentColor('Compacting')).toBe('bg-[rgba(245,158,11,0.45)]')
    expect(swimlaneSegmentColor('compacting')).toBe('bg-[rgba(245,158,11,0.45)]')
  })

  it('returns handoff color for HandingOff', () => {
    expect(swimlaneSegmentColor('HandingOff')).toBe('bg-[rgba(167,139,250,0.5)]')
  })

  it('returns default active color for unknown values', () => {
    expect(swimlaneSegmentColor('Running')).toBe('bg-[rgba(129,140,248,0.45)]')
    expect(swimlaneSegmentColor('thinking')).toBe('bg-[rgba(129,140,248,0.45)]')
  })
})

// ── isTransitionInSegment ─────────────────────────────────────

describe('isTransitionInSegment', () => {
  const baseSegment = {
    field: 'KCL',
    laneKey: 'cascade' as const,
    value: 'trying',
    from: 1000,
    to: 2000,
  }

  it('returns false when segment is null', () => {
    expect(isTransitionInSegment({ ts: 1500, field: 'KCL' }, null)).toBe(false)
  })

  it('returns false when field does not match', () => {
    expect(isTransitionInSegment({ ts: 1500, field: 'KTC' }, baseSegment)).toBe(false)
  })

  it('returns true when ts is within segment range', () => {
    expect(isTransitionInSegment({ ts: 1500, field: 'KCL' }, baseSegment)).toBe(true)
  })

  it('returns true at exact boundaries', () => {
    expect(isTransitionInSegment({ ts: 1000, field: 'KCL' }, baseSegment)).toBe(true)
    expect(isTransitionInSegment({ ts: 2000, field: 'KCL' }, baseSegment)).toBe(true)
  })

  it('returns false when ts is outside segment range', () => {
    expect(isTransitionInSegment({ ts: 999, field: 'KCL' }, baseSegment)).toBe(false)
    expect(isTransitionInSegment({ ts: 2001, field: 'KCL' }, baseSegment)).toBe(false)
  })
})

// ── filterTransitionHistory ───────────────────────────────────

describe('filterTransitionHistory', () => {
  const sample: TransitionHistoryEntry[] = [
    { ts: 1000, field: 'KCL', from: 'idle', to: 'trying' },
    { ts: 1100, field: 'KCL', from: 'trying', to: 'idle' },
    { ts: 1200, field: 'KTC', from: 'Idle', to: 'Running' },
    { ts: 1300, field: 'KSM', from: 'Stable', to: 'Compacting' },
    { ts: 1400, field: 'KMC', from: 'accumulating', to: 'Overflowed' },
    { ts: 1500, field: 'KDP', from: 'undecided', to: 'gate_rejected' },
  ]

  it('returns input reference unchanged for empty query', () => {
    expect(filterTransitionHistory(sample, '')).toBe(sample)
  })

  it('returns input reference unchanged for whitespace-only query', () => {
    expect(filterTransitionHistory(sample, '   ')).toBe(sample)
  })

  it('filters by field (case-insensitive)', () => {
    const result = filterTransitionHistory(sample, 'kcl')
    expect(result).toHaveLength(2)
    expect(result.every(e => e.field === 'KCL')).toBe(true)
  })

  it('filters by from state (case-insensitive)', () => {
    const result = filterTransitionHistory(sample, 'STABLE')
    expect(result).toHaveLength(1)
    expect(result[0]?.field).toBe('KSM')
  })

  it('filters by to state (case-insensitive)', () => {
    const result = filterTransitionHistory(sample, 'overflowed')
    expect(result).toHaveLength(1)
    expect(result[0]?.to).toBe('Overflowed')
  })

  it('matches substring across fields (trying matches both from and to)', () => {
    const result = filterTransitionHistory(sample, 'trying')
    expect(result).toHaveLength(2)
    expect(result.map(e => e.ts)).toEqual([1000, 1100])
  })

  it('trims the query before matching', () => {
    const result = filterTransitionHistory(sample, '  KTC  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.field).toBe('KTC')
  })

  it('returns empty array when no entry matches', () => {
    const result = filterTransitionHistory(sample, 'zzz-nomatch')
    expect(result).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.map(e => ({ ...e }))
    filterTransitionHistory(sample, 'kcl')
    expect(sample).toEqual(snapshot)
  })

  it('handles empty history', () => {
    const empty: TransitionHistoryEntry[] = []
    expect(filterTransitionHistory(empty, 'anything')).toEqual([])
    expect(filterTransitionHistory(empty, '')).toBe(empty)
  })
})
