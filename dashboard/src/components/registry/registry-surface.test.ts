import { describe, expect, it } from 'vitest'

import type { Keeper } from '../../types'
import { buildCompositeByKeeperKey } from '../../composite-signals'
import { groupRegistryKeepers, keeperGroup } from './registry-surface'

function keeper(overrides: Partial<Keeper> = {}): Keeper {
  return { name: 'keeper', status: 'idle', ...overrides }
}

describe('keeperGroup', () => {
  it('projects the canonical operational-state variants without a parallel lifecycle heuristic', () => {
    expect(keeperGroup(keeper(), null)).toBe('running')
    expect(keeperGroup(keeper({ paused: true }), null)).toBe('paused')
    expect(keeperGroup(keeper({ status: 'unbooted' }), null)).toBe('offline')
    expect(keeperGroup(keeper({ runtime_blocker_class: 'runtime_exhausted' }), null)).toBe('stuck')
  })
})

describe('groupRegistryKeepers', () => {
  it('places every keeper in exactly one group', () => {
    const roster = [
      keeper({ name: 'running' }),
      keeper({ name: 'paused', paused: true }),
      keeper({ name: 'offline', status: 'unbooted' }),
      keeper({ name: 'stuck', runtime_blocker_class: 'runtime_exhausted' }),
    ]
    const grouped = groupRegistryKeepers(roster, buildCompositeByKeeperKey(null))
    const names = Object.values(grouped).flatMap(rows => rows.map(row => row.keeper.name))

    expect(names.sort()).toEqual(roster.map(row => row.name).sort())
    expect(new Set(names).size).toBe(roster.length)
  })
})
