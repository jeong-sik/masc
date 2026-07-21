import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
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

describe('keeper detail state import boundary', () => {
  it('preloads keeper config without importing the config panel UI module', () => {
    const source = readFileSync(resolve(__dirname, 'keeper-detail-state.ts'), 'utf8')

    expect(source).toContain("from './keeper-config-state'")
    expect(source).not.toContain("from './keeper-config-panel'")
  })
})

// Registry hosts a keeper roster that drills into the shared detail page. If the
// return route were not tab-aware, opening a keeper from Registry would strand
// the operator on Monitoring — the route they did not come from.
describe('detail route is anchored to the route it was opened from', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('keeps registry as the host tab when opening a keeper', () => {
    mocks.route.value = { tab: 'registry', params: {}, postId: null }
    openKeeperDetail(keeper('alpha'))
    expect(mocks.navigate).toHaveBeenCalledWith('registry', { keeper: 'alpha' })
  })

  it('returns to registry, without the keeper param, on close', () => {
    mocks.route.value = { tab: 'registry', params: { keeper: 'alpha' }, postId: null }
    closeKeeperDetail()
    expect(mocks.navigate).toHaveBeenCalledWith('registry', {})
  })

  it('still anchors the keepers tab', () => {
    mocks.route.value = { tab: 'keepers', params: {}, postId: null }
    openKeeperDetail(keeper('beta'))
    expect(mocks.navigate).toHaveBeenCalledWith('keepers', { keeper: 'beta' })
  })

  it('falls back to the monitoring agent directory from unrelated tabs', () => {
    mocks.route.value = { tab: 'board', params: {}, postId: null }
    openKeeperDetail(keeper('gamma'))
    expect(mocks.navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'gamma' })
  })
})
