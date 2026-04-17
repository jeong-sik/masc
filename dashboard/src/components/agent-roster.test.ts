import { describe, it, expect } from 'vitest'
import {
  runtimeBadgeClass,
  stageBadgeClass,
  compactModelLabel,
  uniqueToolNames,
  keeperRuntimeName,
  mergeRosterAgent,
  filterAgentRoster,
} from './agent-roster'
import type { Agent } from '../types'

function makeAgent(overrides: Partial<Agent> = {}): Agent {
  return {
    name: 'agent-x',
    status: 'active',
    current_task: null,
    ...overrides,
  }
}

describe('runtimeBadgeClass', () => {
  it('returns green classes for active', () => {
    expect(runtimeBadgeClass('active')).toContain('text-[var(--ok)]')
  })

  it('returns yellow classes for attention', () => {
    expect(runtimeBadgeClass('attention')).toContain('text-[var(--warn)]')
  })

  it('returns purple classes for paused', () => {
    expect(runtimeBadgeClass('paused')).toContain('#a78bfa')
  })

  it('returns dim classes for unknown band', () => {
    expect(runtimeBadgeClass('offline')).toContain('text-[var(--text-dim)]')
  })
})

describe('stageBadgeClass', () => {
  it('returns accent classes for tool_use', () => {
    expect(stageBadgeClass('tool_use')).toContain('text-[var(--accent)]')
  })

  it('returns ok classes for thinking', () => {
    expect(stageBadgeClass('thinking')).toContain('text-[var(--ok)]')
  })

  it('returns ok classes for scheduled_autonomous', () => {
    expect(stageBadgeClass('scheduled_autonomous')).toContain('text-[var(--ok)]')
  })

  it('returns purple classes for handoff', () => {
    expect(stageBadgeClass('handoff')).toContain('#c4b5fd')
  })

  it('returns purple classes for compacting', () => {
    expect(stageBadgeClass('compacting')).toContain('#c4b5fd')
  })

  it('returns bad classes for failing', () => {
    expect(stageBadgeClass('failing')).toContain('text-[var(--bad)]')
  })

  it('returns bad classes for crashed', () => {
    expect(stageBadgeClass('crashed')).toContain('text-[var(--bad)]')
  })

  it('returns purple classes for paused stage', () => {
    expect(stageBadgeClass('paused')).toContain('#a78bfa')
  })

  it('returns muted classes for unknown stage', () => {
    expect(stageBadgeClass('idle')).toContain('text-[var(--text-muted)]')
  })
})

describe('compactModelLabel', () => {
  it('returns null for null', () => {
    expect(compactModelLabel(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(compactModelLabel(undefined)).toBeNull()
  })

  it('returns null for empty string', () => {
    expect(compactModelLabel('')).toBeNull()
  })

  it('returns null for whitespace-only string', () => {
    expect(compactModelLabel('   ')).toBeNull()
  })

  it('returns last segment for colon-separated string', () => {
    expect(compactModelLabel('provider:model-name')).toBe('model-name')
  })

  it('returns value as-is for no colon', () => {
    expect(compactModelLabel('claude-sonnet')).toBe('claude-sonnet')
  })

  it('returns last segment for multi-segment', () => {
    expect(compactModelLabel('a:b:c')).toBe('c')
  })

  it('handles spaces around segments', () => {
    expect(compactModelLabel('provider : model-name')).toBe('model-name')
  })
})

describe('uniqueToolNames', () => {
  it('returns empty for no groups', () => {
    expect(uniqueToolNames()).toEqual([])
  })

  it('returns empty for null/undefined groups', () => {
    expect(uniqueToolNames(null, undefined)).toEqual([])
  })

  it('collects unique names from single group', () => {
    expect(uniqueToolNames(['a', 'b', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('deduplicates across groups', () => {
    expect(uniqueToolNames(['a', 'b'], ['b', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('deduplicates within a group', () => {
    expect(uniqueToolNames(['a', 'a', 'b'])).toEqual(['a', 'b'])
  })

  it('trims whitespace', () => {
    expect(uniqueToolNames([' a ', 'b'])).toEqual(['a', 'b'])
  })

  it('skips empty strings', () => {
    expect(uniqueToolNames(['', 'a', ''])).toEqual(['a'])
  })

  it('preserves first occurrence order', () => {
    expect(uniqueToolNames(['z', 'a'], ['a', 'z', 'b'])).toEqual(['z', 'a', 'b'])
  })
})

describe('keeperRuntimeName', () => {
  it('returns agent_name when present', () => {
    expect(keeperRuntimeName({ name: 'keeper1', agent_name: 'claude-agent' })).toBe('claude-agent')
  })

  it('falls back to name when agent_name is empty', () => {
    expect(keeperRuntimeName({ name: 'keeper1', agent_name: '' })).toBe('keeper1')
  })

  it('falls back to name when agent_name is whitespace', () => {
    expect(keeperRuntimeName({ name: 'keeper1', agent_name: '  ' })).toBe('keeper1')
  })

  it('falls back to name when agent_name is undefined', () => {
    expect(keeperRuntimeName({ name: 'keeper1' })).toBe('keeper1')
  })
})

describe('mergeRosterAgent', () => {
  const baseAgent: Agent = {
    name: 'test-agent',
    status: 'active',
    current_task: null,
  }
  const nextAgent: Agent = {
    name: 'test-agent',
    status: 'idle',
    current_task: 'task-1',
    emoji: '🤖',
    model: 'claude-sonnet',
  }

  it('returns next when existing is undefined', () => {
    expect(mergeRosterAgent(undefined, nextAgent)).toEqual(nextAgent)
  })

  it('prefers existing status over next', () => {
    const result = mergeRosterAgent(baseAgent, nextAgent)
    expect(result.status).toBe('active')
  })

  it('fills in missing fields from next', () => {
    const result = mergeRosterAgent(baseAgent, nextAgent)
    // null ?? 'task-1' = 'task-1' — ?? replaces null/undefined
    expect(result.current_task).toBe('task-1')
    expect(result.emoji).toBe('🤖')
    expect(result.model).toBe('claude-sonnet')
  })

  it('uses existing capabilities when non-empty', () => {
    const existing: Agent = {
      ...baseAgent,
      capabilities: ['tool-a'],
    }
    const next: Agent = { ...nextAgent, capabilities: ['tool-b'] }
    const result = mergeRosterAgent(existing, next)
    expect(result.capabilities).toEqual(['tool-a'])
  })

  it('uses next capabilities when existing is empty', () => {
    const existing: Agent = {
      ...baseAgent,
      capabilities: [],
    }
    const next: Agent = { ...nextAgent, capabilities: ['tool-b'] }
    const result = mergeRosterAgent(existing, next)
    expect(result.capabilities).toEqual(['tool-b'])
  })
})

describe('filterAgentRoster', () => {
  const rows: Agent[] = [
    makeAgent({ name: 'keeper-alpha', model: 'gpt-5.4', current_task: 'review PR #42' }),
    makeAgent({ name: 'keeper-beta', model: 'claude-sonnet-4-6', current_task: null, koreanName: '베타' }),
    makeAgent({ name: 'watcher-gamma', current_task: 'compact memory' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterAgentRoster(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterAgentRoster(rows, '   ')).toBe(rows)
  })

  it('trims query before matching', () => {
    expect(filterAgentRoster(rows, '  alpha  ')).toHaveLength(1)
  })

  it('matches by name substring (case-insensitive)', () => {
    const result = filterAgentRoster(rows, 'KEEPER')
    expect(result).toHaveLength(2)
    expect(result.map(r => r.name)).toEqual(['keeper-alpha', 'keeper-beta'])
  })

  it('matches by model substring', () => {
    const result = filterAgentRoster(rows, 'claude')
    expect(result.map(r => r.name)).toEqual(['keeper-beta'])
  })

  it('matches by current_task substring', () => {
    const result = filterAgentRoster(rows, 'compact')
    expect(result.map(r => r.name)).toEqual(['watcher-gamma'])
  })

  it('matches by koreanName substring', () => {
    const result = filterAgentRoster(rows, '베타')
    expect(result.map(r => r.name)).toEqual(['keeper-beta'])
  })

  it('returns empty when no field matches', () => {
    expect(filterAgentRoster(rows, 'nonexistent-token')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterAgentRoster(rows, 'alpha')
    expect(rows).toEqual(copy)
  })

  it('handles rows with null / missing optional fields safely', () => {
    const input: Agent[] = [makeAgent({ name: 'orphan' })]
    expect(filterAgentRoster(input, 'orphan')).toHaveLength(1)
    expect(filterAgentRoster(input, 'anything-else')).toHaveLength(0)
  })

  it('handles empty rows array', () => {
    const empty: Agent[] = []
    expect(filterAgentRoster(empty, 'foo')).toHaveLength(0)
    expect(filterAgentRoster(empty, '')).toBe(empty)
  })
})
