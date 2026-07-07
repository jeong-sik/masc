import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'
import type { Keeper } from '../../types'
import { KeeperLaneStrip } from './keeper-lane-strip'

function keeperFixture(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    agent_name: 'agent-sangsu',
    ...overrides,
  } as Keeper
}

function inventoryFixture(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v1',
    source: 'server_keeper_waiting_inventory',
    generated_at: '2026-07-07T09:00:00Z',
    supported_states: ['idle', 'busy', 'waiting', 'deferred'],
    keeper_count_known: true,
    keeper_count: 2,
    waiting_keeper_count: 1,
    row_count: 2,
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'deferred',
        waiting_count: 2,
        next_action: 'keeper_drain_chat_queue',
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'chat_queue_pending',
            waiting_on: 'dashboard_chat',
            wake_producer: 'keeper_chat_queue',
            since_iso: '2026-07-07T08:59:00Z',
            next_action: 'keeper_drain_chat_queue',
          },
          {
            keeper_name: 'sangsu',
            source: 'turn_admission_waiting',
            waiting_on: 'chat_lane',
            wake_producer: 'keeper_turn_admission',
            since_iso: '2026-07-07T08:58:00Z',
            next_action: 'keeper_finish_in_flight_turn',
          },
        ],
      },
      {
        keeper_name: 'idle-one',
        state: 'idle',
        waiting_count: 0,
        waiting_on: [],
      },
    ],
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
