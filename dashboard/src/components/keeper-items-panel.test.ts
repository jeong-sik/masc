import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import type { Keeper } from '../types'
import { EQUIPMENT_IDS } from '../api/schemas/keeper-portrait'

const fetchKeeperItems = vi.hoisted(() => vi.fn())
vi.mock('../api/keeper-items', () => ({ fetchKeeperItems }))
vi.mock('./keeper-portrait', () => ({ KeeperPortrait: () => html`<div data-testid="portrait" />` }))
vi.mock('./keeper-badge', () => ({ KeeperBadge: () => html`<div />` }))

import { KeeperItemsPanel } from './keeper-items-panel'

const keeper = (name: string) => ({ name, portrait: { state: 'ready', equipment: {
  face: 'bare_face', neck: 'bare_neck', head: 'crown', hand: 'empty_hand', base: 'no_dish',
} } }) as Keeper
const catalog = Object.entries(EQUIPMENT_IDS).flatMap(([slot, ids]) =>
  ids.slice(1).map(id => ({ id, slot, priceMilli: id === 'crown' ? 200 : null })),
)

afterEach(() => { cleanup(); vi.resetAllMocks() })

describe('Keeper Item tab', () => {
  it('shows observed balance, prices, ownership and equipment', async () => {
    fetchKeeperItems.mockResolvedValue({ status: 'ready', keeper: 'rondo', balanceMilli: 800, ownedItems: ['crown'], catalog })
    render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    expect(screen.getByText('보유 1 / 18개')).toBeTruthy()
    expect(screen.getByText('착용 중')).toBeTruthy()
    expect(screen.getAllByText('가격 미설정').length).toBe(17)
    expect(screen.getByTestId('portrait')).toBeTruthy()
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
    fetchKeeperItems.mockResolvedValueOnce({ status: 'ready', keeper: 'rondo', balanceMilli: 800, ownedItems: [], catalog })
      .mockResolvedValueOnce({ status: 'off', keeper: 'geek-scout' })
    const view = render(html`<${KeeperItemsPanel} keeper=${keeper('rondo')} />`)
    expect(await screen.findByText('0.800 Candle')).toBeTruthy()
    view.rerender(html`<${KeeperItemsPanel} keeper=${keeper('geek-scout')} />`)
    expect(screen.queryByText('0.800 Candle')).toBeNull()
    expect(await screen.findByText('Candle 기능이 꺼져 있습니다.')).toBeTruthy()
  })
})
