import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'

import type { Keeper, RouteState } from '../../types'
import { buildCompositeByKeeperKey } from '../../composite-signals'

const mocks = await vi.hoisted(async () => {
  const { signal } = await import('@preact/signals')
  return {
    route: signal<RouteState>({ tab: 'registry', params: {}, postId: null }),
    keepers: signal<readonly Keeper[]>([]),
    openKeeperDetail: vi.fn(),
    navigate: vi.fn(),
  }
})

vi.mock('../../router', () => ({ route: mocks.route, navigate: mocks.navigate }))
vi.mock('../../store', () => ({ keepers: mocks.keepers }))
vi.mock('../keeper-detail-state', () => ({ openKeeperDetail: mocks.openKeeperDetail }))
vi.mock('../keeper-detail-page', () => ({
  KeeperDetailPage: () => h('div', { 'data-testid': 'keeper-detail-page' }, 'KeeperDetailPage'),
}))
vi.mock('../keeper-badge', () => ({
  KeeperBadge: ({ id }: { id: string }) => h('span', { 'data-testid': 'keeper-badge' }, id),
}))
vi.mock('./registry-deregister', () => ({
  RegistryDeregister: ({ keeper }: { keeper: Keeper }) =>
    h('div', { 'data-testid': 'registry-deregister' }, keeper.name),
  deregisterNeedsDrain: () => false,
}))
vi.mock('../../composite-signals', async importActual => {
  const actual = await importActual<typeof import('../../composite-signals')>()
  const { signal } = await import('@preact/signals')
  return { ...actual, fleetCompositeSnapshot: signal(null) }
})

const { RegistrySurface, groupRegistryKeepers, keeperGroup } = await import('./registry-surface')

function keeper(overrides: Partial<Keeper> = {}): Keeper {
  return { name: 'keeper', status: 'idle', ...overrides }
}

describe('keeperGroup', () => {
  it('projects the canonical operational-state variants without a parallel lifecycle heuristic', () => {
    expect(keeperGroup(keeper(), null)).toBe('running')
    expect(keeperGroup(keeper({ paused: true }), null)).toBe('paused')
    expect(keeperGroup(keeper({ status: 'unbooted' }), null)).toBe('offline')
    expect(keeperGroup(keeper({ runtime_blocker_class: 'runtime_exhausted' }), null)).toBe('stuck')
  })
})

describe('groupRegistryKeepers', () => {
  it('places every keeper in exactly one group', () => {
    const roster = [
      keeper({ name: 'running' }),
      keeper({ name: 'paused', paused: true }),
      keeper({ name: 'offline', status: 'unbooted' }),
      keeper({ name: 'stuck', runtime_blocker_class: 'runtime_exhausted' }),
    ]
    const grouped = groupRegistryKeepers(roster, buildCompositeByKeeperKey(null))
    const names = Object.values(grouped).flatMap(rows => rows.map(row => row.keeper.name))

    expect(names.sort()).toEqual(roster.map(row => row.name).sort())
    expect(new Set(names).size).toBe(roster.length)
  })
})

describe('RegistrySurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.route.value = { tab: 'registry', params: {}, postId: null }
    mocks.keepers.value = []
    vi.clearAllMocks()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the design surface chrome (header + concept spine)', () => {
    mocks.keepers.value = [keeper({ name: 'alpha' })]
    render(h(RegistrySurface, null), container)

    expect(container.querySelector('.reg-head .reg-eyebrow')?.textContent).toBe('레지스트리')
    expect(container.querySelector('.reg-sub')).not.toBeNull()
    const stations = container.querySelectorAll('.reg-spine .reg-station')
    expect(stations.length).toBe(3)
    expect(container.querySelector('.reg-station.idea .rs-name')?.textContent).toBe('프롬프트 파일')
    expect(container.querySelectorAll('.reg-spine .reg-arrow').length).toBe(2)
  })

  it('renders keepers on the design card vocabulary', () => {
    mocks.keepers.value = [
      keeper({ name: 'alpha', agent_name: 'resource-agent', runtime_canonical: 'ollama.gemma4' }),
    ]
    render(h(RegistrySurface, null), container)

    const registry = container.querySelector('.reg-keepers')
    expect(registry).not.toBeNull()
    // Canonical group labels from KEEPER_STATUS_LABEL_KO.
    expect(registry!.textContent).toContain('실행 중')
    expect(registry!.textContent).not.toContain('차단 · 확인 필요')
    expect(registry!.textContent).not.toContain('중지 · 미기동')

    const card = container.querySelector('.reg-kgrid .reg-keeper')
    expect(card).not.toBeNull()
    expect(card!.querySelector('.rk-top .rk-id .rk-name')?.textContent).toBe('alpha')
    expect(card!.querySelector('.rk-facet.prov .rk-f-val')?.textContent).toBe('resource-agent')
    expect(card!.querySelector('.rk-facet.rt .rk-f-val')?.textContent).toBe('ollama.gemma4')
    expect(container.querySelector('.reg-panel-h .rp-count')?.textContent).toBe('1')
  })

  it('falls back to 직접 정의 when the keeper carries no agent_name', () => {
    mocks.keepers.value = [keeper({ name: 'alpha' })]
    render(h(RegistrySurface, null), container)

    expect(container.querySelector('.rk-facet.prov .rk-f-val')?.textContent).toBe('직접 정의')
  })

  it('shows the design empty state when the roster is empty', () => {
    render(h(RegistrySurface, null), container)

    expect(container.querySelector('.reg-empty')).not.toBeNull()
    expect(container.querySelector('.reg-kgroup')).toBeNull()
  })

  it('opens keeper detail from the card menu instead of reimplementing update/delete', () => {
    const target = keeper({ name: 'alpha' })
    mocks.keepers.value = [target]
    render(h(RegistrySurface, null), container)

    fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-menu"]')!)
    const open = container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-open"]')
    expect(open).not.toBeNull()
    fireEvent.click(open!)

    expect(mocks.openKeeperDetail).toHaveBeenCalledTimes(1)
    expect(mocks.openKeeperDetail).toHaveBeenCalledWith(target)
  })

  it('navigates to the keeper chat from the card menu', () => {
    mocks.keepers.value = [keeper({ name: 'alpha' })]
    render(h(RegistrySurface, null), container)

    fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-menu"]')!)
    fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-chat"]')!)

    expect(mocks.navigate).toHaveBeenCalledWith('keepers', { keeper: 'alpha' })
  })

  it('opens the deregister dialog from the card menu', () => {
    mocks.keepers.value = [keeper({ name: 'alpha' })]
    render(h(RegistrySurface, null), container)

    expect(container.querySelector('[data-testid="registry-deregister"]')).toBeNull()
    fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-menu"]')!)
    fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-deregister"]')!)

    const dialog = container.querySelector('[data-testid="registry-deregister"]')
    expect(dialog).not.toBeNull()
    expect(dialog!.textContent).toContain('alpha')
  })

  it('renders keeper detail in place when the route carries a keeper param', () => {
    mocks.route.value = { tab: 'registry', params: { keeper: 'alpha' }, postId: null }
    render(h(RegistrySurface, null), container)

    expect(container.querySelector('[data-testid="keeper-detail-page"]')).not.toBeNull()
  })
})
