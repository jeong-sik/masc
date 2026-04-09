import { describe, expect, it } from 'vitest'
import type { Agent, Keeper } from '../types'
import type { DashboardMissionKeeperBrief } from '../types/dashboard-mission'
import {
  buildAgentRoster,
  countAgentsByStatus,
  countRuntimeKinds,
  scopeAgentsByKeeperFilter,
} from './agent-roster'

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
  { name: 'keeper-beta', agent_name: 'keeper-beta-agent', current_work: 'watching room health' },
]

describe('scopeAgentsByKeeperFilter', () => {
  it('adds keeper-backed runtimes into the roster even when the agent feed is empty', () => {
    const built = buildAgentRoster([], KEEPERS, KEEPER_BRIEFS)

    expect(built.map(agent => agent.name)).toEqual([
      'keeper-alpha-agent',
      'keeper-beta-agent',
    ])
    expect(built.map(agent => agent.current_task)).toEqual([
      null,
      'watching room health',
    ])
  })

  it('keeps the all tab showing every agent entry', () => {
    const scoped = scopeAgentsByKeeperFilter(
      buildAgentRoster(AGENTS, KEEPERS, KEEPER_BRIEFS),
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
      buildAgentRoster(AGENTS, KEEPERS, KEEPER_BRIEFS),
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
      buildAgentRoster(AGENTS, KEEPERS, KEEPER_BRIEFS),
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
      buildAgentRoster(AGENTS, KEEPERS, KEEPER_BRIEFS),
      KEEPERS,
      KEEPER_BRIEFS,
      'agent-only',
    )

    expect(countAgentsByStatus(scoped, KEEPERS)).toEqual({
      all: 2,
      active: 1,
      attention: 1,
      paused: 0,
      offline: 0,
    })
  })
})

describe('countRuntimeKinds', () => {
  it('splits live runtimes into agent-only and keeper buckets without double-counting', () => {
    expect(countRuntimeKinds(AGENTS, KEEPERS, KEEPER_BRIEFS)).toEqual({
      agents: 2,
      keepers: 2,
      totalRuntimes: 4,
    })
  })
})
