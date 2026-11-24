import { describe, expect, it, beforeEach, vi } from 'vitest'

import type { Keeper, RouteState } from '../types'

const mocks = await vi.hoisted(async () => {
  const { signal } = await import('@preact/signals')
  return {
    route: signal<RouteState>({ tab: 'monitoring', params: {}, postId: null }),
    navigate: vi.fn(),
    selectKeeper: vi.fn(),
    hydrateKeeperStatus: vi.fn(),
    loadKeeperConfig: vi.fn(),
    resetKeeperConfig: vi.fn(),
  }
})

vi.mock('../router', () => ({ route: mocks.route, navigate: mocks.navigate }))
vi.mock('../keeper-actions', () => ({
  selectKeeper: mocks.selectKeeper,
  hydrateKeeperStatus: mocks.hydrateKeeperStatus,
}))
vi.mock('../keeper-state', async () => {
  const { signal } = await import('@preact/signals')
  return { activeKeeperName: signal('') }
})
vi.mock('../sse-store', () => ({ registerKeeperTurnRefresh: vi.fn() }))
vi.mock('./keeper-config-state', () => ({
  loadKeeperConfig: mocks.loadKeeperConfig,
  resetKeeperConfig: mocks.resetKeeperConfig,
}))

const { openKeeperDetail, closeKeeperDetail } = await import('./keeper-detail-state')

function keeper(name: string): Keeper {
  return { name, status: 'idle' } as Keeper
}

describe('detail route is anchored to the route it was opened from', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('still anchors the keepers tab', () => {
    mocks.route.value = { tab: 'keepers', params: {}, postId: null }
    openKeeperDetail(keeper('beta'))
    expect(mocks.navigate).toHaveBeenCalledWith('keepers', { keeper: 'beta' })
  })

  it('returns to keepers, without the keeper param, on close', () => {
    mocks.route.value = { tab: 'keepers', params: { keeper: 'beta' }, postId: null }
    closeKeeperDetail()
    expect(mocks.navigate).toHaveBeenCalledWith('keepers', {})
  })

  it('falls back to the monitoring agent directory from unrelated tabs', () => {
    mocks.route.value = { tab: 'board', params: {}, postId: null }
    openKeeperDetail(keeper('gamma'))
    expect(mocks.navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'gamma' })
  })
})
