import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { Keeper } from '../types'

const mocks = vi.hoisted(() => ({
  loadKeeperConfig: vi.fn(async () => {}),
  resetKeeperConfig: vi.fn(),
  selectKeeper: vi.fn(),
}))

vi.mock('./keeper-config-panel', async () => {
  const actual = await vi.importActual<typeof import('./keeper-config-panel')>('./keeper-config-panel')
  return {
    ...actual,
    KeeperConfigPanel: () => null,
    loadKeeperConfig: mocks.loadKeeperConfig,
    resetKeeperConfig: mocks.resetKeeperConfig,
  }
})

vi.mock('../keeper-runtime', () => ({
  selectKeeper: mocks.selectKeeper,
}))

import {
  closeKeeperDetail,
  openKeeperDetail,
  selectedKeeper,
} from './keeper-detail'

describe('openKeeperDetail', () => {
  beforeEach(() => {
    selectedKeeper.value = null
    mocks.loadKeeperConfig.mockClear()
    mocks.resetKeeperConfig.mockClear()
    mocks.selectKeeper.mockClear()
  })

  it('selects the keeper and preloads config on modal open', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    openKeeperDetail(keeper)

    expect(selectedKeeper.value).toEqual(keeper)
    expect(mocks.selectKeeper).toHaveBeenCalledWith('sangsu')
    expect(mocks.loadKeeperConfig).toHaveBeenCalledWith('sangsu')
  })

  it('resets modal-local state on close', () => {
    const keeper: Keeper = {
      name: 'sangsu',
      status: 'active',
    }

    openKeeperDetail(keeper)
    closeKeeperDetail()

    expect(selectedKeeper.value).toBeNull()
    expect(mocks.resetKeeperConfig).toHaveBeenCalledTimes(1)
  })
})
