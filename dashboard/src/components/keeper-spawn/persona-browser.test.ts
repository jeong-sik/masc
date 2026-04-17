import { describe, expect, it } from 'vitest'
import { filterPersonas } from './persona-browser'
import type { PersonaSummary } from './keeper-spawn-state'

const sample: PersonaSummary[] = [
  { name: 'analyst',  displayName: 'Analyst',  role: 'analysis',  mode: 'observer', description: 'inspects harness metrics' },
  { name: 'executor', displayName: 'Executor', role: 'action',    mode: 'writer',   description: 'runs code edits' },
  { name: 'scholar',  displayName: 'Scholar',  role: 'research',  mode: 'observer', description: 'reads papers and memory' },
  { name: 'verifier', displayName: 'Verifier', role: 'guard',     mode: 'checker',  description: 'validates outputs' },
  { name: 'uranium666', role: 'lab', description: 'experimental sandbox persona' },
  { name: 'bare-persona' },
]

describe('filterPersonas', () => {
  it('returns the input reference when query is empty', () => {
    expect(filterPersonas(sample, '')).toBe(sample)
    expect(filterPersonas(sample, '   ')).toBe(sample)
  })

  it('matches case-insensitive substring on name', () => {
    const out = filterPersonas(sample, 'URANIUM')
    expect(out.map(p => p.name)).toEqual(['uranium666'])
  })

  it('matches on displayName', () => {
    const out = filterPersonas(sample, 'Scholar')
    expect(out.map(p => p.name)).toEqual(['scholar'])
  })

  it('matches on role', () => {
    const out = filterPersonas(sample, 'research')
    expect(out.map(p => p.name)).toEqual(['scholar'])
  })

  it('matches on mode', () => {
    const out = filterPersonas(sample, 'observer')
    expect(out.map(p => p.name)).toEqual(['analyst', 'scholar'])
  })

  it('matches on description', () => {
    const out = filterPersonas(sample, 'papers')
    expect(out.map(p => p.name)).toEqual(['scholar'])
  })

  it('trims surrounding whitespace before matching', () => {
    const out = filterPersonas(sample, '  action  ')
    expect(out.map(p => p.name)).toEqual(['executor'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterPersonas(sample, 'no-such-token-xyz')).toEqual([])
  })

  it('tolerates personas missing optional fields', () => {
    const out = filterPersonas(sample, 'bare')
    expect(out.map(p => p.name)).toEqual(['bare-persona'])
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.slice()
    filterPersonas(sample, 'analyst')
    expect(sample).toEqual(snapshot)
  })

  it('returns a fresh array (not the input) when filtering narrows rows', () => {
    const out = filterPersonas(sample, 'observer')
    expect(out).not.toBe(sample)
    expect(out.length).toBeLessThan(sample.length)
  })
})
