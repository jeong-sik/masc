import { describe, expect, it } from 'vitest'
import type { Agent, Keeper } from '../types'
import type { DashboardMissionKeeperBrief } from '../types/dashboard-mission'
import { countAgentsByStatus, scopeAgentsByKeeperFilter } from './agent-roster'

const AGENTS: Agent[] = [
  { name: 'plain-agent', status: 'active', current_task: null },
  { name: 'keeper-alpha-agent', status: 'busy', current_task: null },
  { name: 'keeper-beta-agent', status: 'offline', current_task: null },
  { name: 'missing-status-agent', current_task: null },
]

const KEEPERS: Keeper[] = [
  { name: 'keeper-alpha', agent_name: 'keeper-alpha-agent', status: 'active' },
]

const KEEPER_BRIEFS: DashboardMissionKeeperBrief[] = [
  { name: 'keeper-beta', agent_name: 'keeper-beta-agent' },
]

describe('scopeAgentsByKeeperFilter', () => {
  it('keeps the all tab showing every agent entry', () => {
    const scoped = scopeAgentsByKeeperFilter(
      AGENTS,
      KEEPERS,
      KEEPER_BRIEFS,
      'all',
    )

    expect(scoped.map(agent => agent.name)).toEqual([
      'plain-agent',
      'keeper-alpha-agent',
      'keeper-beta-agent',
      'missing-status-agent',
    ])
  })

  it('keeps the general-agent tab scoped to non-keeper entries', () => {
    const scoped = scopeAgentsByKeeperFilter(
      AGENTS,
      KEEPERS,
      KEEPER_BRIEFS,
      'agent-only',
    )

    expect(scoped.map(agent => agent.name)).toEqual([
      'plain-agent',
      'missing-status-agent',
    ])
  })

  it('keeps the keeper tab scoped to keeper-backed runtimes', () => {
    const scoped = scopeAgentsByKeeperFilter(
      AGENTS,
      KEEPERS,
      KEEPER_BRIEFS,
      'keeper-only',
    )

    expect(scoped.map(agent => agent.name)).toEqual([
      'keeper-alpha-agent',
      'keeper-beta-agent',
    ])
  })
})

describe('countAgentsByStatus', () => {
  it('counts status chips from the already-scoped list', () => {
    const scoped = scopeAgentsByKeeperFilter(
      AGENTS,
      KEEPERS,
      KEEPER_BRIEFS,
      'agent-only',
    )

    expect(countAgentsByStatus(scoped)).toEqual({
      all: 2,
      active: 1,
      idle: 1,
      offline: 0,
    })
  })
})
