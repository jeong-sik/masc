import { describe, expect, it } from 'vitest'

import {
  KeeperTransitionsSchemaDriftError,
  parseKeeperTransitionsResponse,
} from './keeper-transitions'

function validTransition(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    prev_phase: 'Running',
    new_phase: 'Compacting',
    selected_event: null,
    wall_clock_at_decision: 1_712_000_000.5,
    transition_outcome: 'ok',
    ...overrides,
  }
}

describe('parseKeeperTransitionsResponse', () => {
  it('accepts an empty transitions list', () => {
    const out = parseKeeperTransitionsResponse({
      keeper: 'greeter',
      current_phase: 'Running',
      count: 0,
      transitions: [],
    })
    expect(out.keeper).toBe('greeter')
    expect(out.transitions).toHaveLength(0)
  })

  it('accepts a populated list with opaque selected_event', () => {
    // selected_event is stored as unknown on purpose — callers render
    // it for diagnostics only, not for branching.
    const out = parseKeeperTransitionsResponse({
      keeper: 'greeter',
      current_phase: 'Running',
      count: 2,
      transitions: [
        validTransition(),
        validTransition({
          prev_phase: 'Compacting',
          new_phase: 'Running',
          selected_event: { kind: 'tool_result', tool: 'masc_check' },
        }),
      ],
    })
    expect(out.transitions).toHaveLength(2)
    expect(out.transitions[1]!.new_phase).toBe('Running')
  })

  it('accepts null current_phase (just-booted keeper with no decisions yet)', () => {
    const out = parseKeeperTransitionsResponse({
      keeper: 'cold-start',
      current_phase: null,
      count: 0,
      transitions: [],
    })
    expect(out.current_phase).toBeNull()
  })

  it('accepts unknown phase values (backend evolves new phases ahead of dashboard)', () => {
    // Phases are open `string()` — a new backend phase should not
    // brick the transition strip during a backend-ahead deploy window.
    const out = parseKeeperTransitionsResponse({
      keeper: 'g',
      current_phase: 'NovelPhase',
      count: 1,
      transitions: [validTransition({ new_phase: 'NovelPhase' })],
    })
    expect(out.current_phase).toBe('NovelPhase')
  })

  it('throws when a required field is missing', () => {
    const bad = {
      keeper: 'g',
      current_phase: null,
      count: 1,
      transitions: [validTransition({ wall_clock_at_decision: undefined })],
    }
    expect(() => parseKeeperTransitionsResponse(bad)).toThrow(
      KeeperTransitionsSchemaDriftError,
    )
  })

  it('throws when transitions is not an array', () => {
    const bad = {
      keeper: 'g',
      current_phase: null,
      count: 0,
      transitions: 'not-an-array',
    }
    expect(() => parseKeeperTransitionsResponse(bad)).toThrow(
      KeeperTransitionsSchemaDriftError,
    )
  })

  it('throws on non-object payload', () => {
    expect(() => parseKeeperTransitionsResponse(null)).toThrow(
      KeeperTransitionsSchemaDriftError,
    )
  })
})
