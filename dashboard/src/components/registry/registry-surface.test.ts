import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { h, render } from 'preact'

import type { Keeper, RouteState } from '../../types'
import { buildCompositeByKeeperKey } from '../../composite-signals'

const mocks = await vi.hoisted(async () => {
  const { signal } = await import('@preact/signals')
  return {
    route: signal<RouteState>({ tab: 'registry', params: {}, postId: null }),
    keepers: signal<readonly Keeper[]>([]),
    openKeeperDetail: vi.fn(),
  }
})

vi.mock('../../router', () => ({ route: mocks.route, navigate: vi.fn() }))
vi.mock('../../store', () => ({ keepers: mocks.keepers }))
vi.mock('../keeper-detail-state', () => ({ openKeeperDetail: mocks.openKeeperDetail }))
vi.mock('../keeper-detail-page', () => ({
  KeeperDetailPage: () => h('div', { 'data-testid': 'keeper-detail-page' }, 'KeeperDetailPage'),
}))
vi.mock('../keeper-spawn/persona-browser', () => ({
  PersonaBrowser: () => h('div', { 'data-testid': 'persona-browser' }, 'PersonaBrowser'),
}))
vi.mock('../keeper-badge', () => ({
  KeeperBadge: ({ id }: { id: string }) => h('span', { 'data-testid': 'keeper-badge' }, id),
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

  // Registry owns persona writes. A read-only persona list here would recreate
  // the split that kept create/edit/delete on a separate route.
  it('mounts the persona browser so create/edit/delete live on this route', () => {
    render(h(RegistrySurface, null), container)
    expect(container.querySelector('[data-testid="persona-browser"]')).not.toBeNull()
  })

  it('puts personas first and keeps keeper instances in a collapsed details block', () => {
    mocks.keepers.value = [keeper({ name: 'alpha' })]
    render(h(RegistrySurface, null), container)

    const details = container.querySelector<HTMLDetailsElement>('details.reg-keepers')
    expect(details).not.toBeNull()
    expect(details!.open).toBe(false)
    expect(details!.textContent).toContain('Keeper 인스턴스')
    // Persona layer precedes the keeper instance block in document order.
    const personas = container.querySelector('.reg-personas')
    expect(personas).not.toBeNull()
    expect(
      personas!.compareDocumentPosition(details!) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy()
    // Canonical group labels from KEEPER_STATUS_LABEL_KO.
    expect(details!.textContent).toContain('실행 중')
    expect(details!.textContent).not.toContain('차단 · 확인 필요')
    expect(details!.textContent).not.toContain('중지 · 미기동')
  })

  it('opens keeper detail from a roster row instead of reimplementing update/delete', () => {
    const target = keeper({ name: 'alpha' })
    mocks.keepers.value = [target]
    render(h(RegistrySurface, null), container)

    const row = container.querySelector<HTMLButtonElement>('[data-testid="registry-keeper-open"]')
    expect(row).not.toBeNull()
    row!.click()

    expect(mocks.openKeeperDetail).toHaveBeenCalledTimes(1)
    expect(mocks.openKeeperDetail).toHaveBeenCalledWith(target)
  })

  it('renders keeper detail in place when the route carries a keeper param', () => {
    mocks.route.value = { tab: 'registry', params: { keeper: 'alpha' }, postId: null }
    render(h(RegistrySurface, null), container)

    expect(container.querySelector('[data-testid="keeper-detail-page"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="persona-browser"]')).toBeNull()
  })
})
