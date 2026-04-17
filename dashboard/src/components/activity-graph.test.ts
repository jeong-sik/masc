import { describe, expect, it } from 'vitest'

import { filterActionGroups, visibleNamespaceLabel } from './activity-graph'
import type { ActionTimelineGroup } from '../types'

describe('visibleNamespaceLabel', () => {
  it('hides empty and default namespaces', () => {
    expect(visibleNamespaceLabel(null)).toBeNull()
    expect(visibleNamespaceLabel(undefined)).toBeNull()
    expect(visibleNamespaceLabel('')).toBeNull()
    expect(visibleNamespaceLabel('   ')).toBeNull()
    expect(visibleNamespaceLabel('default')).toBeNull()
    expect(visibleNamespaceLabel(' default ')).toBeNull()
  })

  it('returns trimmed non-default namespaces', () => {
    expect(visibleNamespaceLabel('project-a')).toBe('project-a')
    expect(visibleNamespaceLabel(' project-b ')).toBe('project-b')
  })
})

function makeGroup(overrides: Partial<ActionTimelineGroup>): ActionTimelineGroup {
  return {
    id: 'g1',
    category: 'task',
    actor: 'dreamer',
    subjectId: null,
    title: 'claim task PK-123',
    summary: 'dreamer claimed task PK-123',
    latestTs: '2026-04-17T00:00:00Z',
    latestTsMs: 0,
    rawCount: 1,
    kinds: ['task.claim'],
    rawEvents: [],
    ...overrides,
  }
}

describe('filterActionGroups', () => {
  const groups: readonly ActionTimelineGroup[] = [
    makeGroup({ id: 'a', title: 'claim task PK-123', actor: 'dreamer', subjectId: 'PK-123' }),
    makeGroup({ id: 'b', title: 'session start', actor: 'keeper-1', subjectId: null, summary: 'keeper-1 joined room alpha' }),
    makeGroup({ id: 'c', title: 'broadcast status', actor: 'Watcher', subjectId: 'room-beta', summary: 'Watcher posted status update' }),
    makeGroup({ id: 'd', title: 'governance vote', actor: 'judge', subjectId: null, summary: '' }),
  ]

  it('returns input reference when query is empty', () => {
    expect(filterActionGroups(groups, '')).toBe(groups)
  })

  it('returns input reference when query is whitespace only', () => {
    expect(filterActionGroups(groups, '   ')).toBe(groups)
  })

  it('trims query before matching', () => {
    const result = filterActionGroups(groups, '  claim  ')
    expect(result).toHaveLength(1)
    expect(result[0]!.id).toBe('a')
  })

  it('matches title case-insensitively', () => {
    const result = filterActionGroups(groups, 'CLAIM')
    expect(result.map(g => g.id)).toEqual(['a'])
  })

  it('matches actor substring', () => {
    const result = filterActionGroups(groups, 'watch')
    expect(result.map(g => g.id)).toEqual(['c'])
  })

  it('matches subjectId substring', () => {
    const result = filterActionGroups(groups, 'room-beta')
    expect(result.map(g => g.id)).toEqual(['c'])
  })

  it('matches summary substring', () => {
    const result = filterActionGroups(groups, 'joined room')
    expect(result.map(g => g.id)).toEqual(['b'])
  })

  it('returns empty array when no group matches', () => {
    expect(filterActionGroups(groups, 'nonexistent-needle')).toEqual([])
  })

  it('handles null subjectId without crashing', () => {
    const result = filterActionGroups(groups, 'judge')
    expect(result.map(g => g.id)).toEqual(['d'])
  })

  it('does not mutate the input array', () => {
    const snapshot = groups.slice()
    filterActionGroups(groups, 'claim')
    expect(groups).toEqual(snapshot)
  })

  it('returns empty result on empty input', () => {
    expect(filterActionGroups([], 'claim')).toEqual([])
  })
})
