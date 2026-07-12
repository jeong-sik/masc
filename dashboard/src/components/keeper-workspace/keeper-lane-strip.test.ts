import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'

import type { DashboardKeeperChatQueue, DashboardKeeperWaitingInventory } from '../../api'
import type { Keeper } from '../../types'
import { KeeperLaneStrip } from './keeper-lane-strip'

function emptyChatQueue(): DashboardKeeperChatQueue {
  return {
    schema: 'keeper_chat_queue.dashboard.v1', revision: 0,
    pending_count: 0, inflight_count: 0, active_receipts: [], read_errors: [],
    next_action: null, recent_failed_receipt_count: 0,
    recent_failed_receipt_limit: 8, recent_failed_receipts_truncated: false,
    recent_failed_receipts: [],
  }
}

function keeperFixture(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    agent_name: 'agent-sangsu',
    ...overrides,
  } as Keeper
}

function inventoryFixture(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v2',
    source: 'server_keeper_waiting_inventory',
    visibility: 'operator',
    generated_at: '2026-07-07T09:00:00Z',
    supported_states: ['idle', 'busy', 'waiting', 'deferred'],
    keeper_count_known: true,
    keeper_count: 2,
    waiting_keeper_count: 1,
    row_count: 2,
    row_count_truncated: false,
    external_attention_row_limit: 64,
    external_attention_truncated_keeper_count: 0,
    global_row_count: 0,
    global_pending_confirm_count_known: true,
    global_pending_confirm_count: 0,
    source_counts: { chat_queue_pending: 1, turn_admission_waiting: 1 },
    keepers: [
      {
        keeper_name: 'sangsu',
        metadata_status: 'registered',
        state: 'deferred',
        waiting_count: 2,
        waiting_count_truncated: false,
        truncated_sources: {},
        sources: { chat_queue_pending: 1, turn_admission_waiting: 1 },
        since: 1_783_415_880,
        since_iso: '2026-07-07T08:58:00Z',
        due_at: null,
        due_at_iso: null,
        next_action: 'keeper_drain_chat_queue',
        chat_queue: emptyChatQueue(),
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'chat_queue_pending',
            waiting_on: 'dashboard_chat',
            wake_producer: 'keeper_chat_queue_store',
            since: 1_783_415_940,
            since_iso: '2026-07-07T08:59:00Z',
            due_at: null,
            due_at_iso: null,
            next_action: 'keeper_drain_chat_queue',
            detail: {},
          },
          {
            keeper_name: 'sangsu',
            source: 'turn_admission_waiting',
            waiting_on: 'chat_lane',
            wake_producer: 'keeper_turn_admission',
            since: 1_783_415_880,
            since_iso: '2026-07-07T08:58:00Z',
            due_at: null,
            due_at_iso: null,
            next_action: 'keeper_finish_in_flight_turn',
            detail: {},
          },
        ],
      },
      {
        keeper_name: 'idle-one',
        metadata_status: 'registered',
        state: 'idle',
        waiting_count: 0,
        waiting_count_truncated: false,
        truncated_sources: {},
        sources: {},
        since: null,
        since_iso: null,
        due_at: null,
        due_at_iso: null,
        next_action: null,
        chat_queue: emptyChatQueue(),
        waiting_on: [],
      },
    ],
    global_waiting_on: [],
  }
}

describe('KeeperLaneStrip', () => {
  let host: HTMLDivElement | null = null

  afterEach(() => {
    if (host) {
      render(null, host)
      host.remove()
      host = null
    }
  })

  function mount(node: ReturnType<typeof html>): HTMLDivElement {
    host = document.createElement('div')
    document.body.appendChild(host)
    render(node, host)
    return host
  }

  it('renders the matching keeper lane state and waiting rows verbatim', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const text = el.textContent ?? ''
    expect(text).toContain('레인')
    expect(text).toContain('deferred')
    expect(text).toContain('dashboard_chat')
    expect(text).toContain('chat_lane')
    expect(text).toContain('keeper finish in flight turn')
    expect(el.querySelector('[data-missing="keeper-lane"]')).toBeNull()
  })

  it('shows the auto-refresh cadence beside the snapshot time when polling', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
        autoRefreshMs=${15_000}
      />
    `)
    const text = el.textContent ?? ''
    expect(text).toContain('기준')
    expect(text).toContain('Auto-refresh 15s')
  })

  it('omits the auto-refresh label when the panel is not polling', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    expect(el.textContent ?? '').not.toContain('Auto-refresh')
  })

  it('renders an explicit gap when the keeper is absent from the inventory', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture({ name: 'ghost', agent_name: 'agent-ghost' })}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const gap = el.querySelector('[data-missing="keeper-lane"]')
    expect(gap).not.toBeNull()
    expect(gap?.textContent ?? '').toContain('이 키퍼 항목이 없습니다')
  })

  it('renders an explicit gap when the response omits the inventory field', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${null}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const gap = el.querySelector('[data-missing="keeper-lane"]')
    expect(gap).not.toBeNull()
    expect(gap?.textContent ?? '').toContain('keeper_waiting_inventory')
  })

  it('renders the fetch error instead of guessing a lane state', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${null}
        ready=${false}
        loading=${false}
        error=${'boom'}
      />
    `)
    const gap = el.querySelector('[data-missing="keeper-lane"]')
    expect(gap?.textContent ?? '').toContain('boom')
  })

  it('shows the loading note before the first response arrives', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${null}
        ready=${false}
        loading=${true}
        error=${null}
      />
    `)
    expect(el.textContent ?? '').toContain('레인 상태 로딩')
    expect(el.querySelector('[data-missing="keeper-lane"]')).toBeNull()
  })
})
