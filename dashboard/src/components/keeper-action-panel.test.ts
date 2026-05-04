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
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
}))

import { keeperActionVisibility } from './keeper-action-panel'
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

  describe('stuck keeper (cascade_exhausted)', () => {
    it('can wake and is running so can pause/shutdown', () => {
      const k = makeKeeper({
        status: 'active',
        phase: 'Running',
        paused: false,
        runtime_blocker_class: 'cascade_exhausted',
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
