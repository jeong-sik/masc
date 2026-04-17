import { describe, expect, it } from 'vitest'
import { filterToolStats } from './keeper-tool-telemetry'
import type { ToolStat } from '../api/dashboard'

function mkStat(name: string, overrides: Partial<ToolStat> = {}): ToolStat {
  return {
    name,
    call_count: 1,
    success_count: 1,
    failure_count: 0,
    avg_duration_ms: 10,
    p95_duration_ms: 20,
    max_duration_ms: 30,
    total_cost_usd: 0,
    last_used_at: '2026-04-17T00:00:00Z',
    ...overrides,
  }
}

const sample: readonly ToolStat[] = [
  mkStat('masc_status'),
  mkStat('masc_dashboard'),
  mkStat('keeper_stay_silent'),
  mkStat('fs_read'),
  mkStat('browser_navigate'),
  mkStat('playwright_click'),
  mkStat('write_file'),
]

describe('filterToolStats', () => {
  it('returns the input reference when query is empty', () => {
    expect(filterToolStats(sample, '')).toBe(sample)
    expect(filterToolStats(sample, '   ')).toBe(sample)
  })

  it('matches case-insensitive substring on name', () => {
    const out = filterToolStats(sample, 'MASC')
    expect(out.map(s => s.name)).toEqual(['masc_status', 'masc_dashboard'])
  })

  it('matches exact name segments', () => {
    const out = filterToolStats(sample, 'stay_silent')
    expect(out.map(s => s.name)).toEqual(['keeper_stay_silent'])
  })

  it('matches via substring on name (read)', () => {
    const out = filterToolStats(sample, 'read')
    // fs_read matches by name
    expect(out.map(s => s.name)).toEqual(['fs_read'])
  })

  it('matches via derived category label (browser)', () => {
    const out = filterToolStats(sample, 'browser')
    const names = out.map(s => s.name)
    // browser_navigate matches by name; playwright_click matches via category=browser label
    expect(names).toContain('browser_navigate')
    expect(names).toContain('playwright_click')
  })

  it('matches via derived category label (status)', () => {
    // 'masc_status' matches by name-substring AND category='status'.
    // keeper_stay_silent has no 'status' in its name; category defaults to 'tool'.
    // So only masc_status should match.
    const out = filterToolStats(sample, 'status')
    expect(out.map(s => s.name)).toEqual(['masc_status'])
  })

  it('trims surrounding whitespace before matching', () => {
    const out = filterToolStats(sample, '  masc_dashboard  ')
    expect(out.map(s => s.name)).toEqual(['masc_dashboard'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterToolStats(sample, 'no-such-token-xyz')).toEqual([])
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.slice()
    filterToolStats(sample, 'masc')
    expect(sample).toEqual(snapshot)
  })

  it('returns a fresh array (not the input) when filtering narrows rows', () => {
    const out = filterToolStats(sample, 'masc')
    expect(out).not.toBe(sample)
    expect(out.length).toBeLessThan(sample.length)
  })

  it('tolerates empty rows input', () => {
    const empty: readonly ToolStat[] = []
    expect(filterToolStats(empty, 'masc')).toEqual([])
    expect(filterToolStats(empty, '')).toBe(empty)
  })
})
