import { describe, it, expect } from 'vitest'
import {
  swimlaneSegmentColor,
  isTransitionInSegment,
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
    expect(swimlaneSegmentColor('idle')).toBe('bg-[rgba(255,255,255,0.07)]')
    expect(swimlaneSegmentColor('undecided')).toBe('bg-[rgba(255,255,255,0.07)]')
    expect(swimlaneSegmentColor('accumulating')).toBe('bg-[rgba(255,255,255,0.07)]')
    expect(swimlaneSegmentColor('Stable')).toBe('bg-[rgba(255,255,255,0.07)]')
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
