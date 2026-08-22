import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

import type { DashboardKeeperWaitingInventory, DashboardKeeperWaitingRow } from '../../api'
import type { Keeper } from '../../types'
import { KeeperLaneStrip } from './keeper-lane-strip'
import type { LaneEventQueueActions } from './keeper-lane-event-actions'

const SOURCE_REF = 'f'.repeat(64)

/** One `event_queue_pending` row as `server_keeper_waiting_inventory.ml`
 *  emits it after #29522: the exact-entry address travels in `detail`. */
function eventRow(detail: Record<string, unknown> = {}): DashboardKeeperWaitingRow {
  return {
    keeper_name: 'sangsu',
    source: 'event_queue_pending',
    waiting_on: 'workspace_message',
    what: 'nick0cave가 보낸 메시지 (즉시)',
    wake_producer: 'keeper_workspace_message',
    since_iso: '2026-07-07T08:57:00Z',
    next_action: 'keeper_drain_event_queue',
    detail: {
      queue_index: 0,
      post_id: 'workspace-message:wmsg-1',
      source_ref: SOURCE_REF,
      source_incarnation: '17',
      urgency: 'normal',
      arrived_at_unix: 1783767420,
      payload_kind: 'workspace_message',
      message_request_id: 'wmsg-1',
      message_from: 'nick0cave',
      ...detail,
    },
  }
}

function eventInventory(row: DashboardKeeperWaitingRow = eventRow()): DashboardKeeperWaitingInventory {
  return {
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: 2,
    keepers: [{
      keeper_name: 'sangsu',
      state: 'waiting',
      waiting_count: 2,
      waiting_on: [
        row,
        {
          keeper_name: 'sangsu',
          source: 'chat_operation_queued',
          waiting_on: 'owner_fifo',
          what: '운영자 채팅 1건 대기',
          wake_producer: 'keeper_owner_actor',
          since_iso: '2026-07-07T08:59:00Z',
          next_action: 'keeper_owner_start_fifo_head',
        },
      ],
    }],
  }
}

function fakeActions(overrides: Partial<LaneEventQueueActions> = {}): LaneEventQueueActions {
  return {
    pendingKey: null,
    recoveries: [],
    error: null,
    operate: vi.fn(async () => undefined),
    ...overrides,
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
    schema: 'masc.dashboard.keeper_waiting_inventory.v3',
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
        next_action: 'keeper_owner_start_fifo_head',
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'chat_operation_queued',
            waiting_on: 'owner_fifo',
            what: '운영자 채팅 1건 대기',
            wake_producer: 'keeper_owner_actor',
            since_iso: '2026-07-07T08:59:00Z',
            next_action: 'keeper_owner_start_fifo_head',
          },
          {
            keeper_name: 'sangsu',
            source: 'chat_operation_running',
            waiting_on: 'keeper_turn',
            what: '운영자와 진행 중인 대화',
            wake_producer: 'keeper_owner_actor',
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

/** Mirrors the live shape that produced the "레인 64" report: the server capped
 *  external attention at `external_attention_row_limit` and said so, so every
 *  count folded over the surviving rows is a lower bound. The cap and the
 *  external-attention row count are the observed values (sangsu, 2026-07-21,
 *  265 pending in the store, 64 served); the uncapped chat rows are added so
 *  the fixture covers a mixed entry where only one source is bounded. */
function truncatedInventoryFixture(): DashboardKeeperWaitingInventory {
  const externalRows: DashboardKeeperWaitingRow[] = Array.from({ length: 64 }, (_, i) => ({
    keeper_name: 'sangsu',
    source: 'external_attention',
    waiting_on: 'external_attention',
    what: 'external_attention 멘션',
    wake_producer: 'keeper_process_external_attention',
    since_iso: '2026-06-12T03:20:00Z',
    next_action: 'keeper_process_external_attention',
    detail: { event_id: `evt-${i}` },
  }))
  const chatRows: DashboardKeeperWaitingRow[] = Array.from({ length: 5 }, (_, i) => ({
    keeper_name: 'sangsu',
    source: 'chat_operation_queued',
    waiting_on: 'owner_fifo',
    what: '운영자 채팅 1건 대기',
    wake_producer: 'keeper_owner_actor',
    since_iso: '2026-07-21T07:30:00Z',
    next_action: 'keeper_owner_start_fifo_head',
    detail: { operation_id: `kmsg-operation-${i}` },
  }))
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v3',
    source: 'server_keeper_waiting_inventory',
    generated_at: '2026-07-21T07:38:06Z',
    supported_states: ['idle', 'busy', 'waiting', 'deferred'],
    keeper_count_known: true,
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: 69,
    row_count_truncated: true,
    external_attention_row_limit: 64,
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'waiting',
        waiting_count: 69,
        waiting_count_truncated: true,
        truncated_sources: { external_attention: true },
        sources: { external_attention: 64, chat_operation_queued: 5 },
        next_action: 'keeper_process_external_attention',
        waiting_on: [...externalRows, ...chatRows],
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
    vi.useRealTimers()
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
    expect(text).toContain('작업 대기열')
    expect(text).toContain('외부 응답 대기')
    expect(text).toContain('owner_fifo')
    expect(text).toContain('keeper_turn')
    expect(text).toContain('keeper finish in flight turn')
    expect(el.querySelector('[data-missing="keeper-lane"]')).toBeNull()
  })

  it('renders a git-log style timeline newest first without claiming processing priority', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-08-09T00:00:00Z'))
    const inventory = inventoryFixture()
    inventory.keepers[0]!.waiting_on = [
      {
        keeper_name: 'sangsu',
        source: 'external_attention',
        waiting_on: 'discord-old',
        what: 'discord-old 멘션',
        wake_producer: 'external_attention_store',
        since_iso: '2026-08-06T03:59:42Z',
        next_action: 'keeper_process_external_attention',
        detail: { event_id: 'evt-old' },
      },
      {
        keeper_name: 'sangsu',
        source: 'external_attention',
        waiting_on: 'discord-new',
        what: 'discord-new 멘션',
        wake_producer: 'external_attention_store',
        since_iso: '2026-08-08T10:12:03Z',
        next_action: 'keeper_process_external_attention',
        detail: { event_id: 'evt-new' },
      },
      {
        keeper_name: 'sangsu',
        source: 'schedule_waiting',
        waiting_on: 'masc.keeper_wake',
        what: '예약 실행 · masc.keeper_wake',
        wake_producer: 'schedule_runner',
        since_iso: '2026-08-08T06:39:09Z',
        due_at_iso: '2026-08-09T07:29:34Z',
        next_action: 'wait_until_due',
        detail: { schedule_id: 'daily-news' },
      },
    ]
    inventory.keepers[0]!.waiting_count = 3

    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventory}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const rows = Array.from(el.querySelectorAll('[data-testid="keeper-lane-waiting-row"]'))
    expect(rows.map(row => row.getAttribute('data-waiting-on'))).toEqual([
      'discord-new',
      'masc.keeper_wake',
      'discord-old',
    ])
    expect(el.querySelector('[data-testid="keeper-lane-graph"]')).not.toBeNull()
    const renderedTimes = Array.from(el.querySelectorAll('[data-testid="keeper-lane-waiting-time"] time'))
    expect(renderedTimes.map(time => time.getAttribute('datetime'))).toEqual([
      '2026-08-08T10:12:03Z',
      '2026-08-08T06:39:09Z',
      '2026-08-06T03:59:42Z',
    ])
    expect(el.textContent ?? '').toContain('최신 → 오래된')
    // The lane legend stays a compact time-order marker; the old prose
    // disclaimer ("처리 우선순위를 뜻하지 않습니다") was removed for layout room.
    expect(el.textContent ?? '').not.toContain('처리 우선순위')
    expect(el.textContent ?? '').toContain('실행 예정')
    expect(el.textContent ?? '').toContain('7시간 후')
    expect(el.textContent ?? '').not.toContain('실행 예정 · 지금')
  })

  it('discloses the typed evidence carried by one queue node', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const disclosure = el.querySelector<HTMLDetailsElement>('[data-testid="keeper-lane-waiting-row"] details')
    expect(disclosure).not.toBeNull()
    disclosure!.open = true
    disclosure!.dispatchEvent(new Event('toggle'))
    expect(disclosure!.textContent ?? '').toContain('wake producer')
    expect(disclosure!.textContent ?? '').toContain('keeper_owner_actor')
  })

  it('marks a server-capped count as a lower bound instead of a total', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${truncatedInventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const text = el.textContent ?? ''
    expect(text).toContain('≥69')
    // the bare integer would assert a total the server never computed
    expect(text).not.toMatch(/작업 대기열\s*69(?!\d)/)
    expect(el.querySelectorAll('[data-testid="keeper-lane-waiting-row"]').length).toBe(69)
  })

  it('attributes the truncation to the capped source and the server limit', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${truncatedInventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const note = el.querySelector('[data-testid="keeper-lane-truncation"]')?.textContent ?? ''
    expect(note).toContain('외부 알림')
    expect(note).toContain('64')
    expect(note).toContain('실제 대기 건수는 더 많습니다')
  })

  it('bounds only the sources the server reported as capped', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${truncatedInventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const sources = el.querySelector('[data-testid="keeper-lane-sources"]')?.textContent ?? ''
    expect(sources).toContain('외부 알림 ≥64')
    // chat_operation_queued was not capped, so it is an exact count
    expect(sources).toContain('채팅 대기 5')
    expect(sources).not.toContain('채팅 대기 ≥5')
  })

  it('renders an exact count and no truncation note when nothing was capped', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    expect(el.textContent ?? '').not.toContain('≥')
    expect(el.querySelector('[data-testid="keeper-lane-truncation"]')).toBeNull()
  })

  it('renders no transport/freshness caption row', () => {
    // The strip used to append "서버 기준 <시각> · WS 즉시 반영" under every
    // queue. That caption described the transport, not the queue, and was
    // removed for layout room — the data itself is the freshness signal.
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
    expect(text).not.toContain('서버 기준')
    expect(text).not.toContain('WS 즉시 반영')
    expect(text).not.toContain('기다리는 작업이 없습니다')
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

  it('renders every row read-only without operator actions', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${eventInventory()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    expect(el.querySelectorAll('[data-testid="keeper-lane-waiting-row"]').length).toBe(2)
    expect(el.querySelector('[data-testid="keeper-lane-event-actions"]')).toBeNull()
    expect(el.querySelector('[data-testid="keeper-lane-event-recoveries"]')).toBeNull()
  })

  it('addresses the operator mutation with the row\'s own source ref and incarnation', () => {
    const actions = fakeActions()
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${eventInventory()}
        ready=${true}
        loading=${false}
        error=${null}
        eventActions=${actions}
      />
    `)
    // Only the event-queue row gets actions; the chat row is another store.
    const actionGroups = el.querySelectorAll('[data-testid="keeper-lane-event-actions"]')
    expect(actionGroups.length).toBe(1)
    const labels = Array.from(actionGroups[0]!.querySelectorAll('button')).map(button => button.textContent)
    expect(labels).toEqual(['immediate', 'normal', 'low', '이관', '취소'])

    fireEvent.click(Array.from(actionGroups[0]!.querySelectorAll('button')).find(b => b.textContent === 'low')!)
    expect(actions.operate).toHaveBeenCalledWith(`event:${SOURCE_REF}`, {
      action: 'reprioritize',
      sourceRef: SOURCE_REF,
      sourceIncarnation: '17',
      urgency: 'low',
    })

    vi.stubGlobal('prompt', vi.fn(() => 'rondo'))
    fireEvent.click(Array.from(actionGroups[0]!.querySelectorAll('button')).find(b => b.textContent === '이관')!)
    expect(actions.operate).toHaveBeenCalledWith(`event:${SOURCE_REF}`, {
      action: 'transfer',
      sourceRef: SOURCE_REF,
      sourceIncarnation: '17',
      targetKeeper: 'rondo',
    })

    vi.stubGlobal('prompt', vi.fn(() => null))
    fireEvent.click(Array.from(actionGroups[0]!.querySelectorAll('button')).find(b => b.textContent === '취소')!)
    expect(actions.operate).toHaveBeenCalledTimes(2)
    vi.unstubAllGlobals()
  })

  it('disables the row whose mutation is in flight', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${eventInventory()}
        ready=${true}
        loading=${false}
        error=${null}
        eventActions=${fakeActions({ pendingKey: `event:${SOURCE_REF}` })}
      />
    `)
    const buttons = Array.from(el.querySelectorAll('[data-testid="keeper-lane-event-actions"] button'))
    expect(buttons.length).toBe(5)
    expect(buttons.every(button => (button as HTMLButtonElement).disabled)).toBe(true)
  })

  it('renders an explicit gap instead of buttons when the row carries no address', () => {
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${eventInventory(eventRow({ source_ref: undefined, source_incarnation: undefined }))}
        ready=${true}
        loading=${false}
        error=${null}
        eventActions=${fakeActions()}
      />
    `)
    expect(el.querySelector('[data-testid="keeper-lane-event-actions"]')).toBeNull()
    expect(el.querySelector('[data-testid="keeper-lane-event-address-missing"]')?.textContent).toContain('항목 주소 미수신')
  })

  it('offers a replay for an operation whose commit state is unconfirmed', () => {
    const operation = {
      action: 'cancel' as const,
      sourceRef: SOURCE_REF,
      sourceIncarnation: '17',
      reason: 'duplicate wake',
      operationId: 'op-1',
    }
    const actions = fakeActions({
      error: 'Event queue mutation committed, but projection follow-up failed (t-1): disk',
      recoveries: [{ operation, commitState: 'committed', message: 'projection follow-up failed' }],
    })
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${eventInventory()}
        ready=${true}
        loading=${false}
        error=${null}
        eventActions=${actions}
      />
    `)
    expect(el.querySelector('[data-testid="keeper-lane-event-error"]')?.textContent).toContain('projection follow-up failed')
    const recoveries = el.querySelector('[data-testid="keeper-lane-event-recoveries"]')!
    expect(recoveries.textContent).toContain('source commit 완료 · 후속 확인 필요')
    expect(recoveries.textContent).toContain('op-1')
    fireEvent.click(recoveries.querySelector('button')!)
    expect(actions.operate).toHaveBeenCalledWith('event-recovery:op-1', operation)
  })
})
