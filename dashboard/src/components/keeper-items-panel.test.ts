import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import type { Keeper } from '../types'
import { EQUIPMENT_IDS } from '../api/schemas/keeper-portrait'

const fetchKeeperItems = vi.hoisted(() => vi.fn())
const portraitFailure = vi.hoisted(() => ({ value: false }))
const fetchDashboardExecution = vi.hoisted(() => vi.fn())
vi.mock('../api/dashboard-execution', () => ({ fetchDashboardExecution }))
vi.mock('../api/keeper-items', () => ({ fetchKeeperItems }))
vi.mock('./keeper-portrait', () => ({ KeeperPortrait: ({ previewItem, fallback }: { previewItem?: string; fallback: unknown }) => portraitFailure.value && previewItem
  ? fallback : html`<div data-testid="portrait" data-preview=${previewItem ?? ''} />` }))
vi.mock('./keeper-badge', () => ({ KeeperBadge: () => html`<div />` }))
vi.mock('../sse', () => ({ journal: { log: vi.fn() } }))

import { KeeperItemsPanel } from './keeper-items-panel'
import {
  executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration,
  resetExecutionSnapshotGeneration, serverStatus, refreshExecution,
} from '../store'
import { ApiRequestError, setStoredToken, clearStoredToken } from '../api/core'
import { parseKeeperItems, type KeeperItemsReading } from '../api/schemas/keeper-items'

const keeper = (name: string, head = 'crown') => ({ name, portrait: { state: 'ready', equipment: {
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
    status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: owned,
    catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: crownPrice } : item),
  }, 'rondo')
}

beforeEach(() => {
  fixtureEpoch = `item-workspace-fixture-${++fixtureEpochSequence}`
  fixtureGeneration = 0
  expect(invalidateExecutionSnapshotGeneration(fixtureEpoch, 0)).toBe(true)
  observeWorkspace('/fixture/workspace-a')
})

afterEach(() => { cleanup(); clearStoredToken(); vi.resetAllMocks(); vi.clearAllTimers(); vi.useRealTimers(); portraitFailure.value = false })

describe('Keeper Item tab', () => {
  it('reports a failed preview and lets the operator restore the observed portrait', async () => {
    fetchKeeperItems.mockResolvedValue(account(['crown'], '200'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    portraitFailure.value = true
    fireEvent.click(screen.getByRole('button', { name: 'beanie 미리보기' }))
    expect(screen.getByRole('alert').textContent).toContain('미리보기 그림을 불러오지 못했습니다')
    fireEvent.click(screen.getByRole('button', { name: '현재 착용 보기' }))
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByTestId('portrait').getAttribute('data-preview')).toBe('')
    expect(screen.getByText('보유 1 / 18개')).toBeTruthy()
    expect(screen.getByText('0.800 Candle')).toBeTruthy()
  })

  it('previews an unowned item and restores the observed outfit without refetching the wallet', async () => {
    fetchKeeperItems.mockResolvedValue(account(['crown'], '200'))
    const observed = keeper('rondo')
    render(html`<${KeeperItemsPanel} keeper=${observed} />`)
    await screen.findByText('보유 1 / 18개')
    fireEvent.click(screen.getByRole('button', { name: 'beanie 미리보기' }))
    expect(screen.getByTestId('portrait').getAttribute('data-preview')).toBe('beanie')
    expect(screen.getByText('미리보기 · beanie')).toBeTruthy()
    expect(screen.getByText('착용 중')).toBeTruthy()
    expect(observed.portrait?.state === 'ready' && observed.portrait.equipment.head).toBe('crown')
    fireEvent.click(screen.getByRole('button', { name: '현재 착용 보기' }))
    expect(screen.getByTestId('portrait').getAttribute('data-preview')).toBe('')
    expect(fetchKeeperItems).toHaveBeenCalledTimes(1)
  })

  it('withdraws a preview when the workspace account changes and requires an observed portrait', async () => {
    fetchKeeperItems.mockResolvedValue(account(['crown'], '200'))
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    fireEvent.click(screen.getByRole('button', { name: 'beanie 미리보기' }))
    await act(async () => { observeWorkspace('/fixture/workspace-b') })
    await screen.findByText('보유 1 / 18개')
    expect(screen.queryByText('미리보기 · beanie')).toBeNull()
    expect(screen.getByTestId('portrait').getAttribute('data-preview')).toBe('')
    view.rerender(html`<${KeeperItemsPanel} keeper=${{ ...keeper('rondo'), portrait: { state: 'unavailable', reason: 'ledger unavailable' } }} />`)
    await screen.findByText('보유 1 / 18개')
    expect(screen.getByRole('button', { name: 'beanie 미리보기' })).toHaveProperty('disabled', true)
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

  it('withdraws the visible account through execution warm-up and reads the recovered workspace', async () => {
    fetchKeeperItems.mockResolvedValueOnce(account(['crown'], '200'))
      .mockResolvedValueOnce(account(['crown', 'beanie'], '300'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    await screen.findByText('보유 1 / 18개')
    vi.useFakeTimers()
    fetchDashboardExecution.mockResolvedValue({ status: { project: 'initializing' } })
    await act(async () => { await refreshExecution({ immediate: true }) })
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
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    await waitFor(() => expect(fetchKeeperItems).toHaveBeenCalledTimes(2))
    const heldSignal = fetchKeeperItems.mock.calls[1]?.[1]
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
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
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
    fetchKeeperItems.mockResolvedValueOnce({ status: 'off', keeper: 'rondo' })
    await act(async () => { observeWorkspace('/fixture/workspace-a') })
    expect(executionWorkspaceAuthority.peek()).not.toBe(beforeReconnect)
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(4)
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

  it('shows observed balance, prices, ownership and equipment', async () => {
    fetchKeeperItems.mockResolvedValue({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    expect(screen.getByText('보유 1 / 18개')).toBeTruthy()
    expect(screen.getByText('착용 중')).toBeTruthy()
    expect(screen.getAllByText('가격 미설정').length).toBe(17)
    expect(screen.getByTestId('portrait')).toBeTruthy()
  })

  it('prints wallets beyond JavaScript safe integers exactly', async () => {
    fetchKeeperItems.mockResolvedValue({ status: 'ready', keeper: 'rondo', balance_milli: '9007199254740993', owned_items: [], catalog })
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('9,007,199,254,740.993 Candle')).toBeTruthy()
  })

  it('shows disabled and unreadable states without inventing an account', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'disabled', keeper: 'rondo', reason: 'bad policy' })
      .mockRejectedValueOnce(new Error('ledger unavailable'))
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Candle 설정을 사용할 수 없습니다: bad policy')
    fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
    expect(await screen.findByText(/ledger unavailable/)).toBeTruthy()
    expect(screen.queryByText(/Candle$/)).toBeNull()
  })

  it('does not show the previous Keeper account after switching', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'off', keeper: 'geek-scout' })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('geek-scout')} />`)
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
  })

  it('rereads ownership when the server-observed outfit changes', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
      .mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '600', owned_items: ['crown', 'beanie'], catalog })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('rondo', 'beanie')} />`)
    expect(await screen.findByText('0.600 Candle')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('rereads purchases when the server-observed wallet changes', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '600', owned_items: ['crown'], catalog })
    const view = render(html`<${KeeperItemsPanel} keeper=${{ ...keeper('rondo'), candle_balance_milli: '800' }} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${{ ...keeper('rondo'), candle_balance_milli: '600' }} />`)
    expect(await screen.findByText('0.600 Candle')).toBeTruthy()
    expect(screen.getByText('보유 1 / 18개')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('rereads a free purchase when ownership changes but wallet and outfit do not', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
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
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: [], catalog: repriced })
    const observed = (revision: string) => ({ ...keeper('rondo'), candle_balance_milli: '800', candle_account_revision: revision })
    const view = render(html`<${KeeperItemsPanel} keeper=${observed('a'.repeat(64))} />`)
    expect(await screen.findByText('0.200 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${observed('b'.repeat(64))} />`)
    expect(screen.queryByText('0.200 Candle')).toBeNull()
    expect(await screen.findByText('0.300 Candle')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })
})
