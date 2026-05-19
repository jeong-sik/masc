import { describe, it, expect } from 'vitest'
import type { Keeper } from '../types/core'
import {
  isKeeperPaused,
  isKeeperOffline,
  isKeeperRunningExcludingRestarting,
  keeperIsStuckOnRecoverableBlocker,
  keeperCanWakeup,
} from './keeper-predicates'

function k(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'test-keeper',
    status: 'active',
    ...overrides,
  } as Keeper
}

describe('isKeeperPaused — RFC-0135 PR-3 SSOT', () => {
  it('returns true on explicit paused flag', () => {
    expect(isKeeperPaused(k({ paused: true }))).toBe(true)
  })
  it('returns true on FSM phase Paused', () => {
    expect(isKeeperPaused(k({ phase: 'Paused' }))).toBe(true)
  })
  it('returns true on pipeline_stage paused', () => {
    expect(isKeeperPaused(k({ pipeline_stage: 'paused' }))).toBe(true)
  })
  it('returns true on lowercased status paused', () => {
    expect(isKeeperPaused(k({ status: 'paused' }))).toBe(true)
  })
  it('returns true on uppercased status PAUSED', () => {
    expect(isKeeperPaused(k({ status: 'PAUSED' }))).toBe(true)
  })
  it('returns false when no axis indicates paused', () => {
    expect(isKeeperPaused(k({ paused: false, phase: 'Running', status: 'active' }))).toBe(false)
  })
})

describe('isKeeperOffline', () => {
  it.each<[Keeper['phase']]>([
    ['Offline'], ['Stopped'], ['Dead'], ['Crashed'], ['Zombie'],
  ])('phase=%s ⇒ offline', (phase) => {
    expect(isKeeperOffline(k({ phase }))).toBe(true)
  })
  it.each([['offline'], ['inactive'], ['unbooted']])('status=%s ⇒ offline', (status) => {
    expect(isKeeperOffline(k({ status }))).toBe(true)
  })
  it('Running keeper not offline', () => {
    expect(isKeeperOffline(k({ phase: 'Running' }))).toBe(false)
  })
})

describe('keeperIsStuckOnRecoverableBlocker', () => {
  it.each([
    ['cascade_exhausted'], ['oas_timeout_budget'], ['turn_timeout'],
  ])('blocker_class=%s ⇒ stuck-recoverable', (cls) => {
    expect(keeperIsStuckOnRecoverableBlocker(k({ runtime_blocker_class: cls as Keeper['runtime_blocker_class'] }))).toBe(true)
  })
  it('other blocker classes are not in the wakeup-recoverable set', () => {
    expect(keeperIsStuckOnRecoverableBlocker(k({ runtime_blocker_class: 'synthetic_stall' }))).toBe(false)
  })
  it('null blocker is not stuck', () => {
    expect(keeperIsStuckOnRecoverableBlocker(k())).toBe(false)
  })
})

describe('keeperCanWakeup', () => {
  it('stuck on recoverable blocker ⇒ can wake', () => {
    expect(keeperCanWakeup(k({ runtime_blocker_class: 'oas_timeout_budget' }))).toBe(true)
  })
  it('plain running keeper ⇒ can wake (kick next turn)', () => {
    expect(keeperCanWakeup(k({ phase: 'Running' }))).toBe(true)
  })
  it('paused keeper ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true }))).toBe(false)
  })
  it('offline keeper ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ phase: 'Crashed' }))).toBe(false)
  })
})

describe('isKeeperRunningExcludingRestarting — RFC-0135 PR-11', () => {
  it.each([
    ['active'], ['running'], ['idle'], ['busy'],
  ])('status=%s ⇒ running', (status) => {
    expect(isKeeperRunningExcludingRestarting(k({ status }))).toBe(true)
  })
  it.each([
    ['Running'], ['Failing'], ['Overflowed'], ['Compacting'], ['HandingOff'], ['Draining'],
  ])('phase=%s ⇒ running', (phase) => {
    expect(isKeeperRunningExcludingRestarting(k({ status: 'unknown', phase: phase as Keeper['phase'] }))).toBe(true)
  })
  it('Restarting phase ⇒ NOT running (action panel treats as stuck)', () => {
    expect(isKeeperRunningExcludingRestarting(k({ status: 'unknown', phase: 'Restarting' }))).toBe(false)
  })
  it.each([
    ['Offline'], ['Stopped'], ['Crashed'], ['Dead'], ['Zombie'], ['Paused'],
  ])('phase=%s ⇒ NOT running', (phase) => {
    expect(isKeeperRunningExcludingRestarting(k({ status: 'unknown', phase: phase as Keeper['phase'] }))).toBe(false)
  })
})
