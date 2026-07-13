import { describe, it, expect } from 'vitest'
import type { Keeper } from '../types/core'
import {
  isKeeperCrashed,
  isCrashedPhase,
  isKeeperPaused,
  isKeeperOffline,
  isKeeperOperatorTargetable,
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
  it('returns true on lifecycle_phase Paused even when phase is stale', () => {
    expect(isKeeperPaused(k({ lifecycle_phase: 'Paused', phase: 'Running' }))).toBe(true)
  })
  it('returns true on lowercase phase paused from operator snapshots', () => {
    expect(isKeeperPaused({ phase: 'paused' })).toBe(true)
  })
  it('returns true on pipeline_stage paused', () => {
    expect(isKeeperPaused(k({ pipeline_stage: 'paused' }))).toBe(true)
  })
  it('returns true on pause_state paused', () => {
    expect(isKeeperPaused(k({ pause_state: 'paused' }))).toBe(true)
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
    ['Offline'], ['Stopped'], ['Dead'], ['Crashed'],
  ])('phase=%s ⇒ offline', (phase) => {
    expect(isKeeperOffline(k({ phase }))).toBe(true)
  })
  it('lifecycle_phase overrides stale phase for offline classification', () => {
    expect(isKeeperOffline(k({ lifecycle_phase: 'Offline', phase: 'Running' }))).toBe(true)
  })
  it.each(['offline', 'stopped', 'dead', 'crashed'])('lowercase phase=%s ⇒ offline', (phase) => {
    expect(isKeeperOffline({ phase })).toBe(true)
  })
  it.each([['offline'], ['inactive'], ['unbooted'], ['stopped']])('status=%s ⇒ offline', (status) => {
    expect(isKeeperOffline(k({ status }))).toBe(true)
  })
  it('Running keeper not offline', () => {
    expect(isKeeperOffline(k({ phase: 'Running' }))).toBe(false)
  })
  it('audit B5 absorbed: status-only `stopped` token (legacy isOfflineStatus arm)', () => {
    // Pre RFC-0139 PR-2 the `'stopped'` status token was recognised
    // only by `lib/status-utils.isOfflineStatus`. The keeper-side SSOT
    // now absorbs it so a wire-format-only snapshot (phase missing)
    // still routes to the offline branch.
    expect(isKeeperOffline({ status: 'stopped' })).toBe(true)
  })
})

describe('isKeeperOperatorTargetable', () => {
  it('keeps phase-paused keepers targetable even when status is offline', () => {
    expect(isKeeperOperatorTargetable({
      status: 'offline',
      phase: 'paused',
      pipeline_stage: 'paused',
    })).toBe(true)
  })

  it('excludes truly offline keepers', () => {
    expect(isKeeperOperatorTargetable({ status: 'offline', phase: 'offline' })).toBe(false)
  })
})

describe('isKeeperCrashed — audit A1 (2026-05-19)', () => {
  it.each<[Keeper['phase']]>([
    ['Crashed'], ['Dead'],
  ])('phase=%s ⇒ crashed', (phase) => {
    expect(isKeeperCrashed(k({ phase }))).toBe(true)
  })
  it.each<[Keeper['phase']]>([
    ['Running'], ['Paused'], ['Offline'], ['Stopped'], ['Restarting'],
    ['Failing'], ['Overflowed'], ['Compacting'], ['HandingOff'], ['Draining'],
  ])('phase=%s ⇒ NOT crashed (terminal-failure-only subset)', (phase) => {
    expect(isKeeperCrashed(k({ phase }))).toBe(false)
  })
  it('null phase ⇒ NOT crashed', () => {
    expect(isKeeperCrashed(k({ phase: null }))).toBe(false)
  })
  it('undefined phase ⇒ NOT crashed', () => {
    expect(isKeeperCrashed(k())).toBe(false)
  })
  it('lifecycle_phase overrides stale phase for crashed classification', () => {
    expect(isKeeperCrashed(k({ lifecycle_phase: 'Dead', phase: 'Running' }))).toBe(true)
  })
})

describe('isCrashedPhase — SSE-safe casing checker', () => {
  it.each(['Crashed', 'crashed', 'Dead', 'dead'])(
    'phase=%s ⇒ crashed',
    (phase) => {
      expect(isCrashedPhase(phase)).toBe(true)
    },
  )
  it.each(['Running', 'running', 'Paused', 'Failing', 'Offline', 'Restarting'])(
    'phase=%s ⇒ NOT crashed',
    (phase) => {
      expect(isCrashedPhase(phase)).toBe(false)
    },
  )
  it('null/undefined ⇒ NOT crashed', () => {
    expect(isCrashedPhase(null)).toBe(false)
    expect(isCrashedPhase(undefined)).toBe(false)
    expect(isCrashedPhase('')).toBe(false)
  })
})

describe('keeperIsStuckOnRecoverableBlocker', () => {
  it.each([
    ['runtime_exhausted'], ['turn_timeout'],
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
  it('stuck on canonical recoverable blocker ⇒ can wake', () => {
    expect(keeperCanWakeup(k({ runtime_blocker_class: 'turn_timeout' }))).toBe(true)
  })
  it('plain running keeper ⇒ can wake (kick next turn)', () => {
    expect(keeperCanWakeup(k({ phase: 'Running' }))).toBe(true)
  })
  it('paused keeper ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true }))).toBe(false)
  })
  it('paused keeper with recoverable blocker ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true, runtime_blocker_class: 'turn_timeout' }))).toBe(false)
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
    ['Offline'], ['Stopped'], ['Crashed'], ['Dead'], ['Paused'],
  ])('phase=%s ⇒ NOT running', (phase) => {
    expect(isKeeperRunningExcludingRestarting(k({ status: 'unknown', phase: phase as Keeper['phase'] }))).toBe(false)
  })
})
