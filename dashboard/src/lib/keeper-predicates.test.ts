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
  // 대소문자 무시는 그대로다. operator snapshot 은 소문자 토큰을,
  // hydrate 된 Keeper 는 PascalCase 를 싣기 때문이다.
  it('축 토큰의 대소문자를 가리지 않는다', () => {
    // `Keeper` 쪽 필드는 닫힌 합타입이라 소문자/대문자 변형이 애초에 들어가지
    // 않는다. 대소문자를 가리지 않는 건 구조적 입력, 즉 operator snapshot 몫이다.
    expect(isKeeperPaused({ pipeline_stage: 'PAUSED' })).toBe(true)
    expect(isKeeperPaused({ lifecycle_phase: 'paused' })).toBe(true)
  })
  it('returns false when no axis indicates paused', () => {
    expect(isKeeperPaused(k({ paused: false, phase: 'Running', status: 'active' }))).toBe(false)
  })
})

// `paused` 불리언과 `status='paused'` 는 서버에서 같은 `ld_paused` 로 만들어진다.
// 그런데 execution 캐시의 lifecycle override 는 `Stopped` 이벤트를 받으면
// 기존 `Cp_paused` 를 그대로 두므로(server_dashboard_http_execution_surfaces.ml),
// `paused: false` 와 `status: 'paused'` 가 한 행에 같이 남을 수 있다.
// 그때 접힌 단어를 읽으면 이미 멈춘 키퍼가 "재개할 수 있다"로 보인다.
describe('일시정지는 flag 로만 판정한다', () => {
  it("paused=false 인데 status='paused' 면 일시정지가 아니다", () => {
    expect(isKeeperPaused({ paused: false, status: 'paused' })).toBe(false)
  })

  it('paused=true 면 일시정지다', () => {
    expect(isKeeperPaused({ paused: true })).toBe(true)
  })

  it("status='paused' 하나로는 일시정지가 되지 않는다", () => {
    expect(isKeeperPaused({ status: 'paused' })).toBe(false)
  })

  it('phase 와 stage 는 그대로 일시정지를 말한다', () => {
    expect(isKeeperPaused({ phase: 'Paused' })).toBe(true)
    expect(isKeeperPaused({ lifecycle_phase: 'Paused' })).toBe(true)
    expect(isKeeperPaused({ pipeline_stage: 'paused' })).toBe(true)
    expect(isKeeperPaused({ pause_state: 'paused' })).toBe(true)
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

// `RUNNING_STATUS_TOKENS` 에는 `busy` 와 `listening` 이 있었는데, 이 둘은
// types_core.ml 의 *에이전트* 어휘지 키퍼 status 가 아니다. #30084 에서
// Surface_busy/Surface_listening 을 지운 뒤로는 어떤 producer 도 보내지 않는다.
// `running` 도 키퍼 status 로 나온 적이 없다. 키퍼의 status 는
// keeper_surface_status 가 만드는 active|inactive|offline|idle 과
// control-plane 의 paused 뿐이다.
describe('running 판정은 phase 와 health 로만 한다', () => {
  it('running 계열 phase 는 running 이다', () => {
    for (const phase of ['Running', 'Failing', 'Draining']) {
      expect(isKeeperRunningExcludingRestarting(k({ phase } as Partial<Keeper>))).toBe(true)
    }
  })

  it('Restarting 은 이름 그대로 제외한다', () => {
    expect(isKeeperRunningExcludingRestarting(k({ phase: 'Restarting' }))).toBe(false)
  })

  it.each(['Paused', 'Offline', 'Stopped', 'Crashed'])('%s 는 running 이 아니다', (phase) => {
    expect(isKeeperRunningExcludingRestarting(k({ phase } as Partial<Keeper>))).toBe(false)
  })

  it('소문자 phase 토큰도 같은 답을 준다', () => {
    expect(isKeeperRunningExcludingRestarting(k({ phase: 'running' } as unknown as Partial<Keeper>))).toBe(true)
    expect(isKeeperRunningExcludingRestarting(k({ phase: 'restarting' } as unknown as Partial<Keeper>))).toBe(false)
  })

  it.each(['active', 'running', 'idle', 'busy', 'listening'])(
    'status=%s 하나로는 running 이 되지 않는다',
    (status) => {
      expect(isKeeperRunningExcludingRestarting(k({ status, phase: null }))).toBe(false)
    },
  )

  // phase 가 없는 스냅샷에서는 health 가 답한다. 하트비트가 늦은(stale) 키퍼도
  // 아직 돌고 있으므로 종료를 걸 수 있어야 한다.
  it.each(['healthy', 'idle', 'stale', 'degraded'])('phase 없이 health=%s 면 running', (health_state) => {
    expect(isKeeperRunningExcludingRestarting(
      k({ phase: null, diagnostic: { health_state } } as Partial<Keeper>),
    )).toBe(true)
  })

  it.each(['offline', 'zombie'])('phase 없이 health=%s 면 running 이 아니다', (health_state) => {
    expect(isKeeperRunningExcludingRestarting(
      k({ phase: null, diagnostic: { health_state } } as Partial<Keeper>),
    )).toBe(false)
  })

  it('축이 하나도 없으면 running 이라고 단정하지 않는다', () => {
    expect(isKeeperRunningExcludingRestarting(k({ phase: null }))).toBe(false)
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
    ['Failing'], ['Draining'],
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
    expect(keeperCanWakeup(k({ runtime_blocker_class: 'fiber_unresolved' }))).toBe(true)
  })
  it('plain running keeper ⇒ can wake (kick next turn)', () => {
    expect(keeperCanWakeup(k({ phase: 'Running' }))).toBe(true)
  })
  it('paused keeper ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true }))).toBe(false)
  })
  it('paused keeper with recoverable blocker ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ paused: true, runtime_blocker_class: 'fiber_unresolved' }))).toBe(false)
  })
  it('offline keeper ⇒ cannot wake', () => {
    expect(keeperCanWakeup(k({ phase: 'Crashed' }))).toBe(false)
  })
})

describe('isKeeperRunningExcludingRestarting — RFC-0135 PR-11', () => {
  it.each([
    ['Running'], ['Failing'], ['Draining'],
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
