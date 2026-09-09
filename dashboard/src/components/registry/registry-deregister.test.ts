import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { h, render } from 'preact'

import type { Keeper } from '../../types'
import { deriveKeeperOperationalState } from '../../lib/keeper-operational-state'

const mocks = await vi.hoisted(async () => ({
  purgeKeeper: vi.fn(),
  shutdownKeeper: vi.fn(),
  showToast: vi.fn(),
  markKeeperPurgePending: vi.fn(),
  refreshKeeperDeletions: vi.fn(async () => undefined),
}))

vi.mock('../../api/keeper-lifecycle', () => ({
  purgeKeeper: mocks.purgeKeeper,
  KEEPER_PURGE_ARTIFACTS: ['설정', '대화 기록'],
  shutdownKeeper: mocks.shutdownKeeper,
}))
vi.mock('../../store', () => ({ markKeeperPurgePending: mocks.markKeeperPurgePending, refreshKeeperDeletions: mocks.refreshKeeperDeletions }))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../keeper-badge', () => ({
  KeeperBadge: ({ id }: { id: string }) => h('span', { 'data-testid': 'keeper-badge' }, id),
}))

const { RegistryDeregister, deregisterStopsRunningKeeper } = await import('./registry-deregister')

function keeper(overrides: Partial<Keeper> = {}): Keeper {
  return { name: 'alpha', status: 'idle', ...overrides }
}

function stateFor(k: Keeper) {
  return deriveKeeperOperationalState({ keeper: k, composite: null })
}

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('deregisterStopsRunningKeeper', () => {
  it('requires drain for running and stuck keepers only', () => {
    expect(deregisterStopsRunningKeeper(stateFor(keeper()))).toBe(true)
    expect(deregisterStopsRunningKeeper(stateFor(keeper({ runtime_blocker_class: 'runtime_exhausted' })))).toBe(true)
    expect(deregisterStopsRunningKeeper(stateFor(keeper({ paused: true })))).toBe(false)
    expect(deregisterStopsRunningKeeper(stateFor(keeper({ phase: 'Offline' })))).toBe(false)
  })
})

describe('RegistryDeregister', () => {
  let container: HTMLDivElement
  let onClose: () => void
  let onCloseCalls: number

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    onCloseCalls = 0
    onClose = () => { onCloseCalls += 1 }
    vi.clearAllMocks()
    mocks.purgeKeeper.mockResolvedValue({ ok: true, accepted: true, operation_id: 'op-1' })
    mocks.shutdownKeeper.mockResolvedValue({ ok: true })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('purges a stopped keeper directly without drain', async () => {
    const k = keeper({ phase: 'Offline' })
    render(h(RegistryDeregister, { keeper: k, state: stateFor(k), onClose }), container)

    expect(container.querySelector('.reg-confirm-warn')).toBeNull()
    expect(container.querySelector('.reg-confirm-msg')?.textContent).toContain('alpha')

    container.querySelector<HTMLButtonElement>('[data-testid="registry-deregister-submit"]')!.click()
    await flush()

    expect(mocks.shutdownKeeper).not.toHaveBeenCalled()
    expect(mocks.purgeKeeper).toHaveBeenCalledWith('alpha')
    expect(mocks.markKeeperPurgePending).toHaveBeenCalledWith('alpha')
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('op-1'), 'success')
    expect(onCloseCalls).toBe(1)
  })

  it('submits one purge operation that owns running Keeper shutdown', async () => {
    const k = keeper()
    render(h(RegistryDeregister, { keeper: k, state: stateFor(k), onClose }), container)

    expect(container.querySelector('.reg-confirm-warn .cw-txt')?.textContent).toContain('실행 중')

    container.querySelector<HTMLButtonElement>('[data-testid="registry-deregister-drain"]')!.click()
    await flush()

    expect(mocks.shutdownKeeper).not.toHaveBeenCalled()
    expect(mocks.purgeKeeper).toHaveBeenCalledWith('alpha')
    expect(onCloseCalls).toBe(1)
  })

  it('stays open and reports when purge admission fails', async () => {
    mocks.purgeKeeper.mockRejectedValue(new Error('busy lane'))
    const k = keeper()
    render(h(RegistryDeregister, { keeper: k, state: stateFor(k), onClose }), container)

    container.querySelector<HTMLButtonElement>('[data-testid="registry-deregister-drain"]')!.click()
    await flush()

    expect(mocks.purgeKeeper).toHaveBeenCalledWith('alpha')
    expect(mocks.showToast).toHaveBeenCalledWith('busy lane', 'error')
    expect(onCloseCalls).toBe(0)
  })

  it('closes on Escape and on the dismiss button', async () => {
    const k = keeper({ phase: 'Offline' })
    render(h(RegistryDeregister, { keeper: k, state: stateFor(k), onClose }), container)
    await flush()

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(onCloseCalls).toBe(1)

    container.querySelector<HTMLButtonElement>('.reg-dlg-x')!.click()
    expect(onCloseCalls).toBe(2)
  })
})
