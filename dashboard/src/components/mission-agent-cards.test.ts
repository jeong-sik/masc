import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Keeper } from '../types'
import {
  keeperDisplayStatus,
  keeperRuntimeBlockerLabel,
  keeperRecentActionLabel,
  keeperRecentHeartbeatLabel,
  keeperRuntimeHint,
} from '../lib/keeper-runtime-display'

describe('mission keeper runtime helpers', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-04-04T15:00:00Z'))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('elevates paused keepers above idle status', () => {
    const keeper = {
      name: 'uranium666',
      status: 'idle',
      paused: true,
      keepalive_running: true,
      last_blocker: 'missing social headers',
      last_heartbeat: '2026-04-04T14:43:49Z',
      last_autonomous_action_at: '2026-04-04T14:08:35Z',
    } as Keeper

    expect(keeperDisplayStatus(keeper, 'idle')).toBe('paused')
    expect(keeperRuntimeHint(keeper)).toBe('일시정지 · missing social headers')
    expect(keeperRecentHeartbeatLabel(keeper)).toContain('최근 하트비트')
    expect(keeperRecentHeartbeatLabel(keeper)).toContain('16분 전')
    expect(keeperRecentActionLabel(keeper)).toContain('마지막 행동')
    expect(keeperRecentActionLabel(keeper)).toContain('51분 전')
  })

  it('falls back to turn age when no autonomous action timestamp exists', () => {
    expect(
      keeperRecentActionLabel(
        { name: 'fallback', status: 'busy' } as Keeper,
        125,
      ),
    ).toBe('마지막 턴 · 125초 전')
  })

  it('shows paused-only runtime hint when keepalive is not running', () => {
    const keeper = {
      name: 'uranium666',
      status: 'idle',
      paused: true,
      keepalive_running: false,
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe('일시정지됨')
  })

  it('prefers structured runtime blocker hints over paused/blocker text', () => {
    const keeper = {
      name: 'uranium666',
      status: 'idle',
      paused: true,
      keepalive_running: true,
      runtime_blocker_class: 'ambiguous_post_commit_timeout',
      runtime_blocker_summary:
        'Mutating tools [keeper_fs_edit] committed before the turn timed out.',
      last_blocker: 'missing social headers',
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      'Mutating tools [keeper_fs_edit] committed before the turn timed out.',
    )
  })

  it('renders continue-gate hints when approval is required', () => {
    const keeper = {
      name: 'uranium666',
      status: 'idle',
      paused: true,
      keepalive_running: true,
      runtime_blocker_class: 'ambiguous_post_commit_timeout',
      runtime_blocker_summary:
        'Mutating tools [keeper_fs_edit] committed before the turn timed out.',
      runtime_blocker_continue_gate: true,
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      '계속 진행 승인 대기 · Mutating tools [keeper_fs_edit] committed before the turn timed out.',
    )
  })

  it('labels backend runtime blocker classes used by keeper_status_bridge', () => {
    expect(keeperRuntimeBlockerLabel('no_tool_capable_provider')).toBe('도구 실행 Provider 없음')
    expect(keeperRuntimeBlockerLabel('fiber_unresolved')).toBe('Fiber 미해결')
    expect(keeperRuntimeBlockerLabel('stale_turn_timeout')).toBe('오래된 턴 만료')
    expect(keeperRuntimeBlockerLabel('stale_termination_storm')).toBe('Stale 종료 폭주')
    expect(keeperRuntimeBlockerLabel('heartbeat_failures')).toBe('하트비트 실패')
    expect(keeperRuntimeBlockerLabel('turn_failures')).toBe('턴 실패 반복')
    expect(keeperRuntimeBlockerLabel('provider_runtime_error')).toBe('Provider 런타임 오류')
    expect(keeperRuntimeBlockerLabel('tool_required_unsatisfied')).toBe('필수 도구 미충족')
    expect(keeperRuntimeBlockerLabel('exception')).toBe('런타임 예외')
    expect(keeperRuntimeBlockerLabel('stale_fleet_batch')).toBe('Fleet stale 배치')
  })

  it('turns raw backend blocker codes into operator-readable hints', () => {
    const keeper = {
      name: 'tool-less',
      status: 'idle',
      runtime_blocker_class: 'no_tool_capable_provider',
      runtime_blocker_summary: 'no_tool_capable_provider',
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      '요구 도구를 실행할 수 있는 provider가 없어 라우팅 또는 tool surface 확인이 필요합니다.',
    )
  })

  it('turns registry failure blocker codes into operator-readable hints', () => {
    const keeper = {
      name: 'stormed',
      status: 'idle',
      runtime_blocker_class: 'stale_termination_storm',
      runtime_blocker_summary:
        'Stale watchdog terminated 8 keeper cycle(s) in the storm window; operator investigation is required before restart.',
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      'Stale watchdog terminated 8 keeper cycle(s) in the storm window; operator investigation is required before restart.',
    )
  })

  it('turns stale fleet batch blockers into operator-readable hints', () => {
    const keeper = {
      name: 'batch-paused',
      status: 'paused',
      runtime_blocker_class: 'stale_fleet_batch',
      runtime_blocker_summary: 'stale_fleet_batch',
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      '여러 keeper가 같은 watchdog 창에서 stale로 종료되어 supervisor pause/backoff 상태 확인이 필요합니다.',
    )
  })

  it('renders dialogue-model fallback hints when the configured model is unknown', () => {
    const keeper = {
      name: 'uranium666',
      status: 'busy',
      social_model: 'bdi_speech_v1',
      configured_social_model: 'experimental_v99',
      social_model_recognized: false,
      social_model_fallback: 'bdi_speech_v1',
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      '대화 모델 experimental_v99 미인식 · bdi_speech_v1로 대체 중',
    )
  })
})
