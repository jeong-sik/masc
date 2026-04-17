import { describe, expect, it } from 'vitest'
import type { MemoryKindUsageEntry } from '../api/keeper'
import { filterMemoryKindUsage } from './keeper-memory-tier-panel'

const sample: MemoryKindUsageEntry[] = [
  { kind: 'tool_result', used: 10, cap: 10, priority: 1 },
  { kind: 'tool_call', used: 5, cap: 10, priority: 1 },
  { kind: 'text', used: 20, cap: 20, priority: 2 },
  { kind: 'board_post', used: 3, cap: 8, priority: 3 },
  { kind: 'uncapped', used: 99, cap: 0, priority: 4 },
]

describe('filterMemoryKindUsage', () => {
  it('returns the input reference when query empty and filter=all', () => {
    expect(filterMemoryKindUsage(sample, '')).toBe(sample)
    expect(filterMemoryKindUsage(sample, '   ')).toBe(sample)
  })

  it('filters by case-insensitive substring on kind', () => {
    const out = filterMemoryKindUsage(sample, 'TOOL')
    expect(out.map(r => r.kind)).toEqual(['tool_result', 'tool_call'])
  })

  it('trims the query before matching', () => {
    const out = filterMemoryKindUsage(sample, '  board  ')
    expect(out.map(r => r.kind)).toEqual(['board_post'])
  })

  it('returns an empty array when no kind matches', () => {
    expect(filterMemoryKindUsage(sample, 'nonexistent_kind')).toEqual([])
  })

  it('keeps only saturated rows when filter=saturated', () => {
    const out = filterMemoryKindUsage(sample, '', 'saturated')
    expect(out.map(r => r.kind)).toEqual(['tool_result', 'text'])
  })

  it('treats cap=0 as never saturated (no div-by-zero framing)', () => {
    const out = filterMemoryKindUsage(sample, '', 'saturated')
    expect(out.some(r => r.kind === 'uncapped')).toBe(false)
  })

  it('combines saturated filter with substring query', () => {
    const out = filterMemoryKindUsage(sample, 'tool', 'saturated')
    expect(out.map(r => r.kind)).toEqual(['tool_result'])
  })

  it('saturated filter with empty query still narrows rows', () => {
    const out = filterMemoryKindUsage(sample, '   ', 'saturated')
    expect(out).toHaveLength(2)
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.slice()
    filterMemoryKindUsage(sample, 'tool', 'saturated')
    expect(sample).toEqual(snapshot)
  })

  it('returns an empty array when saturated filter matches nothing', () => {
    const noneSaturated: MemoryKindUsageEntry[] = [
      { kind: 'a', used: 1, cap: 10, priority: 1 },
      { kind: 'b', used: 0, cap: 5, priority: 2 },
    ]
    expect(filterMemoryKindUsage(noneSaturated, '', 'saturated')).toEqual([])
  })
})
