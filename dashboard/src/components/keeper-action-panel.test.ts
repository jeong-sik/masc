import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock modules with lucide-preact icons that cause test-env errors
vi.mock('./common/confirm-dialog', () => ({ requestConfirm: vi.fn(async () => false) }))
vi.mock('./common/toast', () => ({ showToast: vi.fn() }))
vi.mock('./common/button', () => ({ ActionButton: () => null }))
vi.mock('./keeper-phase-indicator', () => ({ KeeperPhaseBadge: () => null }))
vi.mock('../api/keeper', () => ({
  bootKeeper: vi.fn(),
  pauseKeeper: vi.fn(),
  resumeKeeper: vi.fn(),
  shutdownKeeper: vi.fn(),
  wakeKeeper: vi.fn(),
}))
vi.mock('../api/keeper-lifecycle', () => ({
  purgeKeeper: vi.fn(async () => ({
    ok: true,
    accepted: true,
    target_kind: 'keeper',
    agent_name: 'keeper-test-agent',
    keeper_name: 'test',
    operation_id: 'op-1',
  })),
  KEEPER_PURGE_ARTIFACTS: ['결정 로그', '대화 기록'],
}))
vi.mock('../store', () => ({
  keepers: { value: [] },
  keeperPurgePending: { value: new Set<string>() },
  markKeeperPurgePending: vi.fn(),
  applyOptimisticKeeperDirective: vi.fn(() => () => {}),
  refreshKeeperRuntimeStatus: vi.fn(async () => undefined),
}))

import { pauseKeeper, resumeKeeper } from '../api/keeper'
import { purgeKeeper } from '../api/keeper-lifecycle'
import { requestConfirm } from './common/confirm-dialog'
import { showToast } from './common/toast'
import { keeperActionVisibility } from '../lib/keeper-predicates'
import {
  applyOptimisticKeeperDirective,
  markKeeperPurgePending,
  refreshKeeperRuntimeStatus,
} from '../store'
import { runKeeperAction } from './keeper-action-panel'
import type { Keeper } from '../types'

function makeKeeper(overrides: Partial<Keeper>): Keeper {
  return {
    name: 'test',
    status: 'active',
    phase: 'Running',
    paused: false,
    // A keeper with its fiber alive is the normal case; paused-owner tests
    // override this to false explicitly.
    keepalive_running: true,
    ...overrides,
  } as unknown as Keeper
}

describe('keeperActionVisibility', () => {
  describe('running keeper (not paused)', () => {
    it('can pause and shutdown, cannot boot or resume', () => {
      const k = makeKeeper({ status: 'active', phase: 'Running', paused: false })
      const v = keeperActionVisibility(k)
      expect(v.canPause).toBe(true)
      expect(v.canResume).toBe(false)
      expect(v.canBoot).toBe(false)
      expect(v.canShutdown).toBe(true)
      expect(v.canWake).toBe(true)
    })
  })

  describe('paused keeper', () => {
    it('can resume and shutdown, cannot pause or boot', () => {
      const k = makeKeeper({ status: 'active', phase: 'Paused', paused: true })
      const v = keeperActionVisibility(k)
      expect(v.canPause).toBe(false)
      expect(v.canResume).toBe(true)
      expect(v.canBoot).toBe(false)
      expect(v.canShutdown).toBe(true)
    })

    it('detects paused via paused flag even if status is active', () => {
      const k = makeKeeper({ status: 'active', phase: 'Running', paused: true })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canPause).toBe(false)
      expect(v.canWake).toBe(false)
    })

    it('phase 가 없어도 flag 가 서 있으면 재개를 권한다', () => {
      const k = makeKeeper({ status: 'active', phase: null, paused: true })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canPause).toBe(false)
      expect(v.canWake).toBe(false)
    })

    // flag 가 내려간 뒤에도 캐시된 `status` 단어가 남아 있을 수 있다.
    // 그 단어만 보고 재개 버튼을 열면 이미 멈춘 키퍼를 재개 가능으로 그린다.
    it("flag 가 false 면 status='paused' 만으로 재개를 권하지 않는다", () => {
      const k = makeKeeper({ status: 'paused', phase: null, paused: false })
      expect(keeperActionVisibility(k).canResume).toBe(false)
    })

    it('detects paused via pipeline_stage even if status is active', () => {
      const k = makeKeeper({
        status: 'active',
        phase: 'Running',
        paused: false,
        pipeline_stage: 'paused',
      })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canPause).toBe(false)
      expect(v.canWake).toBe(false)
    })

    it('does not show wake while paused even if a recoverable blocker is latched', () => {
      const k = makeKeeper({
        status: 'active',
        phase: 'Paused',
        paused: true,
        runtime_blocker_class: 'stale_turn_timeout',
      })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canWake).toBe(false)
    })
  })

  describe('paused keeper whose fiber died (keepalive_running=false)', () => {
    it('exposes resume before boot because the durable generation is the owner nonce', () => {
      const k = makeKeeper({ status: 'active', phase: 'Paused', paused: true, keepalive_running: false })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canBoot).toBe(false)
      expect(v.canPause).toBe(false)
      expect(v.canShutdown).toBe(true)
    })

    it('still exposes resume when phase is null but the paused flag lingers', () => {
      const k = makeKeeper({ status: 'active', phase: null, paused: true, keepalive_running: false })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canBoot).toBe(false)
    })
  })

  describe('offline keeper', () => {
    it('can boot, cannot pause or resume or shutdown', () => {
      const k = makeKeeper({ status: 'offline', phase: 'Offline', paused: false })
      const v = keeperActionVisibility(k)
      expect(v.canBoot).toBe(true)
      expect(v.canPause).toBe(false)
      expect(v.canResume).toBe(false)
      expect(v.canShutdown).toBe(false)
    })
  })

  describe('stopped keeper', () => {
    it('can boot, cannot pause/resume/shutdown', () => {
      const k = makeKeeper({ status: 'offline', phase: 'Stopped', paused: false })
      const v = keeperActionVisibility(k)
      expect(v.canBoot).toBe(true)
      expect(v.canPause).toBe(false)
      expect(v.canResume).toBe(false)
      expect(v.canShutdown).toBe(false)
    })
  })

  describe('stuck keeper (runtime_exhausted)', () => {
    it('can wake and is running so can pause/shutdown', () => {
      const k = makeKeeper({
        status: 'active',
        phase: 'Running',
        paused: false,
        runtime_blocker_class: 'runtime_exhausted',
      })
      const v = keeperActionVisibility(k)
      expect(v.canWake).toBe(true)
      expect(v.canPause).toBe(true)
    })
  })

  describe('restarting keeper', () => {
    it('stuck canWake is true', () => {
      const k = makeKeeper({ status: 'active', phase: 'Restarting', paused: false })
      const v = keeperActionVisibility(k)
      expect(v.canWake).toBe(true)
    })
  })
})

describe('runKeeperAction', () => {
  it('refreshes the shared runtime status source after a successful directive', async () => {
    vi.mocked(pauseKeeper).mockResolvedValueOnce({ ok: true })

    await runKeeperAction('rondo', 'pause')

    expect(applyOptimisticKeeperDirective).toHaveBeenCalledWith('rondo', 'pause')
    expect(refreshKeeperRuntimeStatus).toHaveBeenCalledWith()
  })

  it('routes a resume action to resumeKeeper by name alone', async () => {
    vi.mocked(resumeKeeper).mockResolvedValueOnce({ ok: true })

    await runKeeperAction('rondo', 'resume')

    expect(resumeKeeper).toHaveBeenCalledWith('rondo')
  })
})

describe('purge action', () => {
  beforeEach(() => {
    // Mock call counts accumulate across this file, and the assertions below
    // read the first recorded call.
    vi.clearAllMocks()
  })

  // Purge is permanent, so the button must not appear while the lane is
  // running — an operator has to shut the keeper down first.
  it('is offered for offline and paused keepers but not for a running one', () => {
    const running = makeKeeper({ status: 'active', phase: 'Running', paused: false })
    const paused = makeKeeper({ status: 'active', phase: 'Paused', paused: true })
    const offline = makeKeeper({
      status: 'offline',
      phase: 'Offline',
      paused: false,
      keepalive_running: false,
    })

    expect(keeperActionVisibility(running).canPurge).toBe(false)
    expect(keeperActionVisibility(paused).canPurge).toBe(true)
    expect(keeperActionVisibility(offline).canPurge).toBe(true)
  })

  it('does not call the endpoint when the confirmation is declined', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(false)

    await runKeeperAction('test', 'purge')

    expect(purgeKeeper).not.toHaveBeenCalled()
  })

  it('names every deleted store in the confirmation before calling the endpoint', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(true)

    await runKeeperAction('test', 'purge')

    expect(requestConfirm).toHaveBeenCalledTimes(1)
    const options = vi.mocked(requestConfirm).mock.calls[0]![0]!
    expect(options.tone).toBe('danger')
    expect(options.message).toContain('되돌릴 수 없습니다')
    expect(options.message).toContain('결정 로그')
    expect(options.message).toContain('대화 기록')
    expect(purgeKeeper).toHaveBeenCalledWith('test')
    expect(refreshKeeperRuntimeStatus).toHaveBeenCalled()
  })

  // The refresh fired right after the submit still returns the keeper, because
  // the server deletes asynchronously. Marking the name is what makes the
  // operator see the submit land instead of an unchanged row.
  it('marks the keeper pending so the row does not redraw unchanged', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(true)

    await runKeeperAction('test', 'purge')

    expect(markKeeperPurgePending).toHaveBeenCalledWith('test')
  })

  it('does not mark the keeper pending when the endpoint rejects', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(true)
    vi.mocked(purgeKeeper).mockRejectedValueOnce(new Error('nope'))

    await runKeeperAction('test', 'purge')

    expect(markKeeperPurgePending).not.toHaveBeenCalled()
  })

  it('surfaces the failure and does not refresh when the endpoint rejects', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(true)
    vi.mocked(purgeKeeper).mockRejectedValueOnce(new Error('keeper metadata unreadable'))

    await runKeeperAction('test', 'purge')

    expect(showToast).toHaveBeenCalledWith('keeper metadata unreadable', 'error')
    expect(refreshKeeperRuntimeStatus).not.toHaveBeenCalled()
  })
})

describe('purge pending never locks the control', () => {
  // A purge the server accepts and then fails to finish would otherwise leave
  // the row's only control disabled for good. The endpoint is idempotent, so a
  // repeat submit is safe and lets the operator re-check a stalled operation.
  it('keeps submitting possible while a purge is pending', async () => {
    vi.clearAllMocks()
    vi.mocked(requestConfirm).mockResolvedValue(true)

    await runKeeperAction('test', 'purge')
    await runKeeperAction('test', 'purge')

    expect(purgeKeeper).toHaveBeenCalledTimes(2)
  })
})
