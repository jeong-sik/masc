import { describe, it, expect, vi } from 'vitest'

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
vi.mock('../store', () => ({
  keepers: { value: [] },
  applyOptimisticKeeperDirective: vi.fn(() => () => {}),
  refreshKeeperRuntimeStatus: vi.fn(async () => undefined),
}))

import { pauseKeeper } from '../api/keeper'
import { keeperActionVisibility } from '../lib/keeper-predicates'
import { applyOptimisticKeeperDirective, refreshKeeperRuntimeStatus } from '../store'
import { runKeeperAction } from './keeper-action-panel'
import type { Keeper } from '../types'

function makeKeeper(overrides: Partial<Keeper>): Keeper {
  return {
    name: 'test',
    status: 'active',
    phase: 'Running',
    paused: false,
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

    it('detects paused via status even if phase is missing', () => {
      const k = makeKeeper({ status: 'paused', phase: null, paused: false })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canPause).toBe(false)
      expect(v.canWake).toBe(false)
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
        runtime_blocker_class: 'turn_timeout',
      })
      const v = keeperActionVisibility(k)
      expect(v.canResume).toBe(true)
      expect(v.canWake).toBe(false)
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

  describe('dead keeper', () => {
    it('can boot, cannot pause/resume/shutdown', () => {
      const k = makeKeeper({ status: 'offline', phase: 'Dead', paused: false })
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
    expect(refreshKeeperRuntimeStatus).toHaveBeenCalledWith({ force: true })
  })
})
