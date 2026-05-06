import { describe, expect, it } from 'vitest'
import type { MemorySubsystemsMemoryEntry, MemorySubsystemsSynapse } from '../api/dashboard'
import { ARCHITECTURE_FLOW, filterMemoryEntries, filterSynapses } from './memory-subsystems'

function makeSynapse(
  overrides: Partial<MemorySubsystemsSynapse> = {},
): MemorySubsystemsSynapse {
  return {
    from_agent: 'keeper-alpha',
    to_agent: 'keeper-beta',
    weight: 0.5,
    success_count: 1,
    failure_count: 0,
    last_updated: 0,
    created_at: 0,
    ...overrides,
  }
}

describe('filterSynapses', () => {
  const rows: MemorySubsystemsSynapse[] = [
    makeSynapse({ from_agent: 'keeper-alpha', to_agent: 'keeper-beta' }),
    makeSynapse({ from_agent: 'keeper-beta', to_agent: 'watcher-gamma' }),
    makeSynapse({ from_agent: 'router-delta', to_agent: 'keeper-alpha' }),
    makeSynapse({ from_agent: 'planner-epsilon', to_agent: 'router-delta' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterSynapses(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterSynapses(rows, '   ')).toBe(rows)
  })

  it('matches by from_agent substring (case-insensitive)', () => {
    const result = filterSynapses(rows, 'ALPHA')
    // keeper-alpha appears as from_agent in [0] and as to_agent in [2]
    expect(result).toHaveLength(2)
    expect(result.map(r => `${r.from_agent}->${r.to_agent}`)).toEqual([
      'keeper-alpha->keeper-beta',
      'router-delta->keeper-alpha',
    ])
  })

  it('matches by to_agent substring', () => {
    const result = filterSynapses(rows, 'gamma')
    expect(result.map(r => r.to_agent)).toEqual(['watcher-gamma'])
  })

  it('matches a token shared across from and to fields', () => {
    // keeper-* appears in 3 out of 4 rows
    const result = filterSynapses(rows, 'keeper')
    expect(result).toHaveLength(3)
  })

  it('returns empty when no field matches', () => {
    expect(filterSynapses(rows, 'nonexistent-needle')).toHaveLength(0)
  })

  it('trims the query before matching', () => {
    expect(filterSynapses(rows, '  router-delta  ')).toHaveLength(2)
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterSynapses(rows, 'keeper')
    expect(rows).toEqual(copy)
    expect(rows).toHaveLength(4)
  })

  it('handles an empty input array', () => {
    expect(filterSynapses([], 'keeper')).toEqual([])
    const empty: MemorySubsystemsSynapse[] = []
    expect(filterSynapses(empty, '')).toBe(empty)
  })

  it('matches partial substrings at token boundaries', () => {
    const result = filterSynapses(rows, 'router')
    // router-delta appears as from_agent in [3] and as to_agent in [3]'s twin row
    expect(result).toHaveLength(2)
    expect(result.map(r => r.from_agent)).toContain('router-delta')
    expect(result.map(r => r.to_agent)).toContain('router-delta')
  })
})

describe('filterMemoryEntries', () => {
  const entries: MemorySubsystemsMemoryEntry[] = [
    { keeper: 'sangsu', kind: 'verified', text: 'PR verified', priority: 90, ts_unix: 1 },
    { keeper: 'issue_king', kind: 'learned', text: 'task duplicate', priority: 70, ts_unix: 2 },
    { keeper: 'qa-king', kind: 'verified', text: 'release target checked', priority: 85, ts_unix: 3 },
  ]

  it('returns the input reference for all entries', () => {
    expect(filterMemoryEntries(entries, 'all')).toBe(entries)
    expect(filterMemoryEntries(entries, '')).toBe(entries)
  })

  it('keeps entries with the selected memory kind', () => {
    const result = filterMemoryEntries(entries, 'verified')
    expect(result.map(entry => entry.keeper)).toEqual(['sangsu', 'qa-king'])
  })

  it('returns empty when the kind is absent', () => {
    expect(filterMemoryEntries(entries, 'plan')).toEqual([])
  })
})

describe('ARCHITECTURE_FLOW', () => {
  // Mermaid classDef cannot lex CSS var(--token); paren confuses the property
  // delimiter and the whole diagram falls back to the parse error bomb SVG.
  // Same root cause as PR #8843 (composite-fsm-flowchart) and #11141
  // (harness-health). Keep colors as hex literals here too.
  it('uses literal hex colors in classDef (no CSS var())', () => {
    const classDefLines = ARCHITECTURE_FLOW.split('\n').filter(l => /^\s*classDef\s+/.test(l))
    expect(classDefLines.length).toBeGreaterThan(0)
    for (const line of classDefLines) {
      expect(line).not.toMatch(/var\(--/)
    }
  })
})
