import { describe, it, expect } from 'vitest'
import {
  swimlaneSegmentColor,
  isTransitionInSegment,
  filterTransitionHistory,
  type TransitionHistoryEntry,
} from './fsm-hub-timeline-panels'

// ── swimlaneSegmentColor ──────────────────────────────────────

// Wire format: backend (keeper_state_machine.ml:21-35 + keeper_composite_observer.ml:141-201)
// emits all lane values lowercase + snake_case. Prior fixtures asserted
// PascalCase ('Failing', 'Overflowed', 'Stable', 'HandingOff') that the
// backend never emits — mock↔mock loophole that hid the dead branches.
describe('swimlaneSegmentColor', () => {
  it('returns alarm color for alarm values', () => {
    expect(swimlaneSegmentColor('failing')).toBe('bg-[var(--bad-50)]')
    expect(swimlaneSegmentColor('exhausted')).toBe('bg-[var(--bad-50)]')
  })

  it('returns idle color for idle-like values', () => {
    expect(swimlaneSegmentColor('idle')).toBe('bg-[var(--color-bg-panel-alt)]')
    expect(swimlaneSegmentColor('undecided')).toBe('bg-[var(--color-bg-panel-alt)]')
    expect(swimlaneSegmentColor('accumulating')).toBe('bg-[var(--color-bg-panel-alt)]')
  })

  it('returns warn color for overflowed and compacting', () => {
    expect(swimlaneSegmentColor('overflowed')).toBe('bg-[var(--amber-bright-45)]')
    expect(swimlaneSegmentColor('compacting')).toBe('bg-[var(--amber-bright-45)]')
  })

  it('returns handoff color for handing_off', () => {
    expect(swimlaneSegmentColor('handing_off')).toBe('bg-[var(--purple-50)]')
  })

  it('returns default active color for unknown / active values', () => {
    expect(swimlaneSegmentColor('running')).toBe('bg-[var(--indigo-45)]')
    expect(swimlaneSegmentColor('thinking')).toBe('bg-[var(--indigo-45)]')
  })
})

// ── isTransitionInSegment ─────────────────────────────────────

describe('isTransitionInSegment', () => {
  const baseSegment = {
    field: 'KCL',
    laneKey: 'runtime' as const,
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
    { ts: 1500, field: 'KDP', from: 'guard_ok', to: 'tool_policy_selected' },
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
