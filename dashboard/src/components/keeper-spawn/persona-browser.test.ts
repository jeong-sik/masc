import { describe, expect, it, vi } from 'vitest'

vi.mock('../../store', () => ({
  shellAuthSummary: { value: null },
}))

vi.mock('../../lib/dashboard-auth-access', () => ({
  dashboardAuthAccess: () => ({
    allowed: true,
    required_role: 'worker',
    effective_role: 'worker',
    reason: null,
  }),
}))

import { filterPersonas } from './persona-browser'
import type { PersonaSummary } from './keeper-spawn-state'

function persona(
  persona_name: string,
  display_name: string,
  role: string | null,
  trait: string | null,
): PersonaSummary {
  return {
    persona_name,
    display_name,
    role,
    trait,
    profile_path: `/personas/${persona_name}/profile.json`,
    has_keeper_defaults: false,
  }
}

const sample: PersonaSummary[] = [
  persona('analyst', 'Analyst', 'analysis', 'inspects harness metrics'),
  persona('executor', 'Executor', 'action', 'runs code edits'),
  persona('scholar', 'Scholar', 'research', 'reads papers and memory'),
  persona('verifier', 'Verifier', 'guard', 'validates outputs'),
  persona('uranium666', 'Uranium 666', 'lab', 'experimental sandbox persona'),
  persona('bare-persona', 'Bare Persona', null, null),
]

describe('filterPersonas', () => {
  it('returns the input reference when query is empty', () => {
    expect(filterPersonas(sample, '')).toBe(sample)
    expect(filterPersonas(sample, '   ')).toBe(sample)
  })

  it('matches case-insensitive substring on name', () => {
    const out = filterPersonas(sample, 'URANIUM')
    expect(out.map(p => p.persona_name)).toEqual(['uranium666'])
  })

  it('matches on display_name', () => {
    const out = filterPersonas(sample, 'Scholar')
    expect(out.map(p => p.persona_name)).toEqual(['scholar'])
  })

  it('matches on role', () => {
    const out = filterPersonas(sample, 'research')
    expect(out.map(p => p.persona_name)).toEqual(['scholar'])
  })

  it('matches on trait', () => {
    const out = filterPersonas(sample, 'papers')
    expect(out.map(p => p.persona_name)).toEqual(['scholar'])
  })

  it('trims surrounding whitespace before matching', () => {
    const out = filterPersonas(sample, '  action  ')
    expect(out.map(p => p.persona_name)).toEqual(['executor'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterPersonas(sample, 'no-such-token-xyz')).toEqual([])
  })

  it('matches entries whose nullable fields are absent', () => {
    const out = filterPersonas(sample, 'bare')
    expect(out.map(p => p.persona_name)).toEqual(['bare-persona'])
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.slice()
    filterPersonas(sample, 'analyst')
    expect(sample).toEqual(snapshot)
  })

  it('returns a fresh array (not the input) when filtering narrows rows', () => {
    const out = filterPersonas(sample, 'analysis')
    expect(out).not.toBe(sample)
    expect(out.length).toBeLessThan(sample.length)
  })
})
