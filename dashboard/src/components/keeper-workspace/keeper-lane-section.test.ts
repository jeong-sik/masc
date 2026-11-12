import { html } from 'htm/preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'
import type { KeeperWaitingInventoryChange } from '../../sse-store'

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  observer: null as null | {
    ready: (instance: string) => void
    change: (change: KeeperWaitingInventoryChange) => void
    unavailable: () => void
  },
  stopObserver: vi.fn(),
}))

vi.mock('../../api', async importOriginal => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    fetchKeeperWaitingInventory: mocks.fetchKeeperWaitingInventory,
  }
})
vi.mock('../../keeper-waiting-observer-client', () => ({
  startKeeperWaitingObserver: (callbacks: NonNullable<typeof mocks.observer>) => {
    mocks.observer = callbacks
    return { stop: mocks.stopObserver, invalidate: vi.fn() }
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
      keeper_name: 'exampleorg',
      state: 'waiting',
      state_sources: ['event_queue_pending'],
      waiting_count: 1,
      waiting_on: [{
        keeper_name: 'exampleorg',
        source: 'event_queue_pending',
        waiting_on: 'schedule_due',
        what: '예약 실행 시각 도래 · daily-news',
        next_action: 'keeper_consume_event',
      }],
    }],
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  mocks.observer = null
})

describe('KeeperLaneSection', () => {
  it('re-reads the selected keeper on SSE and labels a lost observer', async () => {
    mocks.fetchKeeperWaitingInventory.mockResolvedValue(inventory())
    render(html`<${KeeperLaneSection} keeper=${{ name: 'exampleorg', agent_name: 'agent-exampleorg' }} />`)

    await waitFor(() => expect(mocks.observer).not.toBeNull())
    expect(mocks.fetchKeeperWaitingInventory).not.toHaveBeenCalled()
    mocks.observer?.ready('process.epoch')
    await waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1))

    mocks.observer?.change({ scope: 'keeper', keeperName: 'rondo' })
    expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(1)

    mocks.observer?.change({ scope: 'keeper', keeperName: 'exampleorg' })
    await waitFor(() => expect(mocks.fetchKeeperWaitingInventory).toHaveBeenCalledTimes(2))
    mocks.observer?.unavailable()
    await waitFor(() => expect(document.querySelector('[data-testid="keeper-waiting-stale"]')?.textContent)
      .toContain('마지막으로 확인한 대기 상태'))
  })
})
