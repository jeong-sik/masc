import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'
import { KeeperLaneInventoryPanel, KeeperWaitingInventoryPanel } from './keeper-waiting-inventory-panel'

function inventoryFixture(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v2',
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
      event_queue_inflight: 1,
      chat_queue_inflight: 1,
      schedule_waiting: 1,
      turn_admission_waiting: 1,
      turn_admission_shutdown: 1,
    },
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'waiting',
        waiting_count: 3,
        sources: {
          event_queue_pending: 1,
          event_queue_inflight: 1,
          chat_queue_inflight: 1,
        },
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'event_queue_pending',
            waiting_on: 'bootstrap',
            wake_producer: 'keeper_supervisor',
            since_iso: '2026-07-04T00:00:00Z',
            next_action: 'keeper_drain_event_queue',
          },
          {
            keeper_name: 'sangsu',
            source: 'event_queue_inflight',
            waiting_on: 'no_progress_recovery',
            wake_producer: 'keeper_no_progress_recovery',
            since_iso: '2026-07-04T00:01:00Z',
            next_action: 'recover_inflight_turn',
          },
          {
            keeper_name: 'sangsu',
            source: 'chat_queue_inflight',
            waiting_on: 'dashboard',
            wake_producer: 'keeper_chat_queue_store',
            since_iso: '2026-07-04T00:02:00Z',
            next_action: 'keeper_chat_turn_terminal_receipt',
            detail: {
              queue_index: 0,
              receipt_id: 'chatq_00000000-0000-4000-8000-000000000001',
              lifecycle: {
                state: 'inflight',
                lease_id: 'lease_00000000-0000-4000-8000-000000000002',
                started_at_iso: '2026-07-04T00:02:30Z',
              },
            },
          },
        ],
      },
      {
        keeper_name: 'busy-one',
        state: 'busy',
        waiting_count: 1,
        sources: {
          turn_admission_waiting: 1,
        },
        waiting_on: [
          {
            keeper_name: 'busy-one',
            source: 'turn_admission_waiting',
            waiting_on: 'chat',
            wake_producer: 'keeper_turn_admission',
            since_iso: '2026-07-04T00:02:00Z',
            next_action: 'turn_slot_release',
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
          turn_admission_shutdown: 1,
        },
        waiting_on: [
          {
            keeper_name: 'stopping-one',
            source: 'turn_admission_shutdown',
            waiting_on: 'shutdown',
            wake_producer: 'keeper_turn_admission',
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
    expect(container.textContent).toContain('turn admission waiting')
    expect(container.textContent).toContain('producer keeper turn admission')
    expect(container.textContent).toContain('turn slot release')
    expect(container.textContent).toContain('turn admission shutdown')
    expect(container.textContent).toContain('keeper shutdown finalize')
    expect(container.textContent).toContain('shutdown operation shutdown-op-7')
    expect(container.textContent).toContain('admission fenced')
    expect(container.querySelector('[data-keeper-shutdown-operation-id="shutdown-op-7"]')).not.toBeNull()
    const shutdownChip = [...container.querySelectorAll('[data-status-chip]')]
      .find(chip => chip.textContent?.trim() === 'turn admission shutdown')
    expect(shutdownChip?.getAttribute('data-status-chip-tone')).toBe('info')
    expect(container.textContent).toContain('event queue pending')
    expect(container.textContent).toContain('producer keeper supervisor')
    expect(container.textContent).toContain('producer keeper no progress recovery')
    expect(container.textContent).toContain('no_progress_recovery')
    expect(container.textContent).toContain('chatq_00000000-0000-4000-8000-000000000001')
    expect(container.textContent).toContain('lease_00000000-0000-4000-8000-000000000002')
    expect(container.textContent).toContain('state inflight')
    expect(container.textContent).toContain('Global waiting')
    expect(container.textContent).toContain('masc.board_post')
    expect(container.textContent).not.toContain('idle-one')
  })

  it('renders unavailable state without crashing', () => {
    render(html`<${KeeperWaitingInventoryPanel} inventory=${null} />`, container)

    expect(container.textContent).toContain('waiting inventory unavailable')
  })

  it('expands the active receipt rows instead of hiding reload correlation ids', () => {
    const inventory = inventoryFixture()
    const keeper = inventory.keepers[0]
    if (!keeper) throw new Error('fixture keeper missing')
    keeper.waiting_on = Array.from({ length: 7 }, (_, index) => ({
      keeper_name: keeper.keeper_name,
      source: 'chat_queue_pending',
      waiting_on: 'slack',
      wake_producer: 'keeper_chat_queue',
      next_action: 'keeper_chat_consumer_drain',
      detail: {
        queue_index: index,
        receipt_id: `chatq_00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
        lifecycle: { state: 'pending' },
      },
    }))
    keeper.waiting_count = keeper.waiting_on.length

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).not.toContain('chatq_00000000-0000-4000-8000-000000000006')
    fireEvent.click(container.querySelector('[data-expand-waiting-rows]') as HTMLButtonElement)
    expect(container.textContent).toContain('chatq_00000000-0000-4000-8000-000000000006')
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
    expect(container.querySelector('[data-keeper-lane="busy-one"]')?.textContent).toContain('turn admission waiting')
    expect(container.querySelector('[data-keeper-lane="idle-one"]')?.textContent).toContain('no keeper-specific waiting rows')
    expect(container.querySelector('[data-keeper-lane="stopping-one"]')?.textContent).toContain('turn admission shutdown')
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
