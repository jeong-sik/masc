import { describe, expect, it } from 'vitest'
import {
  topKeepers,
  describeAgentEvent,
  describeSampleWindow,
  describeTotalEventsDetail,
} from './oas-health-chip'
import type { OasAgentEvent, OasHealthSummary, OasKeeperSnapshot } from '../types/oas'

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
  function evt(partial: OasAgentEvent): OasAgentEvent {
    return partial
  }

  it('renders label + action', () => {
    expect(describeAgentEvent(evt({
      type: 'action_executed',
      actor_kind: 'agent',
      agent_name: 'a',
      timestamp: 0,
      action: 'ponder',
    }))).toBe('실행 · ponder')
  })

  it('falls back to trigger_reason when decision action is absent', () => {
    expect(describeAgentEvent(evt({
      type: 'decision',
      actor_kind: 'agent',
      agent_name: 'a',
      timestamp: 0,
      trigger_reason: 'shortlist',
    }))).toBe('결정 · shortlist')
  })

  it('falls back to trigger when action and event absent', () => {
    expect(describeAgentEvent(evt({
      type: 'selected',
      actor_kind: 'agent',
      agent_name: 'a',
      timestamp: 0,
      trigger: 'heartbeat',
    }))).toBe('선택 · heartbeat')
  })

  it('includes secondary_agent arrow when present', () => {
    expect(describeAgentEvent(evt({
      type: 'trust_updated',
      actor_kind: 'agent',
      agent_name: 'a',
      timestamp: 0,
      trust_score: 0.75,
      secondary_agent: 'b',
    }))).toBe('신뢰도 · 0.75 → b')
  })

  it('prefers lifecycle event and phase when present', () => {
    expect(describeAgentEvent(evt({
      type: 'keeper_lifecycle',
      actor_kind: 'keeper',
      agent_name: 'keeper-a',
      keeper_name: 'keeper-a',
      timestamp: 0,
      event: 'started',
      phase: 'running',
    }))).toBe('생명주기 · started')
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
      const rendered = describeAgentEvent(
        t === 'selected'
          ? evt({ type: t, actor_kind: 'agent', agent_name: 'a', timestamp: 0 })
          : t === 'decision'
            ? evt({ type: t, actor_kind: 'agent', agent_name: 'a', timestamp: 0 })
            : t === 'action_executed'
              ? evt({ type: t, actor_kind: 'agent', agent_name: 'a', timestamp: 0 })
              : t === 'keeper_lifecycle'
                ? evt({ type: t, actor_kind: 'keeper', agent_name: 'a', timestamp: 0 })
                : t === 'trust_updated'
                  ? evt({ type: t, actor_kind: 'agent', agent_name: 'a', timestamp: 0 })
                  : evt({ type: t, actor_kind: 'agent', agent_name: 'a', timestamp: 0 }),
      )
      // Non-Latin label should be present (Korean)
      expect(rendered.length).toBeGreaterThan(0)
      expect(/^[a-zA-Z]+$/.test(rendered)).toBe(false)
    }
  })
})

describe('describeTotalEventsDetail', () => {
  it('marks truncated replay windows explicitly', () => {
    const summary = {
      totalEvents: 1842,
      replayLoadedEvents: 500,
      replayTotalMatchingEvents: 1842,
      replayTruncated: true,
    } satisfies Pick<OasHealthSummary, 'totalEvents' | 'replayLoadedEvents' | 'replayTotalMatchingEvents' | 'replayTruncated'>

    expect(describeTotalEventsDetail(summary)).toBe('replay 500/1842 + live')
    expect(describeSampleWindow(summary)).toBe('sample 500/1842')
  })

  it('falls back to durable replay when no truncation happened', () => {
    const summary = {
      totalEvents: 42,
      replayLoadedEvents: 42,
      replayTotalMatchingEvents: 42,
      replayTruncated: false,
    } satisfies Pick<OasHealthSummary, 'totalEvents' | 'replayLoadedEvents' | 'replayTotalMatchingEvents' | 'replayTruncated'>

    expect(describeTotalEventsDetail(summary)).toBe('durable replay + live')
    expect(describeSampleWindow(summary)).toBeNull()
  })
})
