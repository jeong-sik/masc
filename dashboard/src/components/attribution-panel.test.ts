import { describe, expect, it } from 'vitest'
import type { AttributionEvent, AttributionOutcome } from '../api/attribution'
import { filterAttributionEvents, gatesToRender } from './attribution-panel'

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
      gate: overrides.gate ?? 'accountability',
      evidence: {},
      outcome: overrides.outcome ?? { kind: 'passed' },
    },
    recorded_at: overrides.recorded_at ?? 1_700_000_000,
  }
}

describe('filterAttributionEvents', () => {
  const events: readonly AttributionEvent[] = [
    makeEvent({
      gate: 'accountability',
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
    makeEvent({ gate: 'oas_completion', origin: 'nondet', outcome: { kind: 'passed' } }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterAttributionEvents(events, '')).toBe(events)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterAttributionEvents(events, '   ')).toBe(events)
  })

  it('matches by gate substring (case-insensitive)', () => {
    const result = filterAttributionEvents(events, 'account')
    expect(result).toHaveLength(1)
    expect(result[0]!.attribution.gate).toBe('accountability')
  })

  it('matches by origin', () => {
    const result = filterAttributionEvents(events, 'nondet')
    expect(result.map(r => r.attribution.gate)).toEqual(['verification', 'oas_completion'])
  })

  it('matches policy_failed reason', () => {
    const result = filterAttributionEvents(events, 'signature')
    expect(result).toHaveLength(1)
    expect(result[0]!.attribution.gate).toBe('accountability')
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
    const result = filterAttributionEvents(events, '  account  ')
    expect(result).toHaveLength(1)
  })

  it('returns empty when no field matches', () => {
    expect(filterAttributionEvents(events, 'nonexistent-token')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const copy = events.slice()
    filterAttributionEvents(events, 'account')
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

describe('gatesToRender', () => {
  const known = ['accountability', 'verification', 'keeper_fsm'] as const

  it('keeps the known gates first, in declared order', () => {
    expect(gatesToRender(known, [])).toEqual(['accountability', 'verification', 'keeper_fsm'])
  })

  it('appends a data gate that is not in the known set (no silent drop)', () => {
    // The bug class: a backend-emitted gate absent from the known allow-list
    // would never get a card. The union surfaces it instead.
    expect(gatesToRender(known, ['exec_policy'])).toEqual([
      'accountability', 'verification', 'keeper_fsm', 'exec_policy',
    ])
  })

  it('does not duplicate a data gate already in the known set', () => {
    expect(gatesToRender(known, ['verification', 'keeper_fsm'])).toEqual([
      'accountability', 'verification', 'keeper_fsm',
    ])
  })

  it('sorts the appended extras for stable ordering', () => {
    expect(gatesToRender(known, ['zeta_gate', 'alpha_gate'])).toEqual([
      'accountability', 'verification', 'keeper_fsm', 'alpha_gate', 'zeta_gate',
    ])
  })

  it('surfaces exec_policy even when it is missing from the known set', () => {
    // Regression guard: exec_policy is a live backend attribution gate
    // (lib/exec_policy/exec_policy.ml). It must never be silently uncategorized.
    expect(gatesToRender(known, ['exec_policy', 'verification'])).toContain('exec_policy')
  })
})
