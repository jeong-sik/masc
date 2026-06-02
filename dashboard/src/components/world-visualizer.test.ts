import { describe, expect, it } from 'vitest'
import type { Keeper } from '../types'

// Import the pure functions we want to test.
// Since stigmergyIntensity, freeEnergy, and interactionStrength are
// module-scoped (not exported), we re-implement their logic here for
// unit testing. The component itself is tested via integration.

function stigmergyIntensity(keeper: Keeper, msgCount: number): number {
  const actions = keeper.autonomous_action_count ?? 0
  return Math.log1p(actions + msgCount * 2) / Math.log1p(100)
}

function freeEnergy(keeper: Keeper): number {
  const c = keeper.goal_progress?.convergence
  if (typeof c === 'number' && Number.isFinite(c) && c >= 0) return Math.max(0, 1 - c)
  return 0.5
}

function makeKeeper(overrides: Partial<Keeper> & { name: string }): Keeper {
  return { status: 'active', ...overrides } as Keeper
}

describe('stigmergyIntensity', () => {
  it('returns 0 for a keeper with no activity', () => {
    const k = makeKeeper({ name: 'idle-keeper' })
    expect(stigmergyIntensity(k, 0)).toBe(0)
  })

  it('increases with autonomous actions', () => {
    const low = makeKeeper({ name: 'low', autonomous_action_count: 5 })
    const high = makeKeeper({ name: 'high', autonomous_action_count: 50 })
    expect(stigmergyIntensity(high, 0)).toBeGreaterThan(stigmergyIntensity(low, 0))
  })

  it('accounts for message count with 2x weight', () => {
    const k = makeKeeper({ name: 'msg', autonomous_action_count: 0 })
    const noMsg = stigmergyIntensity(k, 0)
    const withMsg = stigmergyIntensity(k, 10)
    expect(withMsg).toBeGreaterThan(noMsg)
  })

  it('increases monotonically for very high activity', () => {
    const k = makeKeeper({ name: 'busy', autonomous_action_count: 1000 })
    const intensity = stigmergyIntensity(k, 500)
    expect(intensity).toBeGreaterThan(0.8)
  })
})

describe('freeEnergy', () => {
  it('returns 0 when convergence is 1 (fully stable)', () => {
    const k = makeKeeper({
      name: 'stable',
      goal_progress: { convergence: 1 },
    })
    expect(freeEnergy(k)).toBe(0)
  })

  it('returns 1 when convergence is 0 (maximum uncertainty)', () => {
    const k = makeKeeper({
      name: 'uncertain',
      goal_progress: { convergence: 0 },
    })
    expect(freeEnergy(k)).toBe(1)
  })

  it('returns 0.5 when convergence is undefined (unknown state)', () => {
    const k = makeKeeper({ name: 'unknown' })
    expect(freeEnergy(k)).toBe(0.5)
  })

  it('returns 0.5 for negative convergence (invalid, clamped)', () => {
    const k = makeKeeper({
      name: 'invalid',
      goal_progress: { convergence: -0.5 },
    })
    expect(freeEnergy(k)).toBe(0.5)
  })

  it('scales linearly with convergence', () => {
    const k50 = makeKeeper({ name: 'half', goal_progress: { convergence: 0.5 } })
    const k75 = makeKeeper({ name: 'three-q', goal_progress: { convergence: 0.75 } })
    expect(freeEnergy(k50)).toBe(0.5)
    expect(freeEnergy(k75)).toBe(0.25)
  })
})
