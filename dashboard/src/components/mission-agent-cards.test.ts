import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Keeper } from '../types'
import {
  keeperDisplayStatus,
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

  it('renders continue-gate hints when manual reconcile is required', () => {
    const keeper = {
      name: 'uranium666',
      status: 'idle',
      paused: true,
      keepalive_running: true,
      runtime_blocker_class: 'ambiguous_post_commit_timeout',
      runtime_blocker_summary:
        'Mutating tools [keeper_fs_edit] committed before the turn timed out.',
      runtime_blocker_manual_reconcile: true,
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      '계속 진행 승인 대기 · Mutating tools [keeper_fs_edit] committed before the turn timed out.',
    )
  })

  it('renders social-model fallback hints when the configured model is unknown', () => {
    const keeper = {
      name: 'uranium666',
      status: 'busy',
      social_model: 'bdi_speech_v1',
      configured_social_model: 'experimental_v99',
      social_model_recognized: false,
      social_model_fallback: 'bdi_speech_v1',
    } as Keeper

    expect(keeperRuntimeHint(keeper)).toBe(
      '소셜 모델 experimental_v99 미인식 · bdi_speech_v1로 대체 중',
    )
  })
})
