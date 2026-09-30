import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import type { Keeper } from '../types'
import { EQUIPMENT_IDS } from '../api/schemas/keeper-portrait'

const fetchKeeperItems = vi.hoisted(() => vi.fn())
vi.mock('../api/keeper-items', () => ({ fetchKeeperItems }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  return { executionWorkspaceRevision: signal(0), serverStatus: signal(null) }
})
vi.mock('./keeper-portrait', () => ({ KeeperPortrait: () => html`<div data-testid="portrait" />` }))
vi.mock('./keeper-badge', () => ({ KeeperBadge: () => html`<div />` }))

import { KeeperItemsPanel } from './keeper-items-panel'
import { executionWorkspaceRevision, serverStatus } from '../store'

const keeper = (name: string, head = 'crown') => ({ name, portrait: { state: 'ready', equipment: {
  face: 'bare_face', neck: 'bare_neck', head, hand: 'empty_hand', base: 'no_dish',
} } }) as Keeper
const catalog = Object.entries(EQUIPMENT_IDS).flatMap(([slot, ids]) =>
  ids.slice(1).map(id => ({ id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced', ...(id === 'crown' ? { price_milli: '200' } : {}) })),
)

afterEach(() => { cleanup(); vi.resetAllMocks(); executionWorkspaceRevision.value = 0; serverStatus.value = null })

describe('Keeper Item tab', () => {
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
  it('rejects an old workspace response for an otherwise identical Keeper', async () => {
    let finishOld!: (value: unknown) => void
    fetchKeeperItems.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
      .mockResolvedValueOnce({ status: 'off', keeper: 'rondo' })
    serverStatus.value = { project: 'A' }
    const unchanged = keeper('rondo')
    const view = render(html`<${KeeperItemsPanel} keeper=${unchanged} />`)
    await act(async () => {})
    await act(async () => {
      serverStatus.value = { project: 'B' }
      executionWorkspaceRevision.value += 1
      view.rerender(html`<${KeeperItemsPanel} keeper=${unchanged} />`)
    })
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
    await act(async () => {
      finishOld({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog })
    })
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    expect(screen.getByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
    expect(fetchKeeperItems).toHaveBeenCalledTimes(2)
  })

  it('invalidates the same project when its publication authority changes', async () => {
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: [], catalog })
      .mockResolvedValueOnce({ status: 'off', keeper: 'rondo' })
    serverStatus.value = { project: 'A' }
    const unchanged = keeper('rondo')
    const view = render(html`<${KeeperItemsPanel} keeper=${unchanged} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    await act(async () => {
      executionWorkspaceRevision.value += 1
      view.rerender(html`<${KeeperItemsPanel} keeper=${unchanged} />`)
    })
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
  })

})
