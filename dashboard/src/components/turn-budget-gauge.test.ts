import { describe, it, expect } from 'vitest'
import { deriveBudgetGaugeState, BUDGET_WARN_RATIO, BUDGET_CRIT_RATIO } from './turn-budget-gauge'
import type { Keeper } from '../types'

function makeKeeper(
  overrides: Partial<{
    name: string
    status: string
    phase: string
    paused: boolean
    supervisor_diagnostics: {
      restart_count?: number
      max_restarts?: number
    }
    conditions: { restart_budget_remaining?: boolean }
  }>,
): Keeper {
  return {
    name: 'test-keeper',
    status: 'active',
    phase: 'Running',
    ...overrides,
  } as unknown as Keeper
}

describe('deriveBudgetGaugeState', () => {
  it('returns null when no supervisor_diagnostics', () => {
    const k = makeKeeper({})
    expect(deriveBudgetGaugeState(k)).toBeNull()
  })

  it('returns null when restart_count is missing', () => {
    const k = makeKeeper({ supervisor_diagnostics: { max_restarts: 5 } })
    expect(deriveBudgetGaugeState(k)).toBeNull()
  })

  it('returns null when max_restarts is missing', () => {
    const k = makeKeeper({ supervisor_diagnostics: { restart_count: 2 } })
    expect(deriveBudgetGaugeState(k)).toBeNull()
  })

  it('returns null when max_restarts is 0', () => {
    const k = makeKeeper({ supervisor_diagnostics: { restart_count: 0, max_restarts: 0 } })
    expect(deriveBudgetGaugeState(k)).toBeNull()
  })

  it('returns ok tone when ratio is below warn threshold', () => {
    const k = makeKeeper({
      supervisor_diagnostics: { restart_count: 1, max_restarts: 10 },
      conditions: { restart_budget_remaining: true },
    })
    const state = deriveBudgetGaugeState(k)
    expect(state).not.toBeNull()
    expect(state!.tone).toBe('ok')
    expect(state!.ratio).toBeCloseTo(0.1)
    expect(state!.remaining).toBe(true)
  })

  it('returns warn tone when ratio is between warn and crit thresholds', () => {
    const used = Math.ceil(BUDGET_WARN_RATIO * 10)   // 5 out of 10 → 50%
    const k = makeKeeper({
      supervisor_diagnostics: { restart_count: used, max_restarts: 10 },
      conditions: { restart_budget_remaining: true },
    })
    const state = deriveBudgetGaugeState(k)
    expect(state).not.toBeNull()
    expect(state!.tone).toBe('warn')
  })

  it('returns bad tone when ratio is above crit threshold', () => {
    const used = Math.ceil(BUDGET_CRIT_RATIO * 10)   // 8 out of 10 → 80%
    const k = makeKeeper({
      supervisor_diagnostics: { restart_count: used, max_restarts: 10 },
      conditions: { restart_budget_remaining: true },
    })
    const state = deriveBudgetGaugeState(k)
    expect(state).not.toBeNull()
    expect(state!.tone).toBe('bad')
  })

  it('returns bad tone when restart_budget_remaining is false regardless of ratio', () => {
    const k = makeKeeper({
      supervisor_diagnostics: { restart_count: 1, max_restarts: 10 },
      conditions: { restart_budget_remaining: false },
    })
    const state = deriveBudgetGaugeState(k)
    expect(state).not.toBeNull()
    expect(state!.tone).toBe('bad')
    expect(state!.remaining).toBe(false)
  })

  it('defaults remaining to true when conditions are absent', () => {
    const k = makeKeeper({
      supervisor_diagnostics: { restart_count: 0, max_restarts: 10 },
    })
    const state = deriveBudgetGaugeState(k)
    expect(state).not.toBeNull()
    expect(state!.remaining).toBe(true)
  })
})
