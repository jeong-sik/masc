import { describe, expect, it } from 'vitest'
import { readKeeperCostCoverage, keeperCostSummary, type KeeperCostCoverage } from './keeper-cost-coverage'

const empty: KeeperCostCoverage = { known_cost_usd: 0, priced_readings: 0,
  unpriced_readings: 0, unresolved_readings: 0, unobserved_attempts: 0, history: 'complete' }

describe('Keeper lifetime pricing evidence', () => {
  it('retains unknown numeric history including zero', () => {
    for (const amount of [0, 12.5]) {
      expect(readKeeperCostCoverage(amount)).toEqual({ ...empty, known_cost_usd: amount, history: 'unobserved' })
      expect(keeperCostSummary(readKeeperCostCoverage(amount))).toContain('history unobserved')
    }
  })
  it('distinguishes complete empty, real zero and absent pricing', () => {
    expect(keeperCostSummary(readKeeperCostCoverage(empty))).toBe('no cost observations')
    expect(keeperCostSummary(readKeeperCostCoverage({ ...empty, priced_readings: 1 }))).toBe('$0.0000')
    expect(keeperCostSummary(readKeeperCostCoverage({ ...empty, unpriced_readings: 1 }))).toContain('not priced by provider')
  })
  it('retains the known part and missing prices together', () => {
    const mixed = { ...empty, known_cost_usd: 2, priced_readings: 1, unpriced_readings: 3 }
    expect(readKeeperCostCoverage(mixed)).toEqual(mixed)
    expect(keeperCostSummary(mixed)).toBe('$2.0000 known · 1 priced / 3 unpriced readings')
  })
  it('keeps unresolved usage and empty attempts separate', () => {
    const unresolved = { ...empty, unresolved_readings: 2, unobserved_attempts: 1 }
    expect(keeperCostSummary(unresolved)).toContain('2 unresolved readings · 1 unobserved attempts')
  })
  it.each([undefined, null, '0', -1, Number.NaN, Number.POSITIVE_INFINITY,
    { ...empty, known_cost_usd: 2 }, { ...empty, extra: 1 },
    { ...empty, history: 'future' }, { ...empty, priced_readings: -1 },
    { ...empty, unpriced_readings: 1.5 }, { ...empty, unresolved_readings: Number.MAX_SAFE_INTEGER + 1 },
    { ...empty, unobserved_attempts: null }, { known_cost_usd: 2 },
  ])('refuses malformed evidence without salvaging a sum: %j', raw => {
    expect(readKeeperCostCoverage(raw)).toBeNull()
    expect(keeperCostSummary(readKeeperCostCoverage(raw))).toBe('cost not observed')
  })
})
