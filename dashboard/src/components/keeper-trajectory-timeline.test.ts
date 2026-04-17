import { describe, it, expect } from 'vitest'

import {
  entryMatchesType,
  entryMatchesSearch,
  entryMatchesOutcome,
  filterTrajectoryEntries,
  countByType,
  countByOutcome,
  groupByTurn,
} from './keeper-trajectory-timeline'
import type { TrajectoryEntry } from '../api/dashboard'

function makeToolEntry(overrides: Partial<TrajectoryEntry> = {}): TrajectoryEntry {
  return {
    ts: 1_700_000_000,
    ts_iso: '2026-04-17T00:00:00Z',
    turn: 1,
    round: 1,
    tool_name: 'bash',
    args: { cmd: 'ls -la' },
    duration_ms: 100,
    ...overrides,
  }
}

function makeThinkingEntry(overrides: Partial<TrajectoryEntry> = {}): TrajectoryEntry {
  return {
    type: 'thinking',
    ts: 1_700_000_000,
    ts_iso: '2026-04-17T00:00:00Z',
    turn: 1,
    content: 'thinking about the plan',
    content_length: 22,
    ...overrides,
  }
}

describe('entryMatchesType', () => {
  it('returns true for any entry when type=all', () => {
    expect(entryMatchesType(makeToolEntry(), 'all')).toBe(true)
    expect(entryMatchesType(makeThinkingEntry(), 'all')).toBe(true)
  })

  it('matches thinking entries with type=thinking', () => {
    expect(entryMatchesType(makeThinkingEntry(), 'thinking')).toBe(true)
    expect(entryMatchesType(makeToolEntry(), 'thinking')).toBe(false)
  })

  it('matches tool entries with type=tool (non-thinking)', () => {
    expect(entryMatchesType(makeToolEntry(), 'tool')).toBe(true)
    expect(entryMatchesType(makeThinkingEntry(), 'tool')).toBe(false)
  })
})

describe('entryMatchesSearch', () => {
  it('returns true for empty search string', () => {
    expect(entryMatchesSearch(makeToolEntry(), '')).toBe(true)
  })

  it('matches tool_name case-insensitively', () => {
    expect(entryMatchesSearch(makeToolEntry({ tool_name: 'BashExec' }), 'bashexec')).toBe(true)
    expect(entryMatchesSearch(makeToolEntry({ tool_name: 'BashExec' }), 'exec')).toBe(true)
    expect(entryMatchesSearch(makeToolEntry({ tool_name: 'BashExec' }), 'python')).toBe(false)
  })

  it('matches within args JSON payload', () => {
    const entry = makeToolEntry({ args: { path: '/tmp/trace.log' } })
    expect(entryMatchesSearch(entry, 'trace')).toBe(true)
    expect(entryMatchesSearch(entry, '/tmp')).toBe(true)
    expect(entryMatchesSearch(entry, 'missing')).toBe(false)
  })

  it('matches within string args', () => {
    const entry = makeToolEntry({ args: 'echo hello world' })
    expect(entryMatchesSearch(entry, 'hello')).toBe(true)
    expect(entryMatchesSearch(entry, 'goodbye')).toBe(false)
  })

  it('matches thinking content', () => {
    const entry = makeThinkingEntry({ content: 'should I retry the failed request?' })
    expect(entryMatchesSearch(entry, 'retry')).toBe(true)
    expect(entryMatchesSearch(entry, 'REQUEST')).toBe(true)
    expect(entryMatchesSearch(entry, 'deploy')).toBe(false)
  })

  it('returns false when nothing in entry matches', () => {
    const entry = makeToolEntry({ tool_name: undefined, args: undefined })
    expect(entryMatchesSearch(entry, 'anything')).toBe(false)
  })
})

describe('filterTrajectoryEntries', () => {
  const entries: TrajectoryEntry[] = [
    makeToolEntry({ turn: 1, tool_name: 'bash', args: { cmd: 'ls' } }),
    makeToolEntry({ turn: 1, tool_name: 'read_file', args: { path: '/etc/hosts' } }),
    makeThinkingEntry({ turn: 2, content: 'plan the next step' }),
    makeToolEntry({ turn: 2, tool_name: 'grep', args: { pattern: 'TODO' } }),
  ]

  it('returns all entries when filter is neutral', () => {
    expect(filterTrajectoryEntries(entries, { type: 'all', outcome: 'all', search: '' })).toHaveLength(4)
  })

  it('filters by type=tool', () => {
    const out = filterTrajectoryEntries(entries, { type: 'tool', outcome: 'all', search: '' })
    expect(out).toHaveLength(3)
    expect(out.every(e => e.type !== 'thinking')).toBe(true)
  })

  it('filters by type=thinking', () => {
    const out = filterTrajectoryEntries(entries, { type: 'thinking', outcome: 'all', search: '' })
    expect(out).toHaveLength(1)
    expect(out[0]?.type).toBe('thinking')
  })

  it('filters by search string across type', () => {
    const out = filterTrajectoryEntries(entries, { type: 'all', outcome: 'all', search: 'plan' })
    expect(out).toHaveLength(1)
    expect(out[0]?.type).toBe('thinking')
  })

  it('combines type and search filters', () => {
    const out = filterTrajectoryEntries(entries, { type: 'tool', outcome: 'all', search: 'etc' })
    expect(out).toHaveLength(1)
    expect(out[0]?.tool_name).toBe('read_file')
  })

  it('returns empty array when no entries match', () => {
    expect(filterTrajectoryEntries(entries, { type: 'all', outcome: 'all', search: 'xyz-no-match' })).toEqual([])
  })
})

describe('entryMatchesOutcome', () => {
  it('returns true for any non-thinking entry when outcome=all', () => {
    expect(entryMatchesOutcome(makeToolEntry(), 'all')).toBe(true)
    expect(entryMatchesOutcome(makeToolEntry({ error: 'boom' }), 'all')).toBe(true)
    expect(entryMatchesOutcome(makeToolEntry({ gate: { status: 'reject', reason: 'policy' } }), 'all')).toBe(true)
  })

  it('returns true for thinking entries only when outcome=all', () => {
    expect(entryMatchesOutcome(makeThinkingEntry(), 'all')).toBe(true)
    expect(entryMatchesOutcome(makeThinkingEntry(), 'error')).toBe(false)
    expect(entryMatchesOutcome(makeThinkingEntry(), 'rejected')).toBe(false)
    expect(entryMatchesOutcome(makeThinkingEntry(), 'completed')).toBe(false)
  })

  it('matches error entries when outcome=error', () => {
    expect(entryMatchesOutcome(makeToolEntry({ error: 'network timeout' }), 'error')).toBe(true)
    expect(entryMatchesOutcome(makeToolEntry({ error: null }), 'error')).toBe(false)
    expect(entryMatchesOutcome(makeToolEntry({ error: '' }), 'error')).toBe(false)
    expect(entryMatchesOutcome(makeToolEntry(), 'error')).toBe(false)
  })

  it('matches gate-rejected entries when outcome=rejected', () => {
    const rejected = makeToolEntry({ gate: { status: 'reject', reason: 'policy violation' } })
    expect(entryMatchesOutcome(rejected, 'rejected')).toBe(true)
    expect(entryMatchesOutcome(makeToolEntry({ gate: { status: 'pass' } }), 'rejected')).toBe(false)
    expect(entryMatchesOutcome(makeToolEntry(), 'rejected')).toBe(false)
  })

  it('matches completed entries (no error, not rejected) when outcome=completed', () => {
    expect(entryMatchesOutcome(makeToolEntry(), 'completed')).toBe(true)
    expect(entryMatchesOutcome(makeToolEntry({ gate: { status: 'pass' } }), 'completed')).toBe(true)
    expect(entryMatchesOutcome(makeToolEntry({ error: 'boom' }), 'completed')).toBe(false)
    expect(entryMatchesOutcome(
      makeToolEntry({ gate: { status: 'reject', reason: 'x' } }),
      'completed',
    )).toBe(false)
  })

  it('treats reject as rejected even when error is also set', () => {
    const both = makeToolEntry({
      error: 'tool threw',
      gate: { status: 'reject', reason: 'policy' },
    })
    expect(entryMatchesOutcome(both, 'rejected')).toBe(true)
    // rejected takes precedence in countByOutcome — but entryMatchesOutcome
    // treats error/rejected as independent predicates that can both match:
    expect(entryMatchesOutcome(both, 'error')).toBe(true)
    expect(entryMatchesOutcome(both, 'completed')).toBe(false)
  })
})

describe('countByOutcome', () => {
  it('counts zero for empty input', () => {
    expect(countByOutcome([])).toEqual({ error: 0, rejected: 0, completed: 0 })
  })

  it('skips thinking entries', () => {
    expect(countByOutcome([makeThinkingEntry(), makeThinkingEntry()]))
      .toEqual({ error: 0, rejected: 0, completed: 0 })
  })

  it('buckets tool entries by outcome precedence rejected > error > completed', () => {
    const entries: TrajectoryEntry[] = [
      makeToolEntry(),                                                       // completed
      makeToolEntry({ error: 'boom' }),                                      // error
      makeToolEntry({ gate: { status: 'reject', reason: 'nope' } }),         // rejected
      makeToolEntry({ error: 'x', gate: { status: 'reject', reason: 'y' } }), // rejected (precedence)
      makeThinkingEntry(),                                                   // skipped
    ]
    expect(countByOutcome(entries)).toEqual({ error: 1, rejected: 2, completed: 1 })
  })
})

describe('filterTrajectoryEntries with outcome axis', () => {
  const entries: TrajectoryEntry[] = [
    makeToolEntry({ turn: 1, tool_name: 'ok_tool' }),
    makeToolEntry({ turn: 1, tool_name: 'err_tool', error: 'timeout' }),
    makeToolEntry({
      turn: 2, tool_name: 'blocked', gate: { status: 'reject', reason: 'policy' },
    }),
    makeThinkingEntry({ turn: 2, content: 'plan ahead' }),
  ]

  it('narrows to error entries only', () => {
    const out = filterTrajectoryEntries(entries, { type: 'all', outcome: 'error', search: '' })
    expect(out).toHaveLength(1)
    expect(out[0]?.tool_name).toBe('err_tool')
  })

  it('narrows to rejected entries only', () => {
    const out = filterTrajectoryEntries(entries, { type: 'all', outcome: 'rejected', search: '' })
    expect(out).toHaveLength(1)
    expect(out[0]?.tool_name).toBe('blocked')
  })

  it('narrows to completed entries only (drops thinking + rejected + error)', () => {
    const out = filterTrajectoryEntries(entries, { type: 'all', outcome: 'completed', search: '' })
    expect(out).toHaveLength(1)
    expect(out[0]?.tool_name).toBe('ok_tool')
  })

  it('combines outcome with type filter (thinking + outcome!=all is empty)', () => {
    const out = filterTrajectoryEntries(entries, { type: 'thinking', outcome: 'error', search: '' })
    expect(out).toEqual([])
  })

  it('combines outcome with search filter', () => {
    const out = filterTrajectoryEntries(
      entries,
      { type: 'all', outcome: 'error', search: 'err' },
    )
    expect(out).toHaveLength(1)
    expect(out[0]?.tool_name).toBe('err_tool')
  })
})

describe('countByType', () => {
  it('counts zero for empty input', () => {
    expect(countByType([])).toEqual({ tool: 0, thinking: 0 })
  })

  it('counts tool vs thinking entries', () => {
    const entries = [
      makeToolEntry(),
      makeToolEntry(),
      makeThinkingEntry(),
    ]
    expect(countByType(entries)).toEqual({ tool: 2, thinking: 1 })
  })

  it('treats entries without type as tool', () => {
    // Explicitly undefined type → classified as tool (non-thinking)
    const entries = [makeToolEntry({ type: undefined })]
    expect(countByType(entries)).toEqual({ tool: 1, thinking: 0 })
  })
})

describe('groupByTurn', () => {
  it('groups entries sharing a turn number', () => {
    const entries = [
      makeToolEntry({ turn: 1 }),
      makeToolEntry({ turn: 1 }),
      makeToolEntry({ turn: 2 }),
    ]
    const groups = groupByTurn(entries)
    expect(groups.get(1)).toHaveLength(2)
    expect(groups.get(2)).toHaveLength(1)
  })

  it('preserves insertion order within a turn', () => {
    const a = makeToolEntry({ turn: 1, tool_name: 'first' })
    const b = makeToolEntry({ turn: 1, tool_name: 'second' })
    const groups = groupByTurn([a, b])
    expect(groups.get(1)?.[0]?.tool_name).toBe('first')
    expect(groups.get(1)?.[1]?.tool_name).toBe('second')
  })

  it('returns empty map for empty input', () => {
    expect(groupByTurn([]).size).toBe(0)
  })
})
