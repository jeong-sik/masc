import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'
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
    expect(container.textContent).toContain('chat operation running')
    expect(container.textContent).toContain('producer keeper owner actor')
    expect(container.textContent).toContain('keeper owner settle operation')
    expect(container.textContent).toContain('owner shutdown')
    expect(container.textContent).toContain('keeper shutdown finalize')
    expect(container.textContent).toContain('shutdown operation shutdown-op-7')
    expect(container.textContent).toContain('admission fenced')
    expect(container.querySelector('[data-keeper-shutdown-operation-id="shutdown-op-7"]')).not.toBeNull()
    const shutdownChip = [...container.querySelectorAll('[data-status-chip]')]
      .find(chip => chip.textContent?.trim() === 'owner shutdown')
    expect(shutdownChip?.getAttribute('data-status-chip-tone')).toBe('info')
    expect(container.textContent).toContain('event queue pending')
    expect(container.textContent).toContain('producer keeper supervisor')
    expect(container.textContent).toContain('producer keeper supervisor')
    expect(container.textContent).toContain('operation kmsg-operation-running')
    expect(container.textContent).toContain('chat operation queued')
    expect(container.textContent).toContain('queued 2')
    expect(container.textContent).toContain('Global waiting')
    expect(container.textContent).toContain('masc.board_post')
    expect(container.textContent).not.toContain('idle-one')
  })

  it('renders unavailable state without crashing', () => {
    render(html`<${KeeperWaitingInventoryPanel} inventory=${null} />`, container)

    expect(container.textContent).toContain('waiting inventory unavailable')
  })

  it('expands operation rows without hiding operation identities', () => {
    const inventory = inventoryFixture()
    const keeper = inventory.keepers[0]
    if (!keeper) throw new Error('fixture keeper missing')
    keeper.waiting_on = Array.from({ length: 7 }, (_, index) => ({
      keeper_name: keeper.keeper_name,
      source: 'chat_operation_running',
      waiting_on: 'keeper_turn',
      what: '운영자와 진행 중인 대화',
      wake_producer: 'keeper_owner_actor',
      next_action: 'keeper_owner_settle_operation',
      detail: {
        operation_id: `kmsg-operation-${index}`,
      },
    }))
    keeper.waiting_count = keeper.waiting_on.length

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).not.toContain('kmsg-operation-6')
    fireEvent.click(container.querySelector('[data-expand-waiting-rows]') as HTMLButtonElement)
    expect(container.textContent).toContain('kmsg-operation-6')
    expect(container.querySelector('[data-collapse-waiting-rows]')).not.toBeNull()
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
    expect(container.textContent).toContain('repair operator pending confirms')
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
    expect(container.textContent).toContain('repair keeper meta store')
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
    expect(container.querySelector('[data-keeper-lane="sangsu"]')?.textContent).toContain('event queue pending')
    expect(container.querySelector('[data-keeper-lane="busy-one"]')?.textContent).toContain('chat operation running')
    expect(container.querySelector('[data-keeper-lane="idle-one"]')?.textContent).toContain('no keeper-specific waiting rows')
    expect(container.querySelector('[data-keeper-lane="stopping-one"]')?.textContent).toContain('owner shutdown')
    expect(container.textContent).toContain('Global lane evidence')
    expect(container.textContent).toContain('producer schedule runner')
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
            source: 'external_attention',
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
    expect(container.textContent).toContain('producer wake producer missing')
    expect(container.textContent).toContain('next action missing')
  })

  it('renders unavailable lane evidence without inventing fallback rows', () => {
    render(html`<${KeeperLaneInventoryPanel} inventory=${null} />`, container)

    expect(container.textContent).toContain('keeper lane evidence unavailable')
    expect(container.querySelector('[data-testid="keeper-lane-card"]')).toBeNull()
  })
})
