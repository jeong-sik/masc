import { describe, it, expect } from 'vitest'

import {
  entryMatchesType,
  entryMatchesSearch,
  filterTrajectoryEntries,
  countByType,
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
    expect(filterTrajectoryEntries(entries, { type: 'all', search: '' })).toHaveLength(4)
  })

  it('filters by type=tool', () => {
    const out = filterTrajectoryEntries(entries, { type: 'tool', search: '' })
    expect(out).toHaveLength(3)
    expect(out.every(e => e.type !== 'thinking')).toBe(true)
  })

  it('filters by type=thinking', () => {
    const out = filterTrajectoryEntries(entries, { type: 'thinking', search: '' })
    expect(out).toHaveLength(1)
    expect(out[0]?.type).toBe('thinking')
  })

  it('filters by search string across type', () => {
    const out = filterTrajectoryEntries(entries, { type: 'all', search: 'plan' })
    expect(out).toHaveLength(1)
    expect(out[0]?.type).toBe('thinking')
  })

  it('combines type and search filters', () => {
    const out = filterTrajectoryEntries(entries, { type: 'tool', search: 'etc' })
    expect(out).toHaveLength(1)
    expect(out[0]?.tool_name).toBe('read_file')
  })

  it('returns empty array when no entries match', () => {
    expect(filterTrajectoryEntries(entries, { type: 'all', search: 'xyz-no-match' })).toEqual([])
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
