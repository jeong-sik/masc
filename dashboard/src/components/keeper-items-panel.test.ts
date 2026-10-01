import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import type { Keeper } from '../types'
import { EQUIPMENT_IDS } from '../api/schemas/keeper-portrait'

const fetchDashboardExecution = vi.hoisted(() => vi.fn())
vi.mock('../api/dashboard-execution', () => ({ fetchDashboardExecution }))
const fetchKeeperItems = vi.hoisted(() => vi.fn())
vi.mock('../api/keeper-items', () => ({ fetchKeeperItems }))
vi.mock('./keeper-portrait', () => ({ KeeperPortrait: () => html`<div data-testid="portrait" />` }))
vi.mock('./keeper-badge', () => ({ KeeperBadge: () => html`<div />` }))
const refreshExecution = vi.hoisted(() => vi.fn(async () => {}))
vi.mock('../store', async importOriginal => ({ ...await importOriginal<typeof import('../store')>(), refreshExecution }))
vi.mock('../sse', () => ({ journal: { log: vi.fn() } }))

import { KeeperItemsPanel } from './keeper-items-panel'
import {
  executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration,
  resetExecutionSnapshotGeneration, serverStatus,
} from '../store'
import { ApiRequestError, setStoredToken, clearStoredToken } from '../api/core'
import { parseKeeperItems, type KeeperItemsReading } from '../api/schemas/keeper-items'

const revisionA = 'a'.repeat(64)
const revisionB = 'b'.repeat(64)
const keeper = (name: string, head = 'crown', revision: string | null = revisionA) => ({ name, candle_account_revision: revision, portrait: { state: 'ready', equipment: {
  face: 'bare_face', neck: 'bare_neck', head, hand: 'empty_hand', base: 'no_dish',
} } }) as Keeper
const catalog = Object.entries(EQUIPMENT_IDS).flatMap(([slot, ids]) =>
  ids.slice(1).map(id => ({ id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced', ...(id === 'crown' ? { price_milli: '200' } : {}) })),
)

let fixtureEpoch = ''
let fixtureEpochSequence = 0
let fixtureGeneration = 0
let fixtureConnectionGeneration = 0
function observeWorkspace(root: unknown, includeRoot = true) {
  expect(hydrateExecutionSnapshot({
    execution_publication_epoch: fixtureEpoch,
    execution_publication_generation: ++fixtureGeneration,
    // Deliberately identical project label across distinct canonical roots.
    status: { project: 'same-project', ...(includeRoot ? { workspace_root: root } : {}) },
  } as Parameters<typeof hydrateExecutionSnapshot>[0], {
    requestGeneration: fixtureConnectionGeneration,
  })).toBe(true)
}
function pendingAccount() {
  let resolve!: (account: KeeperItemsReading) => void
  let reject!: (error: Error) => void
  const promise = new Promise<KeeperItemsReading>((done, fail) => { resolve = done; reject = fail })
  return { promise, resolve, reject }
}
function account(owned: string[], crownPrice: string) {
  return parseKeeperItems({
    status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: owned,
    catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: crownPrice } : item),
  }, 'rondo')
}

beforeEach(() => {
  fixtureEpoch = `item-workspace-fixture-${++fixtureEpochSequence}`
  fixtureGeneration = 0
  expect(invalidateExecutionSnapshotGeneration(fixtureEpoch, 0)).toBe(true)
  observeWorkspace('/fixture/workspace-a')
})

afterEach(() => { cleanup(); clearStoredToken(); vi.resetAllMocks(); vi.clearAllTimers(); vi.useRealTimers() })

describe('Keeper Item tab', () => {
  it('withdraws the visible account through execution warm-up and reads the recovered workspace', async () => {
    const { refreshExecution: actualRefreshExecution } = await vi.importActual<typeof import('../store')>('../store')
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockResolvedValueOnce(account(['crown', 'beanie'], '300'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    vi.useFakeTimers()
    fetchDashboardExecution.mockResolvedValue({ status: { project: 'initializing' } })
    await act(async () => { await expect(actualRefreshExecution({ immediate: true })).rejects.toThrow('initializing') })
    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(executionWorkspaceAuthority.peek()).toBeNull()
    expect(screen.getByRole('status').textContent).toBe('현재 작업 공간을 확인하는 중…')
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    expect(screen.queryByText('보유 1 / 18개')).toBeNull()
    expect(screen.queryByTestId('portrait')).toBeNull()
    vi.useRealTimers()
    await act(async () => { observeWorkspace('/fixture/workspace-a') })
    expect(await screen.findByText('보유 2 / 18개')).toBeTruthy()
    expect(screen.getByText('0.300 Candle')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('withdraws old accounts and rejects old-token replies without a WebSocket', async () => {
    const oldTokenRead = pendingAccount()
    const loggedOutRead = pendingAccount()
    const replacementRead = pendingAccount()
    setStoredToken('fixture-token-a')
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockReturnValueOnce(oldTokenRead.promise)
      .mockReturnValueOnce(loggedOutRead.promise)
      .mockReturnValueOnce(replacementRead.promise)
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('보유 1 / 18개')).toBeTruthy()
    const workspace = executionWorkspaceAuthority.peek()
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(2))
    await act(async () => {
      clearStoredToken()
      // Resolve before effect cleanup: token admission must reject this reply.
      oldTokenRead.resolve(account(['crown', 'beanie', 'book'], '900'))
      await oldTokenRead.promise
    })
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(3))
    expect(executionWorkspaceAuthority.peek()).toBe(workspace)
    expect(screen.queryByText(/보유/)).toBeNull()
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    await act(async () => { setStoredToken('fixture-token-b') })
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(4))
    await act(async () => {
      loggedOutRead.reject(new Error('previous credential failure'))
      await loggedOutRead.promise.catch(() => {})
    })
    expect(screen.queryByRole('alert')).toBeNull()
    await act(async () => { replacementRead.resolve(account(['book'], '400')) })
    expect(await screen.findByText('0.400 Candle')).toBeTruthy()
    expect(screen.queryByText('0.900 Candle')).toBeNull()
  })

  it('withdraws accounts across same-project A/B/A and refuses the first A read after returning', async () => {
    const firstARefresh = pendingAccount()
    const returningA = pendingAccount()
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockReturnValueOnce(firstARefresh.promise)
      .mockResolvedValueOnce(account(['crown', 'beanie'], '300'))
      .mockReturnValueOnce(returningA.promise)
    // The very same Keeper object, wallet and outfit survive both transitions.
    const sameKeeper = { ...keeper('rondo'), candle_balance_milli: '800' }
    render(html`<${KeeperItemsPanel} keeper=${sameKeeper} />`)
    expect(await screen.findByText('보유 1 / 18개')).toBeTruthy()
    const firstAuthority = executionWorkspaceAuthority.peek()
    await act(async () => { observeWorkspace('/fixture/workspace-a') })
    expect(executionWorkspaceAuthority.peek()).toBe(firstAuthority)
    expect(fetchKeeperItems).toHaveBeenCalledTimes(1)
    expect(fetchKeeperItems.mock.calls[0]?.[1]).toBe('/fixture/workspace-a')
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(2))
    const heldSignal = fetchKeeperItems.mock.calls[1]?.[2]
    if (!(heldSignal instanceof AbortSignal)) throw new Error('Held Item request requires an AbortSignal')
    await act(async () => { observeWorkspace('/fixture/workspace-b') })
    expect(await screen.findByText('보유 2 / 18개')).toBeTruthy()
    expect(screen.getByText('0.300 Candle')).toBeTruthy()
    expect(screen.queryByText('0.200 Candle')).toBeNull()
    expect(heldSignal.aborted).toBe(true)
    await act(async () => { observeWorkspace('/fixture/workspace-a') })
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(4))
    expect(executionWorkspaceAuthority.peek()).not.toBe(firstAuthority)
    expect(screen.queryByText('보유 2 / 18개')).toBeNull()
    expect(screen.queryByText('0.300 Candle')).toBeNull()
    // Mock transport intentionally resolves despite AbortSignal: old A cannot
    // become authoritative merely because the current tuple names A again.
    await act(async () => { firstARefresh.resolve(account(['crown', 'beanie', 'book'], '900')) })
    expect(screen.queryByText('보유 3 / 18개')).toBeNull()
    expect(screen.getByRole('status').textContent).toBe('Item 계정 불러오는 중…')
    await act(async () => { returningA.resolve(account(['crown', 'beanie', 'book', 'mug'], '400')) })
    expect(await screen.findByText('보유 4 / 18개')).toBeTruthy()
    expect(screen.getByText('0.400 Candle')).toBeTruthy()
    expect(screen.getByText('0.800 Candle')).toBeTruthy()
  })

  it('does not admit retained display roots, stale failures or pre-reconnect requests', async () => {
    const held = pendingAccount()
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockReturnValueOnce(held.promise)
      .mockResolvedValueOnce(account(['crown', 'beanie'], '300'))
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('보유 1 / 18개')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(2))
    await act(async () => {
      observeWorkspace(undefined, false)
      // Reject before effect cleanup can abort the old request. Live authority
      // admission must discard this failure rather than display an old alert.
      held.reject(new Error('old workspace ledger failure'))
      await held.promise.catch(() => {})
    })
    expect(serverStatus.peek()?.workspace_root).toBe('/fixture/workspace-a')
    expect(executionWorkspaceAuthority.peek()).toBeNull()
    expect(screen.getByRole('status').textContent).toBe('현재 작업 공간을 확인하는 중…')
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.queryByText(/보유/)).toBeNull()
    for (const root of [null, 42, '', '   ']) {
      await act(async () => { observeWorkspace(root) })
      expect(executionWorkspaceAuthority.peek()).toBeNull()
      expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
    }
    await act(async () => { observeWorkspace('/fixture/workspace-a') })
    expect(await screen.findByText('보유 2 / 18개')).toBeTruthy()
    const beforeReconnect = executionWorkspaceAuthority.peek()!
    const staleConnectionGeneration = beforeReconnect.connectionGeneration
    await act(async () => { resetExecutionSnapshotGeneration() })
    expect(executionWorkspaceAuthority.peek()).toBeNull()
    expect(screen.queryByText('보유 2 / 18개')).toBeNull()
    expect(hydrateExecutionSnapshot({
      execution_publication_epoch: fixtureEpoch,
      execution_publication_generation: ++fixtureGeneration,
      status: { workspace_root: '/fixture/workspace-a' },
    }, { requestGeneration: staleConnectionGeneration })).toBe(false)
    fixtureConnectionGeneration = staleConnectionGeneration + 1
    fetchKeeperItems.mockResolvedValueOnce({ status: 'off', account_revision: null, keeper: 'rondo' })
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('rondo', 'crown', null)} />`)
    await act(async () => { observeWorkspace('/fixture/workspace-a') })
    expect(executionWorkspaceAuthority.peek()).not.toBe(beforeReconnect)
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(4)
  })

  it('shows observed balance, prices, ownership and equipment', async () => {
    fetchKeeperItems.mockResolvedValue({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    expect(screen.getByText('보유 1 / 18개')).toBeTruthy()
    expect(screen.getByText('착용 중')).toBeTruthy()
    expect(screen.getAllByText('가격 미설정').length).toBe(17)
    expect(screen.getByTestId('portrait')).toBeTruthy()
  })

  it('prints wallets beyond JavaScript safe integers exactly', async () => {
    fetchKeeperItems.mockResolvedValue({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '9007199254740993', owned_items: [], catalog })
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('9,007,199,254,740.993 Candle')).toBeTruthy()
  })

  it('shows disabled and unreadable states without inventing an account', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'disabled', account_revision: revisionA, keeper: 'rondo', reason: 'bad policy' })
      .mockRejectedValueOnce(new Error('ledger unavailable'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Candle 설정을 사용할 수 없습니다: bad policy')
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByText(/ledger unavailable/)).toBeTruthy()
    expect(screen.queryByText(/Candle$/)).toBeNull()
  })

  it('does not show the previous Keeper account after switching', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'off', account_revision: null, keeper: 'geek-scout' })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('geek-scout', 'crown', null)} />`)
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
  })

  it('rereads ownership when the server-observed outfit changes', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
      .mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '600', owned_items: ['crown', 'beanie'], catalog })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('rondo', 'beanie')} />`)
    expect(await screen.findByText('0.600 Candle')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('rereads purchases when the server-observed wallet changes', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '600', owned_items: ['crown'], catalog })
    const view = render(html`<${KeeperItemsPanel} keeper=${{ ...keeper('rondo'), candle_balance_milli: '800' }} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${{ ...keeper('rondo'), candle_balance_milli: '600' }} />`)
    expect(await screen.findByText('0.600 Candle')).toBeTruthy()
    expect(screen.getByText('보유 1 / 18개')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('accepts the latest naturally decayed balance under unchanged durable account facts', async () => {
    fetchKeeperItems.mockResolvedValue({ ...account([], '200'), balance_milli: '999' })
    render(html`<${KeeperItemsPanel} keeper=${{ ...keeper('rondo'), candle_balance_milli: '1000' }} />`)
    expect(await screen.findByText('0.999 Candle')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(1)
  })

  it('refuses pending B under observed A through price A/B/A, then admits an explicit refreshed A', async () => {
    const held = pendingAccount()
    fetchKeeperItems.mockReturnValueOnce(held.promise).mockResolvedValueOnce(account(['crown'], '200'))
    const observedA = keeper('rondo')
    const view = render(html`<${KeeperItemsPanel} keeper=${observedA} />`)
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(1))
    const changed = account(['crown'], '400')
    if (changed.status !== 'ready') throw new Error('Expected ready account')
    // HTTP read saw price B, but the roster never observed it before price A returned.
    await act(async () => { held.resolve({ ...changed, account_revision: revisionB }) })
    expect(await screen.findByRole('alert')).toHaveProperty('textContent',
      'Item 계정을 읽지 못했습니다: Item 계정 관측이 변경되었습니다. 새로고침으로 Keeper 관측을 갱신해주세요.')
    view.rerender(html`<${KeeperItemsPanel} keeper=${observedA} />`)
    expect(fetchKeeperItems).toHaveBeenCalledTimes(1)
    expect(screen.queryByText('0.400 Candle')).toBeNull()
    expect(screen.queryByText(/보유/)).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByText('0.200 Candle')).toBeTruthy()
    expect(refreshExecution).toHaveBeenCalledWith({ force: true })
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('refreshes the Keeper observation before accepting a changed current account', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ ...account([], '200'), account_revision: revisionB })
      .mockResolvedValue({ ...account(['crown'], '300'), account_revision: revisionB })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByRole('alert')
    refreshExecution.mockImplementationOnce(async () => {
      view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('rondo', 'crown', revisionB)} />`)
    })
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByText('0.300 Candle')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it.each(['ready', 'off', 'disabled'] as const)('withdraws loaded %s at the refresh click until execution completes', async status => {
    const value = status === 'ready' ? account(['crown'], '200')
      : status === 'off' ? { status: 'off' as const, account_revision: null, keeper: 'rondo' }
      : { status: 'disabled' as const, account_revision: revisionA, keeper: 'rondo', reason: 'bad policy' }
    const label = status === 'ready' ? '보유 1 / 18개'
      : status === 'off' ? 'Candle 기능이 꺼져 있습니다.' : 'Candle 설정을 사용할 수 없습니다: bad policy'
    fetchKeeperItems.mockResolvedValue(value)
    let release!: () => void
    const held = new Promise<void>(resolve => { release = resolve })
    refreshExecution.mockReturnValueOnce(held)
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo', 'crown', status === 'off' ? null : revisionA)} />`)
    await screen.findByText(label)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByText('Item 계정 불러오는 중…')).toBeTruthy()
    expect(screen.queryByText(label)).toBeNull()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', true)
    await act(async () => { release(); await held })
    expect(await screen.findByText(label)).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('withdraws all account states immediately while execution refresh is held and aborts the old read', async () => {
    let release!: () => void
    const execution = new Promise<void>(resolve => { release = resolve })
    const old = pendingAccount()
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockReturnValueOnce(old.promise).mockResolvedValueOnce(account(['crown', 'beanie'], '300'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(2))
    const signal = fetchKeeperItems.mock.calls[1]?.[2]
    if (!(signal instanceof AbortSignal)) throw new Error('Expected old Item signal')
    refreshExecution.mockReturnValueOnce(execution)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(signal.aborted).toBe(true))
    expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', true)
    expect(screen.queryByText(/보유/)).toBeNull()
    await act(async () => { old.resolve(account(['crown', 'beanie', 'book'], '900')) })
    expect(screen.getByRole('status').textContent).toBe('Item 계정 불러오는 중…')
    expect(screen.queryByText('0.900 Candle')).toBeNull()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
    await act(async () => { release(); await execution })
    expect(await screen.findByText('보유 2 / 18개')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(3)
    expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', false)
  })

  it('does not restore a loaded account after execution refresh rejects, and permits an explicit retry', async () => {
    fetchKeeperItems.mockResolvedValue(account(['crown'], '200'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    refreshExecution.mockRejectedValueOnce(new Error('observation unavailable'))
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByRole('alert')).toHaveProperty('textContent',
      'Item 계정을 읽지 못했습니다: observation unavailable')
    expect(screen.queryByText(/보유/)).toBeNull()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', false)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByText('보유 1 / 18개')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it.each(['success', 'failure'] as const)('keeps workspace B independent of held refresh A and late A %s', async outcome => {
    let finishA!: () => void
    let failA!: (error: Error) => void
    const heldA = new Promise<void>((resolve, reject) => { finishA = resolve; failA = reject })
    let finishB!: () => void
    const heldB = new Promise<void>(resolve => { finishB = resolve })
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockResolvedValueOnce(account(['crown', 'beanie'], '300'))
      .mockResolvedValueOnce(account(['crown', 'beanie', 'book'], '400'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    refreshExecution.mockReturnValueOnce(heldA).mockReturnValueOnce(heldB)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await screen.findByRole('status')
    await act(async () => { observeWorkspace('/fixture/workspace-b') })
    expect(await screen.findByText('보유 2 / 18개')).toBeTruthy()
    expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', false)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', true))
    await act(async () => {
      if (outcome === 'success') finishA()
      else failA(new Error('old A failure'))
      await heldA.catch(() => {})
    })
    expect(screen.getByRole('button', { name: '새로고침' })).toHaveProperty('disabled', true)
    expect(screen.getByRole('status').textContent).toBe('Item 계정 불러오는 중…')
    expect(screen.queryByRole('alert')).toBeNull()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
    await act(async () => { finishB(); await heldB })
    expect(await screen.findByText('보유 3 / 18개')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(3)
  })

  it('rereads a free purchase when ownership changes but wallet and outfit do not', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'ready', account_revision: revisionB, keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
    const observed = (revision: string) => ({ ...keeper('rondo'), candle_balance_milli: '800', candle_account_revision: revision })
    const view = render(html`<${KeeperItemsPanel} keeper=${observed('a'.repeat(64))} />`)
    expect(await screen.findByText('보유 0 / 18개')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${observed('b'.repeat(64))} />`)
    expect(screen.queryByText('보유 0 / 18개')).toBeNull()
    expect(await screen.findByText('보유 1 / 18개')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('rereads edited prices while ownership, wallet and outfit stay fixed', async () => {
    const repriced = catalog.map(item => item.id === 'crown' ? { ...item, price_milli: '300' } : item)
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', account_revision: revisionA, keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'ready', account_revision: revisionB, keeper: 'rondo', balance_milli: '800', owned_items: [], catalog: repriced })
    const observed = (revision: string) => ({ ...keeper('rondo'), candle_balance_milli: '800', candle_account_revision: revision })
    const view = render(html`<${KeeperItemsPanel} keeper=${observed('a'.repeat(64))} />`)
    expect(await screen.findByText('0.200 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${observed('b'.repeat(64))} />`)
    expect(screen.queryByText('0.200 Candle')).toBeNull()
    expect(await screen.findByText('0.300 Candle')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })
  it('adopts newer same-workspace account observations while an older refresh rejects', async () => {
    let reject!: (error: Error) => void
    const held = new Promise<void>((_, fail) => { reject = fail })
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockResolvedValueOnce({ ...account(['crown', 'beanie'], '300'), account_revision: revisionB })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    const authority = executionWorkspaceAuthority.peek()
    refreshExecution.mockReturnValueOnce(held)
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await screen.findByText('Item 계정 불러오는 중…')
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('rondo', 'crown', revisionB)} />`)
    expect(executionWorkspaceAuthority.peek()).toBe(authority)
    expect(await screen.findByText('보유 2 / 18개')).toBeTruthy()
    await act(async () => { reject(new Error('superseded old refresh')); await held.catch(() => {}) })
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByText('보유 2 / 18개')).toBeTruthy()
  })

  it('shows the server request reason without an internal endpoint and supports missing detail', async () => {
    fetchKeeperItems.mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/api/v1/keepers/rondo/items', status: 503, detail: 'ledger unreadable' }))
      .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/api/v1/keepers/rondo/items', status: 503 }))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Item 계정을 읽지 못했습니다: ledger unreadable')
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await screen.findByText('Item 계정을 읽지 못했습니다: 계정 요청에 실패했습니다. 다시 시도해주세요.')
    expect(screen.queryByText(/\/api\//)).toBeNull()
  })

})
