import { describe, expect, it } from 'vitest'
import { topKeepers, describeAgentEvent } from './oas-health-chip'
import type { OasAgentEvent, OasKeeperSnapshot } from '../types/oas'

function snap(name: string, ts: number, extras: Partial<OasKeeperSnapshot> = {}): OasKeeperSnapshot {
  return {
    keeper_name: name,
    generation: 1,
    context_ratio: 0.1,
    message_count: 0,
    timestamp: ts,
    ...extras,
  }
}

describe('topKeepers', () => {
  it('returns keepers sorted by timestamp descending', () => {
    const map = new Map<string, OasKeeperSnapshot>([
      ['a', snap('a', 100)],
      ['b', snap('b', 300)],
      ['c', snap('c', 200)],
    ])
    const result = topKeepers(map, 10)
    expect(result.map(k => k.keeper_name)).toEqual(['b', 'c', 'a'])
  })

  it('clamps to limit', () => {
    const map = new Map<string, OasKeeperSnapshot>([
      ['a', snap('a', 1)],
      ['b', snap('b', 2)],
      ['c', snap('c', 3)],
      ['d', snap('d', 4)],
    ])
    expect(topKeepers(map, 2)).toHaveLength(2)
    expect(topKeepers(map, 2).map(k => k.keeper_name)).toEqual(['d', 'c'])
  })

  it('returns empty for empty map', () => {
    expect(topKeepers(new Map(), 3)).toEqual([])
  })

  it('returns all when limit exceeds size', () => {
    const map = new Map<string, OasKeeperSnapshot>([
      ['only', snap('only', 42)],
    ])
    expect(topKeepers(map, 10)).toHaveLength(1)
  })
})

describe('describeAgentEvent', () => {
  function evt(partial: Partial<OasAgentEvent> & { type: OasAgentEvent['type'] }): OasAgentEvent {
    return {
      agent_name: 'a',
      timestamp: 0,
      ...partial,
    }
  }

  it('renders label + action', () => {
    expect(describeAgentEvent(evt({ type: 'action_executed', action: 'ponder' }))).toBe('실행 · ponder')
  })

  it('falls back to event when action absent', () => {
    expect(describeAgentEvent(evt({ type: 'decision', event: 'shortlist' }))).toBe('결정 · shortlist')
  })

  it('falls back to trigger when action and event absent', () => {
    expect(describeAgentEvent(evt({ type: 'selected', trigger: 'heartbeat' }))).toBe('선택 · heartbeat')
  })

  it('includes secondary_agent arrow when present', () => {
    expect(describeAgentEvent(evt({
      type: 'trust_updated',
      action: 'bump',
      secondary_agent: 'b',
    }))).toBe('신뢰도 · bump → b')
  })

  it('omits action segment when all three fields missing', () => {
    expect(describeAgentEvent(evt({ type: 'keeper_lifecycle' }))).toBe('생명주기')
  })

  it('maps all discriminants to Korean labels', () => {
    const types: OasAgentEvent['type'][] = [
      'selected',
      'decision',
      'action_executed',
      'keeper_lifecycle',
      'trust_updated',
      'reputation_changed',
    ]
    for (const t of types) {
      const rendered = describeAgentEvent(evt({ type: t }))
      // Non-Latin label should be present (Korean)
      expect(rendered.length).toBeGreaterThan(0)
      expect(/^[a-zA-Z]+$/.test(rendered)).toBe(false)
    }
  })
})
