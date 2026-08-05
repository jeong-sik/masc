import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  refresh: null as ((keeperName: string) => void) | null,
  unregisterPush: vi.fn(),
}))

vi.mock('../../api', () => ({
  fetchKeeperWaitingInventory: mocks.fetchKeeperWaitingInventory,
}))
vi.mock('../../sse-store', () => ({
  registerKeeperWaitingInventoryRefresh: vi.fn((refresh: (keeperName: string) => void) => {
    mocks.refresh = refresh
    return mocks.unregisterPush
  }),
}))
vi.mock('../../dashboard-ws-state', () => ({
  dashboardWsReady: { value: true },
  dashboardWsReconnectCount: {
    value: 0,
    subscribe: vi.fn(() => vi.fn()),
  },
}))

import { KeeperLaneSection } from './keeper-lane-strip'

function inventory(): DashboardKeeperWaitingInventory {
  return {
    generated_at: '2026-08-05T08:00:00Z',
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: 1,
    keepers: [{
      keeper_name: 'kidsnote',
      state: 'waiting',
      waiting_count: 1,
      waiting_on: [{
        keeper_name: 'kidsnote',
        source: 'event_queue_pending',
        waiting_on: 'schedule_due',
        next_action: 'keeper_consume_event',
      }],
    }],
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  mocks.refresh = null
})

describe('KeeperLaneSection', () => {
  it('re-reads only the visible keeper when its WS invalidation arrives', async () => {
    mocks.fetchKeeperWaitingInventory.mockResolvedValue(inventory())
    render(html`<${KeeperLaneSection} keeper=${{ name: 'kidsnote', agent_name: 'agent-kidsnote' }} />`)

    await waitFor(() => expect(screen.getByText('처리 대기 중')).toBeTruthy())
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)

    mocks.refresh?.('rondo')
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)

    mocks.refresh?.('kidsnote')
    await waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2))
  })
})
