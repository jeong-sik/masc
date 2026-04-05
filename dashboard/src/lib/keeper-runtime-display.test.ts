import { describe, expect, it } from 'vitest'
import type { Keeper } from '../types'
import { keeperDisplayStatus } from './keeper-runtime-display'

/** Minimal Keeper stub with only the fields relevant to status classification. */
function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'test-keeper',
    status: 'offline',
    ...overrides,
  } as Keeper
}

describe('keeperDisplayStatus', () => {
  it('returns paused when keeper.paused is true', () => {
    expect(keeperDisplayStatus(makeKeeper({ paused: true }))).toBe('paused')
  })

  it('returns unknown for null keeper', () => {
    expect(keeperDisplayStatus(null)).toBe('unknown')
  })

  it('returns unknown for undefined keeper', () => {
    expect(keeperDisplayStatus(undefined)).toBe('unknown')
  })

  it('passes through non-offline statuses', () => {
    expect(keeperDisplayStatus(makeKeeper({ status: 'active' }))).toBe('active')
    expect(keeperDisplayStatus(makeKeeper({ status: 'idle' }))).toBe('idle')
  })

  describe('offline refinement into unbooted/stopped', () => {
    it('classifies offline keeper with no activity as unbooted', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('classifies inactive keeper with no activity as unbooted', () => {
      const keeper = makeKeeper({
        status: 'inactive',
        generation: 0,
        turn_count: 0,
        agent: { exists: false },
      })
      expect(keeperDisplayStatus(keeper)).toBe('unbooted')
    })

    it('classifies offline keeper with generation > 0 as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 3,
        turn_count: 0,
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('classifies offline keeper with turn_count > 0 as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 5,
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })

    it('classifies offline keeper with agent.exists=true but no turns as offline', () => {
      // agent exists but generation=0, turn_count=0 — doesn't match unbooted
      // (agent exists) and doesn't match stopped (no turns/generation)
      const keeper = makeKeeper({
        status: 'offline',
        generation: 0,
        turn_count: 0,
        agent: { exists: true },
      })
      expect(keeperDisplayStatus(keeper)).toBe('offline')
    })

    it('classifies offline keeper with all activity signals as stopped', () => {
      const keeper = makeKeeper({
        status: 'offline',
        generation: 2,
        turn_count: 10,
        agent: { exists: true },
      })
      expect(keeperDisplayStatus(keeper)).toBe('stopped')
    })
  })
})
