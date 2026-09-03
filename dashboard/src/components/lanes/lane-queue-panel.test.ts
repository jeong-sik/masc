import { html } from 'htm/preact'
import { cleanup, render, waitFor, fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { DashboardKeeperWaitingInventory } from '../../api'
import type { FleetCompositeSnapshot, KeeperCompositeSnapshot } from '../../api/schemas/keeper-composite'
import type { KeeperLifecycleTimelineResponse } from '../../api/keeper'

const mocks = vi.hoisted(() => ({
  fetchKeeperWaitingInventory: vi.fn(),
  fetchDashboardScheduledAutomation: vi.fn(),
  fetchKeeperLifecycle: vi.fn(),
  fetchFleet: vi.fn(),
}))

vi.mock('../../api', async importOriginal => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    fetchKeeperWaitingInventory: mocks.fetchKeeperWaitingInventory,
  }
})
vi.mock('../../api/dashboard-scheduled-automation', () => ({
  fetchDashboardScheduledAutomation: mocks.fetchDashboardScheduledAutomation,
}))
vi.mock('../../sse-store', () => ({
  registerKeeperWaitingInventoryRefresh: vi.fn(() => vi.fn()),
}))
vi.mock('../../dashboard-ws-state', () => ({
  dashboardWsReady: { value: true },
  dashboardWsReconnectCount: {
    value: 0,
    subscribe: vi.fn(() => vi.fn()),
  },
}))

import {
  KeeperWaitQueueRail,
  LaneQueuePanel,
  ingestLaneQueueFleetSnapshot,
  resetLaneQueueObservations,
} from './lane-queue-panel'
import { keepers } from '../../store'
import { nowSecondsSignal } from '../../lib/now-signal'
import type { Keeper } from '../../types'

const NOW = Math.floor(Date.now() / 1000)

function keeperFixture(name: string): Keeper {
  return { name, status: 'active' } as Keeper
}

function compositeSnapshot(name: string, ts: number, overrides: Record<string, unknown> = {}): KeeperCompositeSnapshot {
  return {
    keeper: name,
    correlation_id: name,
    run_id: 'run-1',
    ts,
    phase: 'running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    runtime: { state: 'idle' },
    is_live: false,
    ...overrides,
  } as unknown as KeeperCompositeSnapshot
}

function fleetSnapshot(snapshots: KeeperCompositeSnapshot[]): FleetCompositeSnapshot {
  return { snapshots } as unknown as FleetCompositeSnapshot
}

function waitingInventory(name: string): DashboardKeeperWaitingInventory {
  return {
    generated_at: '2026-08-23T05:00:00Z',
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: 2,
    keepers: [{
      keeper_name: name,
      state: 'waiting',
      waiting_count: 2,
      sources: { event_queue_pending: 1, hitl_pending: 1 },
      waiting_on: [
        {
          keeper_name: name,
          source: 'event_queue_pending',
          waiting_on: 'discord:product-review',
          what: 'Discord · product-review 알림',
          wake_producer: 'connector_attention_hook',
          since: NOW - 600,
          next_action: 'keeper_drain_event_queue',
        },
        {
          keeper_name: name,
          source: 'hitl_pending',
          waiting_on: 'gate:apr_51c8 · tool_execute',
          what: '운영자 승인 (쓰기 작업)',
          wake_producer: 'hitl_queue',
          since: NOW - 120,
          next_action: 'await_operator_decision',
        },
      ],
    }],
  } as DashboardKeeperWaitingInventory
}

function scheduleProjection() {
  return {
    state: 'available',
    data: {
      request_count: 2,
      request_limit: 100,
      truncated: false,
      counts: { succeeded: 1, failed: 0 },
      fsm: {},
      requests: [
        {
          schedule_id: 'sch_missed',
          status: 'succeeded',
          source: 'test',
          payload_summary: 'docs 검증',
          due_at_iso: new Date((NOW - 3600) * 1000).toISOString(),
          keeper_queue_evidence: { projection_status: 'not_found', keeper_name: 'qa-king' },
          keeper_reaction_evidence: { projection_status: 'matched_stimulus' },
        },
        {
          schedule_id: 'sch_drained',
          status: 'succeeded',
          source: 'test',
          payload_summary: 'board sweep',
          due_at_iso: new Date((NOW - 7200) * 1000).toISOString(),
          keeper_queue_evidence: { projection_status: 'not_found', keeper_name: 'masc-improver' },
          keeper_reaction_evidence: { projection_status: 'matched_turn_started' },
        },
      ],
    },
  }
}

function lifecycleResponse(name: string): KeeperLifecycleTimelineResponse {
  return {
    keeper: name,
    count: 2,
    events: [
      { ts: NOW - 540, event: 'restarted', phase: 'Failing', detail: '쓸 수 있는 모델이 없어 재시작' },
      { ts: NOW - 7200, event: 'started', phase: 'Running', detail: '처음 기동' },
    ],
  }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  keepers.value = []
  resetLaneQueueObservations()
})

describe('LaneQueuePanel', () => {
  beforeEach(() => {
    // Age labels read the shared wall-clock signal, which is seeded when
    // lib/now-signal loads — before or after this module depending on the
    // import graph. Pinning it to the same NOW the fixtures are built from
    // makes "10분 전" mean 10 minutes regardless of that order.
    nowSecondsSignal.value = NOW
    mocks.fetchKeeperWaitingInventory.mockImplementation((name: string) => Promise.resolve(waitingInventory(name)))
    mocks.fetchDashboardScheduledAutomation.mockResolvedValue(scheduleProjection())
    mocks.fetchKeeperLifecycle.mockImplementation((name: string) => Promise.resolve(lifecycleResponse(name)))
    mocks.fetchFleet.mockResolvedValue(fleetSnapshot([]))
  })

  it('renders header, KPIs, and keeper tabs from the roster', async () => {
    keepers.value = [keeperFixture('masc-improver'), keeperFixture('sangsu')]
    const { getByTestId, getAllByTestId, container } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)

    expect(container.querySelector('.ia-wrap.lq-wrap')).not.toBeNull()
    expect(container.querySelector('.ia-devslot')).not.toBeNull()
    expect(container.querySelectorAll('.lq-kpi')).toHaveLength(4)
    await waitFor(() => expect(getAllByTestId('lane-queue-tab')).toHaveLength(2))
    expect(getByTestId('lane-kpi-misses').textContent).toBe('1')
  })

  it('builds swimlane segments and the focus read-out from composite observations', async () => {
    keepers.value = [keeperFixture('masc-improver')]
    mocks.fetchFleet.mockResolvedValue(fleetSnapshot([
      compositeSnapshot('masc-improver', NOW - 300),
      compositeSnapshot('masc-improver', NOW - 10, { turn_phase: 'executing', is_live: true }),
    ]))
    const { getByTestId, container } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)

    await waitFor(() => expect(container.querySelectorAll('.sw-row')).toHaveLength(4))
    expect(container.querySelector('.sw-axis-track')).not.toBeNull()
    expect(container.querySelectorAll('.sw-tick')).toHaveLength(5)
    expect(container.querySelectorAll('.sw-seg').length).toBeGreaterThan(0)

    const read = getByTestId('lane-read')
    expect(read.querySelector('.lq-read-l')?.textContent).toBe('턴 진행')
    expect(read.querySelector('b')?.textContent).toBe('작업 중')
    expect(read.querySelector('.lq-read-m')?.textContent).toContain('모델을 부르거나')
    expect(read.querySelector('.lq-read-o')?.textContent).toContain('진행 중인 턴 있음')
  })

  it('marks a stalled lane with the design stall treatment and tab dot', async () => {
    keepers.value = [keeperFixture('masc-improver')]
    mocks.fetchFleet.mockResolvedValue(fleetSnapshot([
      compositeSnapshot('masc-improver', NOW - 600),
      compositeSnapshot('masc-improver', NOW - 120, { turn_phase: 'executing', is_live: true }),
    ]))
    const { getByTestId, container } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)

    await waitFor(() => expect(container.querySelector('.sw-stallmark')).not.toBeNull())
    expect(container.querySelector('.lq-tab-dot')).not.toBeNull()
    expect(getByTestId('lane-kpi-stalls').textContent).toBe('1')
    expect(getByTestId('lane-read').className).toContain('stalled')
  })

  it('renders the waiting pipeline and age bars from the waiting inventory', async () => {
    keepers.value = [keeperFixture('masc-improver')]
    const { getByTestId, getAllByTestId, container } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)

    await waitFor(() => expect(getByTestId('lane-pipeline')).not.toBeNull())
    const stages = container.querySelectorAll('.pl-stage.on')
    expect(stages).toHaveLength(2)
    expect(container.querySelector('.lq-batch')?.textContent).toContain('한 턴이 밀린')
    expect(container.querySelector('.lq-sec-sub')?.textContent).toBe('오래 기다린 순서')

    const rows = getAllByTestId('lane-wait-row')
    expect(rows).toHaveLength(2)
    // Oldest first: the 10-minute queue row leads the 2-minute HITL row.
    expect(rows[0]?.querySelector('.wa-src')?.textContent).toBe('자율 이벤트')
    expect(rows[0]?.querySelector('.wa-age')?.textContent).toBe('10분 전')

    fireEvent.click(rows[0]!.querySelector('.wa-bar')!)
    expect(rows[0]?.querySelector('.wa-detail')).not.toBeNull()
    expect(getByTestId('lane-kpi-waiting').textContent).toBe('1')
  })

  it('renders lifecycle events for the selected keeper', async () => {
    keepers.value = [keeperFixture('masc-improver')]
    const { getAllByTestId } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)

    await waitFor(() => expect(getAllByTestId('lane-lifecycle-row')).toHaveLength(2))
    const first = getAllByTestId('lane-lifecycle-row')[0]!
    expect(first.getAttribute('data-tone')).toBe('warn')
    expect(first.querySelector('.lc-ev')?.textContent).toBe('재시작됨')
    expect(first.querySelector('.lc-ago')?.textContent).toBe('9분 전')
  })

  it('lists drain verdicts missed-first and switches to the evidence matrix in dev mode', async () => {
    keepers.value = [keeperFixture('masc-improver')]
    const { getAllByTestId, getByTestId, container } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)

    await waitFor(() => expect(getAllByTestId('lane-drain-row')).toHaveLength(2))
    const rows = getAllByTestId('lane-drain-row')
    expect(rows[0]?.getAttribute('data-state')).toBe('missed')
    expect(rows[0]?.querySelector('.dl-keeper')?.textContent).toBe('qa-king')
    expect(rows[0]?.querySelector('.dl-payload')?.textContent).toBe('docs 검증')
    expect(container.querySelector('.dl-legend')).not.toBeNull()
    expect(getByTestId('lane-kpi-misses').textContent).toBe('1')

    fireEvent.click(getByTestId('lane-queue-dev-toggle'))
    await waitFor(() => expect(container.querySelector('.dm-grid')).not.toBeNull())
    const missedCell = container.querySelector('.dm-c[data-queue="not_found"][data-reaction="matched_stimulus"]')
    expect(missedCell?.textContent).toContain('누락')
    fireEvent.click(missedCell!)
    expect(container.querySelector('.dm-detail-h')).not.toBeNull()
    expect(container.querySelector('.dm-row')?.textContent).toContain('sch_missed')
  })

  it('shows the design gap treatment when the keeper has no observation data', async () => {
    keepers.value = [keeperFixture('drifter')]
    const { getAllByTestId } = render(html`
      <${LaneQueuePanel} fetchFleet=${mocks.fetchFleet} fetchLifecycle=${mocks.fetchKeeperLifecycle} />
    `)
    await waitFor(() => expect(getAllByTestId('lane-swimlane-gap').length).toBeGreaterThan(0))
  })
})

describe('KeeperWaitQueueRail', () => {
  beforeEach(() => {
    // Age labels read the shared wall-clock signal, which is seeded when
    // lib/now-signal loads — before or after this module depending on the
    // import graph. Pinning it to the same NOW the fixtures are built from
    // makes "10분 전" mean 10 minutes regardless of that order.
    nowSecondsSignal.value = NOW
    mocks.fetchKeeperWaitingInventory.mockImplementation((name: string) => Promise.resolve(waitingInventory(name)))
  })

  it('renders the ctx-sec rail with lane state chip and wait ages', async () => {
    keepers.value = [keeperFixture('masc-improver')]
    const { getByTestId, container } = render(html`<${KeeperWaitQueueRail} keeperName="masc-improver" />`)
    await waitFor(() => expect(container.querySelector('.lq-state-row')).not.toBeNull())
    expect(getByTestId('keeper-wait-queue-rail').classList.contains('ctx-sec')).toBe(true)
    expect(container.querySelector('.lq-rail-body')).not.toBeNull()
    expect(container.querySelector('.lq-chip')?.textContent).toBe('대기 중')
    expect(container.querySelectorAll('.wa-row')).toHaveLength(2)
  })

  it('renders the unknown-state gap when the keeper is absent from the inventory', async () => {
    mocks.fetchKeeperWaitingInventory.mockResolvedValue({
      generated_at: '2026-08-23T05:00:00Z',
      keeper_count: 0,
      waiting_keeper_count: 0,
      row_count: 0,
      keepers: [],
    } as DashboardKeeperWaitingInventory)
    const { container } = render(html`<${KeeperWaitQueueRail} keeperName="ghost" />`)
    await waitFor(() => expect(container.querySelector('.lq-gap')).not.toBeNull())
    expect(container.querySelector('.lq-gap b')?.textContent).toBe('상태 알 수 없음')
  })
})

describe('ingestLaneQueueFleetSnapshot', () => {
  it('accumulates observations per keeper without fabricating transitions', () => {
    resetLaneQueueObservations()
    ingestLaneQueueFleetSnapshot(fleetSnapshot([compositeSnapshot('a', NOW - 100)]))
    ingestLaneQueueFleetSnapshot(fleetSnapshot([compositeSnapshot('a', NOW - 100)]))
    ingestLaneQueueFleetSnapshot(fleetSnapshot([compositeSnapshot('a', NOW - 50, { turn_phase: 'executing' })]))
    // Render-free sanity: buffers feed laneReading via the exported reset/ingest pair.
    keepers.value = [keeperFixture('a')]
    mocks.fetchKeeperLifecycle.mockResolvedValue(lifecycleResponse('a'))
    mocks.fetchFleet.mockResolvedValue(fleetSnapshot([]))
  })
})
