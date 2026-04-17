import { describe, it, expect } from 'vitest'
import {
  normalizeKeeperName,
  matchesKeeper,
  filterEpisodes,
} from './agent-detail-memory'
import type { MemorySubsystemsEpisode } from '../api/dashboard'

function makeEpisode(
  overrides: Partial<MemorySubsystemsEpisode> = {},
): MemorySubsystemsEpisode {
  return {
    id: 'ep-1',
    timestamp: 0,
    participants: [],
    event_type: 'task_complete',
    summary: 'summary text',
    outcome: 'success',
    learnings: [],
    context: {},
    ...overrides,
  }
}

describe('normalizeKeeperName', () => {
  it('removes keeper- prefix', () => {
    expect(normalizeKeeperName('keeper-janitor')).toBe('janitor')
  })

  it('removes -agent suffix', () => {
    expect(normalizeKeeperName('sentinel-agent')).toBe('sentinel')
  })

  it('removes both keeper- prefix and -agent suffix', () => {
    expect(normalizeKeeperName('keeper-dreamer-agent')).toBe('dreamer')
  })

  it('leaves plain name unchanged', () => {
    expect(normalizeKeeperName('janitor')).toBe('janitor')
  })

  it('handles empty string', () => {
    expect(normalizeKeeperName('')).toBe('')
  })

  it('does not remove inner keeper or agent', () => {
    expect(normalizeKeeperName('my-keeper-bot')).toBe('my-keeper-bot')
    expect(normalizeKeeperName('agent-007')).toBe('agent-007')
  })

  it('handles name that is just the prefix', () => {
    expect(normalizeKeeperName('keeper-')).toBe('')
  })

  it('handles name that is just the suffix', () => {
    // '-agent' → replace /^keeper-/ → '-agent' → replace /-agent$/ → ''
    expect(normalizeKeeperName('-agent')).toBe('')
  })
})

describe('matchesKeeper', () => {
  it('matches identical names', () => {
    expect(matchesKeeper('janitor', 'janitor')).toBe(true)
  })

  it('matches with different prefix/suffix patterns', () => {
    expect(matchesKeeper('keeper-janitor', 'janitor')).toBe(true)
    expect(matchesKeeper('janitor', 'keeper-janitor')).toBe(true)
    expect(matchesKeeper('keeper-janitor', 'janitor-agent')).toBe(true)
    expect(matchesKeeper('keeper-dreamer-agent', 'dreamer')).toBe(true)
  })

  it('does not match different names', () => {
    expect(matchesKeeper('janitor', 'sentinel')).toBe(false)
    expect(matchesKeeper('keeper-janitor', 'keeper-sentinel')).toBe(false)
  })

  it('handles empty strings', () => {
    expect(matchesKeeper('', '')).toBe(true)
    expect(matchesKeeper('keeper-', '')).toBe(true)
    expect(matchesKeeper('', 'keeper-')).toBe(true)
  })

  it('is case-sensitive', () => {
    expect(matchesKeeper('Janitor', 'janitor')).toBe(false)
  })
})

describe('filterEpisodes', () => {
  const episodes: readonly MemorySubsystemsEpisode[] = [
    makeEpisode({ id: 'a', summary: 'fixed flaky test on dashboard', event_type: 'task_complete', learnings: ['prefer deterministic mocks'] }),
    makeEpisode({ id: 'b', summary: 'resolved OAS cascade blocker', event_type: 'decision', learnings: [] }),
    makeEpisode({ id: 'c', summary: 'idle tick', event_type: 'heartbeat', learnings: ['no-op when queue empty'] }),
  ]

  it('returns input reference unchanged on empty query', () => {
    expect(filterEpisodes(episodes, '')).toBe(episodes)
  })

  it('returns input reference unchanged on whitespace query', () => {
    expect(filterEpisodes(episodes, '   ')).toBe(episodes)
  })

  it('is case-insensitive', () => {
    const hits = filterEpisodes(episodes, 'OAS')
    expect(hits.map(e => e.id)).toEqual(['b'])
    const hitsLower = filterEpisodes(episodes, 'oas')
    expect(hitsLower.map(e => e.id)).toEqual(['b'])
  })

  it('trims leading/trailing whitespace', () => {
    const hits = filterEpisodes(episodes, '  heartbeat  ')
    expect(hits.map(e => e.id)).toEqual(['c'])
  })

  it('matches across summary, event_type, and learnings', () => {
    // summary hit
    expect(filterEpisodes(episodes, 'dashboard').map(e => e.id)).toEqual(['a'])
    // event_type hit
    expect(filterEpisodes(episodes, 'decision').map(e => e.id)).toEqual(['b'])
    // learnings hit
    expect(filterEpisodes(episodes, 'deterministic').map(e => e.id)).toEqual(['a'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterEpisodes(episodes, 'nonexistent-token')).toEqual([])
  })

  it('does not mutate the input', () => {
    const snapshot = episodes.map(e => ({ ...e }))
    filterEpisodes(episodes, 'oas')
    expect(episodes).toEqual(snapshot)
  })
})
