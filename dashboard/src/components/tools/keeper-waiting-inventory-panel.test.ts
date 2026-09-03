import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'
import type { Keeper } from '../../types'
import { KeeperLaneStrip } from '../keeper-workspace/keeper-lane-strip'
import { KeeperLaneInventoryPanel, KeeperWaitingInventoryPanel } from './keeper-waiting-inventory-panel'

function inventoryFixture(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v3',
    source: 'server_keeper_waiting_inventory',
    generated_at: '2026-07-04T00:00:00Z',
    supported_states: ['idle', 'busy', 'waiting', 'deferred'],
    keeper_count_known: true,
    keeper_count: 4,
    waiting_keeper_count: 3,
    row_count: 5,
    global_row_count: 1,
    global_pending_confirm_count_known: true,
    global_pending_confirm_count: 1,
    source_counts: {
      event_queue_pending: 1,
      chat_operation_running: 1,
      chat_operation_queued: 1,
      schedule_waiting: 1,
      owner_shutdown: 1,
    },
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'waiting',
        waiting_count: 3,
        sources: {
          event_queue_pending: 1,
          chat_operation_running: 1,
          chat_operation_queued: 1,
        },
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'event_queue_pending',
            waiting_on: 'bootstrap',
            what: '기동 직후 첫 턴',
            wake_producer: 'keeper_supervisor',
            since_iso: '2026-07-04T00:00:00Z',
            next_action: 'keeper_drain_event_queue',
          },
          {
            keeper_name: 'sangsu',
            source: 'chat_operation_running',
            waiting_on: 'keeper_turn',
            what: '운영자와 진행 중인 대화',
            wake_producer: 'keeper_owner_actor',
            since_iso: '2026-07-04T00:02:00Z',
            next_action: 'keeper_owner_settle_operation',
            detail: {
              operation_id: 'kmsg-operation-running',
            },
          },
          {
            keeper_name: 'sangsu',
            source: 'chat_operation_queued',
            waiting_on: 'owner_fifo',
            what: '운영자 채팅 1건 대기',
            wake_producer: 'keeper_owner_actor',
            since_iso: '2026-07-04T00:03:00Z',
            next_action: 'keeper_owner_start_fifo_head',
            detail: {
              queued_count: 2,
            },
          },
        ],
      },
      {
        keeper_name: 'busy-one',
        state: 'busy',
        waiting_count: 1,
        sources: {
          chat_operation_running: 1,
        },
        waiting_on: [
          {
            keeper_name: 'busy-one',
            source: 'chat_operation_running',
            waiting_on: 'keeper_turn',
            what: '운영자와 진행 중인 대화',
            wake_producer: 'keeper_owner_actor',
            since_iso: '2026-07-04T00:02:00Z',
            next_action: 'keeper_owner_settle_operation',
          },
        ],
      },
      {
        keeper_name: 'idle-one',
        state: 'idle',
        waiting_count: 0,
        waiting_on: [],
      },
      {
        keeper_name: 'stopping-one',
        state: 'deferred',
        waiting_count: 1,
        sources: {
          owner_shutdown: 1,
        },
        waiting_on: [
          {
            keeper_name: 'stopping-one',
            source: 'owner_shutdown',
            waiting_on: 'shutdown',
            what: '종료 정리 중',
            wake_producer: 'keeper_owner_actor',
            next_action: 'keeper_shutdown_finalize',
            detail: {
              shutdown_operation_id: 'shutdown-op-7',
              admission_fenced: true,
            },
          },
        ],
      },
    ],
    global_waiting_on: [
      {
        source: 'schedule_waiting',
        waiting_on: 'masc.board_post',
        what: '예약 실행 · masc.board_post',
        wake_producer: 'schedule_runner',
        due_at_iso: '2026-07-04T01:00:00Z',
        next_action: 'schedule_runner_dispatch',
      },
    ],
  }
}

function keeperFixture(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    agent_name: 'agent-sangsu',
    ...overrides,
  } as Keeper
}

describe('KeeperWaitingInventoryPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders keeper-specific and global waiting evidence', () => {
    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventoryFixture()} />`, container)

    expect(container.textContent).toContain('keepers')
    expect(container.textContent).toContain('waiting')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('busy-one')
    expect(container.textContent).toContain('busy')
    // The operator sentence is the default reading; the raw wire vocabulary
    // stays behind the 기술 상세 toggle.
    expect(container.textContent).toContain('기동 직후 첫 턴')
    expect(container.textContent).toContain('운영자와 진행 중인 대화')
    expect(container.textContent).toContain('운영자 채팅 1건 대기')
    expect(container.textContent).toContain('종료 정리 중')
    expect(container.textContent).toContain('Global waiting')
    expect(container.textContent).toContain('masc.board_post')
    expect(container.textContent).not.toContain('idle-one')
    expect(container.textContent).not.toContain('keeper_owner_actor')

    fireEvent.click(container.querySelector('[data-testid="keeper-lane-dev-toggle"]') as HTMLButtonElement)
    const devText = container.textContent ?? ''
    expect(devText).toContain('keeper_owner_actor')
    expect(devText).toContain('keeper_owner_settle_operation')
    expect(devText).toContain('keeper_supervisor')
    expect(devText).toContain('kmsg-operation-running')
    expect(devText).toContain('shutdown-op-7')
    expect(devText).toContain('admission_fenced')
  })

  it('renders unavailable state without crashing', () => {
    render(html`<${KeeperWaitingInventoryPanel} inventory=${null} />`, container)

    expect(container.textContent).toContain('waiting inventory unavailable')
  })

  it('renders every row oldest-first with no client-side cap', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-07-04T00:10:00Z'))
    const inventory = inventoryFixture()
    const keeper = inventory.keepers[0]
    if (!keeper) throw new Error('fixture keeper missing')
    // Out of order on purpose: the newest row first, the oldest last.
    keeper.waiting_on = [
      {
        keeper_name: keeper.keeper_name,
        source: 'chat_operation_queued',
        waiting_on: 'owner_fifo',
        what: '운영자 채팅 1건 대기',
        wake_producer: 'keeper_owner_actor',
        since_iso: '2026-07-04T00:09:00Z',
        next_action: 'keeper_owner_start_fifo_head',
      },
      {
        keeper_name: keeper.keeper_name,
        source: 'chat_operation_running',
        waiting_on: 'keeper_turn',
        what: '운영자와 진행 중인 대화',
        wake_producer: 'keeper_owner_actor',
        since_iso: '2026-07-04T00:05:00Z',
        next_action: 'keeper_owner_settle_operation',
      },
      {
        keeper_name: keeper.keeper_name,
        source: 'event_queue_pending',
        waiting_on: 'bootstrap',
        what: '기동 직후 첫 턴',
        wake_producer: 'keeper_supervisor',
        since_iso: '2026-07-04T00:00:00Z',
        next_action: 'keeper_drain_event_queue',
      },
    ]
    keeper.waiting_count = keeper.waiting_on.length

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    const sangsuLane = container.querySelector('[data-keeper-lane="sangsu"]')!
    const rows = Array.from(sangsuLane.querySelectorAll('[data-testid="keeper-lane-waiting-row"]'))
    expect(rows.map(row => row.getAttribute('data-waiting-on'))).toEqual([
      'bootstrap',
      'keeper_turn',
      'owner_fifo',
    ])
    // All three rows render — no slice cap.
    expect(rows.length).toBe(3)
    expect(container.querySelector('[data-expand-waiting-rows]')).toBeNull()
    vi.useRealTimers()
  })

  it('renders unknown pending-confirm count when the store read failed', () => {
    const inventory = inventoryFixture()
    inventory.global_pending_confirm_count_known = false
    inventory.global_pending_confirm_count = 0
    inventory.global_waiting_on = [
      {
        source: 'read_error',
        waiting_on: 'operator_pending_confirm_store',
        what: '대기 기록 읽기 실패 · operator_pending_confirm_store',
        wake_producer: 'read_model_reader',
        next_action: 'repair_operator_pending_confirms',
      },
    ]

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).toContain('unmapped confirmsunknown')
    expect(container.textContent).toContain('operator_pending_confirm_store')
    fireEvent.click(container.querySelector('[data-testid="keeper-lane-dev-toggle"]') as HTMLButtonElement)
    expect(container.textContent).toContain('repair_operator_pending_confirms')
  })

  it('renders unknown keeper count when discovery failed', () => {
    const inventory = inventoryFixture()
    inventory.keeper_count_known = false
    inventory.keeper_count = 0
    inventory.global_waiting_on = [
      {
        source: 'read_error',
        waiting_on: 'keeper_meta_store',
        what: '대기 기록 읽기 실패 · keeper_meta_store',
        wake_producer: 'read_model_reader',
        next_action: 'repair_keeper_meta_store',
      },
    ]

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).toContain('keepersunknown')
    expect(container.textContent).toContain('keeper_meta_store')
    fireEvent.click(container.querySelector('[data-testid="keeper-lane-dev-toggle"]') as HTMLButtonElement)
    expect(container.textContent).toContain('repair_keeper_meta_store')
  })

  it('uses the same waiting-row component as the keeper lane strip', () => {
    const inventory = inventoryFixture()
    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)
    const fleetRows = container.querySelectorAll('[data-testid="keeper-lane-waiting-row"]')
    expect(fleetRows.length).toBeGreaterThan(0)

    const laneHost = document.createElement('div')
    document.body.appendChild(laneHost)
    render(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventory}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `, laneHost)
    const stripRows = laneHost.querySelectorAll('[data-testid="keeper-lane-waiting-row"]')
    expect(stripRows.length).toBeGreaterThan(0)
    // Both surfaces emit the same row testid from the shared LaneWaitingRow.
    expect(fleetRows[0]!.tagName).toBe(stripRows[0]!.tagName)
    render(null, laneHost)
    laneHost.remove()
  })
})

describe('KeeperLaneInventoryPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders one lane card per projected keeper, including idle lanes', () => {
    render(html`<${KeeperLaneInventoryPanel} inventory=${inventoryFixture()} />`, container)

    const cards = container.querySelectorAll('[data-testid="keeper-lane-card"]')
    expect(cards).toHaveLength(4)
    expect(container.querySelector('[data-keeper-lane="sangsu"]')?.textContent).toContain('기동 직후 첫 턴')
    expect(container.querySelector('[data-keeper-lane="busy-one"]')?.textContent).toContain('운영자와 진행 중인 대화')
    expect(container.querySelector('[data-keeper-lane="idle-one"]')?.textContent).toContain('no keeper-specific waiting rows')
    expect(container.querySelector('[data-keeper-lane="stopping-one"]')?.textContent).toContain('종료 정리 중')
    expect(container.textContent).toContain('Global lane evidence')
    expect(container.textContent).toContain('masc.board_post')
  })

  it('surfaces missing wake producer and next action evidence explicitly', () => {
    const inventory = inventoryFixture()
    inventory.keepers = [
      {
        keeper_name: 'partial-lane',
        state: 'waiting',
        waiting_count: 1,
        waiting_on: [
          {
            keeper_name: 'partial-lane',
            source: 'event_queue_pending',
            waiting_on: 'discord:ops',
            what: 'discord:ops 멘션',
            wake_producer: null,
            next_action: '',
          },
        ],
      },
    ]

    render(html`<${KeeperLaneInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).toContain('partial-lane')
    expect(container.textContent).toContain('discord:ops')
    fireEvent.click(container.querySelector('[data-testid="keeper-lane-dev-toggle"]') as HTMLButtonElement)
    expect(container.textContent).toContain('wake ·')
    expect(container.textContent).toContain('미기록')
    expect(container.textContent).toContain('다음 동작 ·')
  })

  it('renders unavailable lane evidence without inventing fallback rows', () => {
    render(html`<${KeeperLaneInventoryPanel} inventory=${null} />`, container)

    expect(container.textContent).toContain('keeper lane evidence unavailable')
    expect(container.querySelector('[data-testid="keeper-lane-card"]')).toBeNull()
  })
})
