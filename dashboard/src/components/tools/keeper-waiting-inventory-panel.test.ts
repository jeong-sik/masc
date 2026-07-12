import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type { DashboardKeeperChatQueue, DashboardKeeperWaitingInventory } from '../../api'
import { KeeperLaneInventoryPanel, KeeperWaitingInventoryPanel } from './keeper-waiting-inventory-panel'

function emptyChatQueue(): DashboardKeeperChatQueue {
  return {
    schema: 'keeper_chat_queue.dashboard.v1', revision: 0,
    pending_count: 0, inflight_count: 0, active_receipts: [], read_errors: [],
    next_action: null, recent_failed_receipt_count: 0,
    recent_failed_receipt_limit: 8, recent_failed_receipts_truncated: false,
    recent_failed_receipts: [],
  }
}

function inventoryFixture(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v2',
    source: 'server_keeper_waiting_inventory',
    visibility: 'operator',
    generated_at: '2026-07-04T00:00:00Z',
    supported_states: ['idle', 'busy', 'waiting', 'deferred'],
    keeper_count_known: true,
    keeper_count: 4,
    waiting_keeper_count: 3,
    row_count: 5,
    row_count_truncated: false,
    external_attention_row_limit: 64,
    external_attention_truncated_keeper_count: 0,
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
        metadata_status: 'registered',
        state: 'waiting',
        waiting_count: 3,
        waiting_count_truncated: false,
        truncated_sources: {},
        chat_queue: emptyChatQueue(),
        sources: {
          event_queue_pending: 1,
          event_queue_inflight: 1,
          chat_queue_inflight: 1,
        },
        since: 1_783_123_200,
        since_iso: '2026-07-04T00:00:00Z',
        due_at: null,
        due_at_iso: null,
        next_action: 'keeper_drain_event_queue',
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'event_queue_pending',
            waiting_on: 'bootstrap',
            wake_producer: 'keeper_supervisor',
            since: 1_783_123_200,
            since_iso: '2026-07-04T00:00:00Z',
            due_at: null,
            due_at_iso: null,
            next_action: 'keeper_drain_event_queue',
            detail: {},
          },
          {
            keeper_name: 'sangsu',
            source: 'event_queue_inflight',
            waiting_on: 'no_progress_recovery',
            wake_producer: 'keeper_no_progress_recovery',
            since: 1_783_123_260,
            since_iso: '2026-07-04T00:01:00Z',
            due_at: null,
            due_at_iso: null,
            next_action: 'recover_inflight_turn',
            detail: {},
          },
          {
            keeper_name: 'sangsu',
            source: 'chat_queue_inflight',
            waiting_on: 'dashboard',
            wake_producer: 'keeper_chat_queue_store',
            since: 1_783_123_320,
            since_iso: '2026-07-04T00:02:00Z',
            due_at: null,
            due_at_iso: null,
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
        metadata_status: 'registered',
        state: 'busy',
        waiting_count: 1,
        waiting_count_truncated: false,
        truncated_sources: {},
        chat_queue: emptyChatQueue(),
        sources: {
          turn_admission_waiting: 1,
        },
        since: 1_783_123_320,
        since_iso: '2026-07-04T00:02:00Z',
        due_at: null,
        due_at_iso: null,
        next_action: 'turn_slot_release',
        waiting_on: [
          {
            keeper_name: 'busy-one',
            source: 'turn_admission_waiting',
            waiting_on: 'chat',
            wake_producer: 'keeper_turn_admission',
            since: 1_783_123_320,
            since_iso: '2026-07-04T00:02:00Z',
            due_at: null,
            due_at_iso: null,
            next_action: 'turn_slot_release',
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
      {
        keeper_name: 'stopping-one',
        metadata_status: 'registered',
        state: 'deferred',
        waiting_count: 1,
        waiting_count_truncated: false,
        truncated_sources: {},
        chat_queue: emptyChatQueue(),
        sources: {
          turn_admission_shutdown: 1,
        },
        since: null,
        since_iso: null,
        due_at: null,
        due_at_iso: null,
        next_action: 'keeper_shutdown_finalize',
        waiting_on: [
          {
            keeper_name: 'stopping-one',
            source: 'turn_admission_shutdown',
            waiting_on: 'shutdown',
            wake_producer: 'keeper_turn_admission',
            since: null,
            since_iso: null,
            due_at: null,
            due_at_iso: null,
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
        keeper_name: null,
        source: 'schedule_waiting',
        waiting_on: 'masc.board_post',
        wake_producer: 'schedule_runner',
        since: null,
        since_iso: null,
        due_at: 1_783_126_800,
        due_at_iso: '2026-07-04T01:00:00Z',
        next_action: 'schedule_runner_dispatch',
        detail: {},
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
    expect(container.querySelector('[aria-label="종료 작업 ID shutdown-op-7 복사"]')).not.toBeNull()
    const shutdownChip = [...container.querySelectorAll('[data-status-chip]')]
      .find(chip => chip.textContent?.trim() === 'turn admission shutdown')
    expect(shutdownChip?.getAttribute('data-status-chip-tone')).toBe('info')
    expect(container.textContent).toContain('event queue pending')
    expect(container.textContent).toContain('producer keeper supervisor')
    expect(container.textContent).toContain('producer keeper no progress recovery')
    expect(container.textContent).toContain('no_progress_recovery')
    expect(container.textContent).toContain('chatq_00000000-0000-4000-8000-000000000001')
    expect(container.querySelector('[aria-label="큐 receipt chatq_00000000-0000-4000-8000-000000000001 복사"]')).not.toBeNull()
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
      wake_producer: 'keeper_chat_queue_store',
      since: null,
      since_iso: null,
      due_at: null,
      due_at_iso: null,
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
        keeper_name: null,
        source: 'read_error',
        waiting_on: 'operator_pending_confirm_store',
        wake_producer: 'read_model_reader',
        since: null,
        since_iso: null,
        due_at: null,
        due_at_iso: null,
        next_action: 'repair_operator_pending_confirms',
        detail: { kind: 'read_failed', message: 'ledger unavailable' },
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
        keeper_name: null,
        source: 'read_error',
        waiting_on: 'keeper_meta_store',
        wake_producer: 'read_model_reader',
        since: null,
        since_iso: null,
        due_at: null,
        due_at_iso: null,
        next_action: 'repair_keeper_meta_store',
        detail: { kind: 'read_failed', message: 'metadata unavailable' },
      },
    ]

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).toContain('keepersunknown')
    expect(container.textContent).toContain('keeper_meta_store')
    expect(container.textContent).toContain('repair keeper meta store')
  })

  it('keeps an idle queue-only Keeper visible when its only evidence is a terminal failure', () => {
    const inventory = inventoryFixture()
    const idle = inventory.keepers.find(keeper => keeper.keeper_name === 'idle-one')
    if (!idle) throw new Error('idle fixture missing')
    inventory.keepers = [{
      ...idle,
      keeper_name: 'orphan-queue',
      metadata_status: 'queue_only',
      chat_queue: {
        ...emptyChatQueue(),
        revision: 7,
        recent_failed_receipt_count: 1,
        recent_failed_receipts: [{
          receipt_id: 'chatq_00000000-0000-4000-8000-000000000099',
          state: 'failed',
          failure_kind: 'delivery_failed',
          completed_at: 1_783_123_500,
          completed_at_iso: '2026-07-04T00:05:00Z',
          outcome_ref: null,
        }],
      },
    }]
    inventory.keeper_count = 1
    inventory.waiting_keeper_count = 0
    inventory.row_count = 0
    inventory.source_counts = {}

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).toContain('orphan-queue')
    expect(container.textContent).toContain('queue only · metadata missing')
    expect(container.textContent).toContain('delivery failed')
    expect(container.textContent).toContain('orphan-queue@7')
    expect(container.querySelector('[data-keeper-chat-queue-terminal-failure]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Keeper queue revision orphan-queue@7 복사"]')).not.toBeNull()
  })

  it('expands global diagnostics and renders queue configuration error details', () => {
    const inventory = inventoryFixture()
    const scheduleRows = Array.from({ length: 4 }, (_, index) => ({
      keeper_name: null,
      source: 'schedule_waiting' as const,
      waiting_on: `schedule-${index}`,
      wake_producer: 'schedule_store' as const,
      since: null,
      since_iso: null,
      due_at: null,
      due_at_iso: null,
      next_action: 'wait_for_schedule',
      detail: {},
    }))
    inventory.global_waiting_on = [
      ...scheduleRows,
      {
        keeper_name: null,
        source: 'read_error',
        waiting_on: 'chat_queue_configuration',
        wake_producer: 'read_model_reader',
        since: null,
        since_iso: null,
        due_at: null,
        due_at_iso: null,
        next_action: 'repair_keeper_chat_queue_configuration',
        detail: {
          kind: 'invalid_path',
          path: '/private/keeper/chat-queue.json',
          message: 'queue registry is unavailable',
        },
      },
    ]
    inventory.global_row_count = inventory.global_waiting_on.length

    render(html`<${KeeperWaitingInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).not.toContain('chat_queue_configuration')
    fireEvent.click(container.querySelector('[data-expand-global-waiting-rows]') as HTMLButtonElement)
    expect(container.textContent).toContain('chat_queue_configuration')
    expect(container.textContent).toContain('/private/keeper/chat-queue.json')
    expect(container.textContent).toContain('queue registry is unavailable')
    expect(container.querySelector('[data-waiting-read-error-detail]')).not.toBeNull()
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

  it('surfaces queue-only terminal evidence in the all-lanes diagnostic', () => {
    const inventory = inventoryFixture()
    const idle = inventory.keepers.find(keeper => keeper.keeper_name === 'idle-one')
    if (!idle) throw new Error('idle fixture missing')
    inventory.keepers = [{
      ...idle,
      keeper_name: 'orphan-lane',
      metadata_status: 'queue_only',
      chat_queue: {
        ...emptyChatQueue(),
        revision: 11,
        recent_failed_receipt_count: 1,
        recent_failed_receipts: [{
          receipt_id: 'chatq_00000000-0000-4000-8000-000000000111',
          state: 'failed',
          failure_kind: 'internal_error',
          completed_at: 1_783_123_500,
          completed_at_iso: '2026-07-04T00:05:00Z',
          outcome_ref: null,
        }],
      },
    }]
    inventory.keeper_count = 1
    inventory.waiting_keeper_count = 0
    inventory.row_count = 0
    inventory.source_counts = {}

    render(html`<${KeeperLaneInventoryPanel} inventory=${inventory} />`, container)

    expect(container.textContent).toContain('orphan-lane')
    expect(container.textContent).toContain('queue only · metadata missing')
    expect(container.textContent).toContain('internal error')
    expect(container.textContent).toContain('orphan-lane@11')
  })

  it('renders unavailable lane evidence without inventing fallback rows', () => {
    render(html`<${KeeperLaneInventoryPanel} inventory=${null} />`, container)

    expect(container.textContent).toContain('keeper lane evidence unavailable')
    expect(container.querySelector('[data-testid="keeper-lane-card"]')).toBeNull()
  })
})
