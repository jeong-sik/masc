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
    // The operator sentence is the default reading; the wire vocabulary stays
    // behind the 기술 상세 toggle.
    expect(text).toContain('운영자 채팅 1건 대기')
    expect(text).toContain('운영자와 진행 중인 대화')
    expect(text).not.toContain('owner_fifo')
    expect(text).not.toContain('keeper_finish_in_flight_turn')
    expect(el.querySelector('[data-missing="keeper-lane"]')).toBeNull()

    fireEvent.click(el.querySelector('[data-testid="keeper-lane-dev-toggle"]')!)
    const devText = el.textContent ?? ''
    expect(devText).toContain('owner_fifo')
    expect(devText).toContain('keeper_turn')
    expect(devText).toContain('keeper_finish_in_flight_turn')
    expect(devText).toContain('keeper_owner_actor')
  })

  it('renders the queue oldest first on an age axis without claiming processing priority', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-08-09T00:00:00Z'))
    const inventory = inventoryFixture()
    inventory.keepers[0]!.waiting_on = [
      {
        keeper_name: 'sangsu',
        source: 'event_queue_pending',
        waiting_on: 'discord-old',
        what: 'discord-old 멘션',
        wake_producer: 'connector_attention_hook',
        since_iso: '2026-08-06T03:59:42Z',
        next_action: 'keeper_drain_event_queue',
        detail: { event_id: 'evt-old' },
      },
      {
        keeper_name: 'sangsu',
        source: 'event_queue_pending',
        waiting_on: 'discord-new',
        what: 'discord-new 멘션',
        wake_producer: 'connector_attention_hook',
        since_iso: '2026-08-08T10:12:03Z',
        next_action: 'keeper_drain_event_queue',
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
      'discord-old',
      'masc.keeper_wake',
      'discord-new',
    ])
    expect(el.querySelector('[data-testid="keeper-lane-graph"]')).not.toBeNull()
    const renderedTimes = Array.from(el.querySelectorAll('[data-testid="keeper-lane-waiting-time"] time'))
    expect(renderedTimes.map(time => time.getAttribute('datetime'))).toEqual([
      '2026-08-06T03:59:42Z',
      '2026-08-08T06:39:09Z',
      '2026-08-09T07:29:34Z',
      '2026-08-08T10:12:03Z',
    ])
    // Bar width is the waited age on a log axis: the 3-day row fills the
    // strip, the 14-hour row sits below it, and the 1일 tick lands at the
    // position of a one-day wait rather than at the right edge.
    const widths = Array.from(el.querySelectorAll<HTMLElement>('[data-testid="keeper-lane-waiting-bar"]'))
      .map(bar => Number.parseFloat(bar.style.width))
    expect(widths[0]).toBe(100)
    expect(widths[1]!).toBeLessThan(widths[0]!)
    expect(widths[2]!).toBeLessThan(widths[1]!)
    const dayTick = el.querySelector<HTMLElement>('[data-axis-tick="1일"]')!
    expect(Number.parseFloat(dayTick.style.left)).toBeLessThan(100)
    // 2026-08-06T03:59 → 2026-08-09T00:00 is 2.83 days: the axis end reads 3일.
    expect(el.querySelector('[data-axis-tick="3일"]')).not.toBeNull()
    expect(el.textContent ?? '').toContain('오래 기다린 순서')
    expect(el.textContent ?? '').not.toContain('HEAD')
    expect(el.textContent ?? '').not.toContain('처리 우선순위')
    expect(el.textContent ?? '').toContain('3일 전')
    expect(el.textContent ?? '').toContain('실행 예정')
    expect(el.textContent ?? '').toContain('7시간 후')
    expect(el.textContent ?? '').not.toContain('실행 예정 · 지금')
  })

  it('keeps the 1일 tick at the right edge while nothing has waited a day', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-07-07T09:00:00Z'))
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventoryFixture()}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const dayTick = el.querySelector<HTMLElement>('[data-axis-tick="1일"]')!
    expect(Number.parseFloat(dayTick.style.left)).toBe(100)
    const hourTick = el.querySelector<HTMLElement>('[data-axis-tick="1시간"]')!
    expect(Number.parseFloat(hourTick.style.left)).toBeGreaterThan(50)
    expect(Number.parseFloat(hourTick.style.left)).toBeLessThan(60)
    // Two rows, two and one minutes old: the older one is wider, and both
    // sit near the left of a day-long axis.
    const widths = Array.from(el.querySelectorAll<HTMLElement>('[data-testid="keeper-lane-waiting-bar"]'))
      .map(bar => Number.parseFloat(bar.style.width))
    expect(widths.length).toBe(2)
    expect(widths[0]!).toBeGreaterThan(widths[1]!)
    expect(widths[1]!).toBeGreaterThanOrEqual(6)
    expect(widths[0]!).toBeLessThan(20)
  })

  it('groups the server source counts into the stage pipeline', () => {
    const inventory = inventoryFixture()
    inventory.keepers[0]!.sources = {
      event_queue_pending: 2,
      schedule_waiting: 1,
      chat_operation_queued: 1,
      chat_operation_running: 1,
    }
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventory}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const stages = Array.from(el.querySelectorAll('[data-testid="keeper-lane-pipeline"] [data-stage]'))
    expect(stages.map(stage => `${stage.getAttribute('data-stage')}:${stage.getAttribute('data-active')}`)).toEqual([
      'external:false',
      'schedule:true',
      'queue:true',
      'operator:false',
      'keeper:true',
    ])
    const queueStage = el.querySelector('[data-stage="queue"]')!
    expect(queueStage.textContent).toContain('채팅 대기')
    expect(queueStage.textContent).toContain('1')
    expect(queueStage.textContent).not.toContain('keeper_event_queue')
    fireEvent.click(el.querySelector('[data-testid="keeper-lane-dev-toggle"]')!)
    expect(el.querySelector('[data-stage="queue"]')!.textContent).toContain('keeper_event_queue')
    expect(el.querySelector('[data-stage="queue"]')!.textContent).toContain('chat_operation_queued')
  })

  it('keeps a source key outside the closed vocabulary visible instead of filing it into a stage', () => {
    const inventory = inventoryFixture()
    inventory.keepers[0]!.sources = { chat_operation_queued: 1, not_a_source: 3 }
    const el = mount(html`
      <${KeeperLaneStrip}
        keeper=${keeperFixture()}
        inventory=${inventory}
        ready=${true}
        loading=${false}
        error=${null}
      />
    `)
    const unknown = el.querySelector('[data-stage="unknown"]')!
    expect(unknown.textContent).toContain('미분류 source')
    expect(unknown.textContent).toContain('not_a_source')
    expect(unknown.textContent).toContain('3')
    expect(el.querySelector('[data-stage="queue"]')!.textContent).not.toContain('not_a_source')
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
    const disclosure = el.querySelector<HTMLDetailsElement>('[data-testid="keeper-lane-waiting-row"]')
    expect(disclosure).not.toBeNull()
    expect(disclosure!.tagName).toBe('DETAILS')
    expect(disclosure!.textContent ?? '').not.toContain('wake ·')
    fireEvent.click(el.querySelector('[data-testid="keeper-lane-dev-toggle"]')!)
    disclosure!.open = true
    disclosure!.dispatchEvent(new Event('toggle'))
    expect(disclosure!.textContent ?? '').toContain('wake ·')
    expect(disclosure!.textContent ?? '').toContain('keeper_owner_actor')
    expect(disclosure!.textContent ?? '').toContain('다음 동작 ·')
    expect(disclosure!.querySelector('[data-testid="keeper-lane-waiting-time"] time')).not.toBeNull()
  })

  it('renders an exact count', () => {
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
        keeper=${keeperFixture({ name: 'ghost' })}
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
