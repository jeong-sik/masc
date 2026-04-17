import { describe, expect, it } from 'vitest'
import type { AttributionEvent, AttributionOutcome } from '../api/attribution'
import { filterAttributionEvents } from './attribution-panel'

function makeEvent(
  overrides: Partial<{
    gate: string
    origin: 'det' | 'nondet'
    outcome: AttributionOutcome
    recorded_at: number
  }> = {},
): AttributionEvent {
  return {
    attribution: {
      origin: overrides.origin ?? 'det',
      gate: overrides.gate ?? 'cdal_verdict',
      evidence: null,
      outcome: overrides.outcome ?? { kind: 'passed' },
    },
    recorded_at: overrides.recorded_at ?? 1_700_000_000,
  }
}

describe('filterAttributionEvents', () => {
  const events: readonly AttributionEvent[] = [
    makeEvent({
      gate: 'cdal_verdict',
      origin: 'det',
      outcome: { kind: 'policy_failed', reason: 'invalid signature' },
    }),
    makeEvent({
      gate: 'verification',
      origin: 'nondet',
      outcome: { kind: 'partial_pass', score: 0.7, rationale: 'weak evidence' },
    }),
    makeEvent({
      gate: 'keeper_fsm',
      origin: 'det',
      outcome: {
        kind: 'transition_blocked',
        from_state: 'Idle',
        to_state: 'Running',
        reason: 'budget exhausted',
      },
    }),
    makeEvent({ gate: 'autoresearch', origin: 'nondet', outcome: { kind: 'passed' } }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterAttributionEvents(events, '')).toBe(events)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterAttributionEvents(events, '   ')).toBe(events)
  })

  it('matches by gate substring (case-insensitive)', () => {
    const result = filterAttributionEvents(events, 'CDAL')
    expect(result).toHaveLength(1)
    expect(result[0]!.attribution.gate).toBe('cdal_verdict')
  })

  it('matches by origin', () => {
    const result = filterAttributionEvents(events, 'nondet')
    expect(result.map(r => r.attribution.gate)).toEqual(['verification', 'autoresearch'])
  })

  it('matches policy_failed reason', () => {
    const result = filterAttributionEvents(events, 'signature')
    expect(result).toHaveLength(1)
    expect(result[0]!.attribution.gate).toBe('cdal_verdict')
  })

  it('matches partial_pass rationale', () => {
    const result = filterAttributionEvents(events, 'weak')
    expect(result).toHaveLength(1)
    expect(result[0]!.attribution.gate).toBe('verification')
  })

  it('matches transition_blocked reason / from_state / to_state', () => {
    expect(filterAttributionEvents(events, 'budget')).toHaveLength(1)
    expect(filterAttributionEvents(events, 'Idle')).toHaveLength(1)
    expect(filterAttributionEvents(events, 'running')).toHaveLength(1)
  })

  it('trims query before matching', () => {
    const result = filterAttributionEvents(events, '  cdal  ')
    expect(result).toHaveLength(1)
  })

  it('returns empty when no field matches', () => {
    expect(filterAttributionEvents(events, 'nonexistent-token')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const copy = events.slice()
    filterAttributionEvents(events, 'cdal')
    expect(events).toEqual(copy)
  })

  it('composes with an already-gate-filtered subset (gate + text stack)', () => {
    // Simulate the server-filtered subset that comes back when
    // filterGate.value === 'keeper_fsm'.
    const gateFiltered = events.filter(e => e.attribution.gate === 'keeper_fsm')
    const result = filterAttributionEvents(gateFiltered, 'budget')
    expect(result).toHaveLength(1)
    expect(result[0]!.attribution.gate).toBe('keeper_fsm')

    // Gate + text where text does not match within the gate subset.
    const noMatch = filterAttributionEvents(gateFiltered, 'signature')
    expect(noMatch).toHaveLength(0)
  })
})
