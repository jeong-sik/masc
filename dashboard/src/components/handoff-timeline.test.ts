import { describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../api/dashboard'
import {
  A2A_EVENT_TYPES,
  CHIP_CLASS_BY_KIND,
  deriveTimelineRows,
  kindOfEventType,
} from './handoff-timeline'

function makeEntry(overrides: Partial<TelemetryEntry>): TelemetryEntry {
  return {
    source: 'oas_event',
    event_type: 'agent_started',
    agent_name: 'alpha',
    ts_unix: 1_000_000,
    ...overrides,
  } as TelemetryEntry
}

describe('kindOfEventType', () => {
  it('maps each declared A2A event type to a known kind', () => {
    for (const et of A2A_EVENT_TYPES) {
      const k = kindOfEventType(et)
      expect(CHIP_CLASS_BY_KIND[k]).toBeDefined()
      expect(k).not.toBe('unknown')
    }
  })

  it('classifies failure separately from lifecycle', () => {
    expect(kindOfEventType('agent_failed')).toBe('failure')
    expect(kindOfEventType('agent_started')).toBe('lifecycle')
    expect(kindOfEventType('turn_completed')).toBe('lifecycle')
  })

  it('classifies tool/handoff/context by prefix', () => {
    expect(kindOfEventType('tool_called')).toBe('tool')
    expect(kindOfEventType('handoff_requested')).toBe('handoff')
    expect(kindOfEventType('context_compacted')).toBe('context')
  })

  it('falls back to unknown for unrecognised event types', () => {
    expect(kindOfEventType('completely_new_event')).toBe('unknown')
  })
})

describe('deriveTimelineRows', () => {
  const WIN_START = 1_000_000_000
  const WIN_END = 1_000_000_500
  const WIN_START_MS = WIN_START * 1000
  const WIN_END_MS = WIN_END * 1000

  it('returns empty array when windowEnd <= windowStart', () => {
    expect(deriveTimelineRows([], 100, 100)).toEqual([])
    expect(deriveTimelineRows([], 200, 100)).toEqual([])
  })

  it('ignores entries that are not oas_event source', () => {
    const entries = [
      makeEntry({ source: 'keeper_metric' as TelemetryEntry['source'], ts_unix: WIN_START + 1 }),
      makeEntry({ source: 'tool_usage' as TelemetryEntry['source'], ts_unix: WIN_START + 2 }),
    ]
    expect(deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)).toEqual([])
  })

  it('ignores entries with unknown event_type (not in A2A set)', () => {
    const entries = [
      makeEntry({ event_type: 'mystery_event', ts_unix: WIN_START + 1 }),
    ]
    expect(deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)).toEqual([])
  })

  it('ignores entries missing agent_name AND keeper_name', () => {
    const entries = [
      makeEntry({ agent_name: undefined, keeper_name: undefined, ts_unix: WIN_START + 1 }),
    ]
    expect(deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)).toEqual([])
  })

  it('groups events by agent_name and sorts chips ascending by timestamp', () => {
    const entries = [
      makeEntry({ agent_name: 'alpha', event_type: 'turn_completed', ts_unix: WIN_START + 10 }),
      makeEntry({ agent_name: 'alpha', event_type: 'agent_started',  ts_unix: WIN_START + 5  }),
      makeEntry({ agent_name: 'beta',  event_type: 'tool_called',     ts_unix: WIN_START + 20 }),
    ]
    const rows = deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)
    expect(rows.map(r => r.keeper)).toEqual(['alpha', 'beta'])
    const alpha = rows[0]!
    expect(alpha.chips.map(c => c.eventType)).toEqual(['agent_started', 'turn_completed'])
    expect(alpha.chips[0]!.ts).toBeLessThan(alpha.chips[1]!.ts)
  })

  it('sorts rows by first-chip timestamp so earliest-active keeper is on top', () => {
    const entries = [
      makeEntry({ agent_name: 'late',    ts_unix: WIN_START + 100 }),
      makeEntry({ agent_name: 'early',   ts_unix: WIN_START + 10  }),
      makeEntry({ agent_name: 'middle',  ts_unix: WIN_START + 50  }),
    ]
    const rows = deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)
    expect(rows.map(r => r.keeper)).toEqual(['early', 'middle', 'late'])
  })

  it('filters chips outside [windowStart, windowEnd]', () => {
    const entries = [
      makeEntry({ agent_name: 'alpha', ts_unix: WIN_START - 1   }),
      makeEntry({ agent_name: 'alpha', ts_unix: WIN_START + 10  }),
      makeEntry({ agent_name: 'alpha', ts_unix: WIN_END   + 10  }),
    ]
    const rows = deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.chips).toHaveLength(1)
  })

  it('carries peerAgent from to_agent or from_agent for handoff events', () => {
    const entries = [
      makeEntry({
        agent_name: 'alpha',
        event_type: 'handoff_requested',
        to_agent: 'beta',
        ts_unix: WIN_START + 5,
      }),
      makeEntry({
        agent_name: 'beta',
        event_type: 'handoff_completed',
        from_agent: 'alpha',
        ts_unix: WIN_START + 8,
      }),
    ]
    const rows = deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)
    const alphaPeer = rows.find(r => r.keeper === 'alpha')?.chips[0]?.peerAgent
    const betaPeer  = rows.find(r => r.keeper === 'beta')?.chips[0]?.peerAgent
    expect(alphaPeer).toBe('beta')
    expect(betaPeer).toBe('alpha')
  })

  it('accepts keeper_name as a fallback when agent_name is missing', () => {
    const entries = [
      makeEntry({ agent_name: undefined, keeper_name: 'ani1999', ts_unix: WIN_START + 1 }),
    ]
    const rows = deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.keeper).toBe('ani1999')
  })

  it('classifies agent_failed chips as failure kind for red render', () => {
    const entries = [
      makeEntry({ event_type: 'agent_failed', ts_unix: WIN_START + 1 }),
    ]
    const rows = deriveTimelineRows(entries, WIN_START_MS, WIN_END_MS)
    expect(rows[0]!.chips[0]!.kind).toBe('failure')
  })
})
