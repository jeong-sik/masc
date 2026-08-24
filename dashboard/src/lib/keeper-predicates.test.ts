import { describe, it, expect } from 'vitest'
import type { Keeper } from '../types/core'
import {
  isKeeperCrashed,
  isCrashedPhase,
  isKeeperPaused,
  isKeeperOffline,
  type KeeperOfflineInput,
  isKeeperOperatorTargetable,
  isKeeperRunningExcludingRestarting,
  keeperIsStuckOnRecoverableBlocker,
  keeperCanWakeup,
  keeperActionVisibility,
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
    ['Offline'], ['Stopped'], ['Crashed'],
  ])('phase=%s ⇒ offline', (phase) => {
    expect(isKeeperOffline(k({ phase }))).toBe(true)
  })
  it('lifecycle_phase overrides stale phase for offline classification', () => {
    expect(isKeeperOffline(k({ lifecycle_phase: 'Offline', phase: 'Running' }))).toBe(true)
  })
  it.each(['offline', 'stopped', 'crashed'])('lowercase phase=%s ⇒ offline', (phase) => {
    expect(isKeeperOffline({ phase })).toBe(true)
  })
  it('Running keeper not offline', () => {
    expect(isKeeperOffline(k({ phase: 'Running' }))).toBe(false)
  })
  it('health=offline ⇒ offline', () => {
    expect(isKeeperOffline({ diagnostic: { health_state: 'offline' } })).toBe(true)
  })
  it.each(['stale', 'degraded', 'zombie', 'idle', 'healthy'])(
    'health=%s 는 조용해진 것이지 멈춘 것이 아니다',
    (health_state) => {
      expect(isKeeperOffline({ diagnostic: { health_state } })).toBe(false)
    },
  )
  it.each(['offline', 'inactive', 'unbooted', 'stopped', 'active'])(
    'status=%s 는 판정에 관여하지 않는다',
    (status) => {
      expect(isKeeperOffline({ status } as KeeperOfflineInput)).toBe(false)
    },
  )
  it('축이 하나도 없으면 offline 이라고 단정하지 않는다', () => {
    expect(isKeeperOffline({})).toBe(false)
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
    ['Crashed'],
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
  })
})

describe('isCrashedPhase — SSE-safe casing checker', () => {
  it.each(['Crashed', 'crashed'])(
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
    ['runtime_exhausted'],
  ])('blocker_class=%s ⇒ stuck-recoverable', (cls) => {
    expect(keeperIsStuckOnRecoverableBlocker(k({ runtime_blocker_class: cls as Keeper['runtime_blocker_class'] }))).toBe(true)
  })
  it('other blocker classes are not in the wakeup-recoverable set', () => {
    expect(keeperIsStuckOnRecoverableBlocker(k({ runtime_blocker_class: 'exception' }))).toBe(false)
  })
  it('null blocker is not stuck', () => {
    expect(keeperIsStuckOnRecoverableBlocker(k())).toBe(false)
  })
})

describe('keeperCanWakeup', () => {
  it('stuck on canonical recoverable blocker ⇒ can wake', () => {
    expect(keeperCanWakeup(k({ runtime_blocker_class: 'stale_turn_timeout' }))).toBe(true)
  })
  it('plain running keeper ⇒ can wake (kick next turn)', () => {
    expect(keeperCanWakeup(k({ phase: 'Running' }))).toBe(true)
  })
  it('paused keeper ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true }))).toBe(false)
  })
  it('paused keeper with recoverable blocker ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true, runtime_blocker_class: 'stale_turn_timeout' }))).toBe(false)
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
    ['Offline'], ['Stopped'], ['Crashed'], ['Paused'],
  ])('phase=%s ⇒ NOT running', (phase) => {
    expect(isKeeperRunningExcludingRestarting(k({ status: 'unknown', phase: phase as Keeper['phase'] }))).toBe(false)
  })
})

// 2026-08-24 라이브 관측: /api/v1/dashboard/execution 의 `rondo` 는
// status='offline' 인데 health='healthy', phase='Running', paused=false 였다.
// 캐시된 행에서 `status` 만 옛 값에 머물고 diagnostic 은 새로 채워진 결과다.
// 18초 동안 네 번 폴링해도 그대로였으니 경합이 아니라 고정된 어긋남이다.
describe('접힌 status 가 살아 있는 축과 어긋날 때', () => {
  const rondo = k({
    status: 'offline',
    phase: 'Running',
    lifecycle_phase: 'Running',
    paused: false,
    keepalive_running: true,
    diagnostic: { health_state: 'healthy' },
  } as Partial<Keeper>)

  it('health 와 phase 가 살아 있다고 말하면 offline 이 아니다', () => {
    expect(isKeeperOffline(rondo)).toBe(false)
  })

  it('살아 있는 키퍼에게 부팅과 삭제를 권하지 않는다', () => {
    const vis = keeperActionVisibility(rondo)
    expect(vis.canBoot).toBe(false)
    expect(vis.canPurge).toBe(false)
  })

  it('살아 있는 키퍼는 깨울 수 있다', () => {
    expect(keeperCanWakeup(rondo)).toBe(true)
  })

  it('health=offline 은 phase 와 무관하게 offline 으로 읽는다', () => {
    expect(isKeeperOffline(k({
      status: 'active',
      phase: 'Running',
      diagnostic: { health_state: 'offline' },
    } as Partial<Keeper>))).toBe(true)
  })
})
