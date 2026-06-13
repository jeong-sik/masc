import { describe, expect, it } from 'vitest'
import { isKeeperPaused } from '../lib/keeper-predicates'
import type { Keeper } from '../types'

describe('isKeeperPaused', () => {
  function keeper(overrides: Partial<Keeper>): Keeper {
    return { name: 'test', status: 'active', ...overrides } satisfies Keeper
  }

  it('returns true when paused flag is set', () => {
    expect(isKeeperPaused(keeper({ paused: true }))).toBe(true)
  })

  it('returns true when phase is Paused', () => {
    expect(isKeeperPaused(keeper({ phase: 'Paused' }))).toBe(true)
  })

  it('returns true when pipeline_stage is paused', () => {
    expect(isKeeperPaused(keeper({ pipeline_stage: 'paused' }))).toBe(true)
  })

  it('returns false for a running keeper', () => {
    expect(isKeeperPaused(keeper({ phase: 'Running', paused: false }))).toBe(false)
  })

  it('returns false when paused is false and phase is Running', () => {
    expect(isKeeperPaused(keeper({ paused: false, phase: 'Running', pipeline_stage: 'idle' }))).toBe(false)
  })

  it('returns false when paused is undefined', () => {
    expect(isKeeperPaused(keeper({ phase: 'Running' }))).toBe(false)
  })
})
