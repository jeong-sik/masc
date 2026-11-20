import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardKeeperWaitingInventory,
  DashboardScheduledAutomationAvailableData,
  DashboardScheduledAutomationProjection,
  DashboardScheduledAutomationRequest,
} from '../../api'

type MockToolsResponse = {
  generated_at?: string
  tool_inventory: { tools: unknown[] }
  tool_usage: Record<string, unknown>
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
}

const mocks = vi.hoisted(() => ({
  loadTools: vi.fn(),
  toolsData: { value: null as null | MockToolsResponse },
  toolsLoading: { value: false },
  loadScheduledAutomation: vi.fn(),
  scheduledAutomationProjection: { value: null as null | DashboardScheduledAutomationProjection },
  scheduledAutomationLoading: { value: false },
  scheduledAutomationError: { value: null as string | null },
  subscribeScheduledAutomationRefresh: vi.fn(() => () => {}),
  activeSchedulesProjection: { value: null as null | DashboardScheduledAutomationProjection },
  activeSchedulesError: { value: null as string | null },
  stopActiveSchedulesRefresh: vi.fn(),
  subscribeActiveSchedulesRefresh: vi.fn(),
  pruneSchedules: vi.fn(),
  fetchScheduledAutomationLookup: vi.fn(),
  replaceRoute: vi.fn(),
  route: {
    value: {
      tab: 'schedule',
      params: {} as Record<string, string>,
      postId: null,
    },
  },
}))

vi.mock('../tools/tool-state', () => ({
  loadTools: mocks.loadTools,
  toolsData: mocks.toolsData,
  toolsLoading: mocks.toolsLoading,
}))

vi.mock('./schedule-state', () => ({
  loadScheduledAutomation: mocks.loadScheduledAutomation,
  scheduledAutomationProjection: mocks.scheduledAutomationProjection,
  scheduledAutomationError: mocks.scheduledAutomationError,
  scheduledAutomationLoading: mocks.scheduledAutomationLoading,
  subscribeScheduledAutomationRefresh: mocks.subscribeScheduledAutomationRefresh,
  activeSchedulesProjection: mocks.activeSchedulesProjection,
  activeSchedulesError: mocks.activeSchedulesError,
  subscribeActiveSchedulesRefresh: mocks.subscribeActiveSchedulesRefresh,
}))

vi.mock('../../api/dashboard-schedule', () => ({
  pruneSchedules: mocks.pruneSchedules,
}))

vi.mock('../../api/dashboard-scheduled-automation', async () => {
  const actual = await vi.importActual<typeof import('../../api/dashboard-scheduled-automation')>(
    '../../api/dashboard-scheduled-automation',
  )
  return {
    ...actual,
    fetchDashboardScheduledAutomationLookup: mocks.fetchScheduledAutomationLookup,
  }
})

vi.mock('../../router', () => ({
  route: mocks.route,
  replaceRoute: mocks.replaceRoute,
}))

import { ScheduleSurface } from './schedule-surface'

function sampleAutomation(): DashboardScheduledAutomationAvailableData {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    source: 'schedule_runner_signals',
    generated_at: '2026-06-21T00:00:00Z',
    status: 'ok',
    schedule_store_known: true,
    schedule_store_read_error: null,
    request_count: 1,
    request_limit: 20,
    truncated: false,
    counts: { scheduled: 3, due: 1, running: 1 },
    fsm: {
      state: 'due',
      active_count: 1,
      terminal_count: 0,
      next_due_at: '2026-06-21T01:00:00Z',
    },
    signal_count: 1,
    signals: [
      {
        occurrence_id: 'sig-1',
        kind: 'schedule.due_candidate',
        event_type: 'schedule.due_candidate',
        schedule_id: 'sched-1',
        emitted_at_iso: '2026-06-21T00:30:00Z',
      },
    ],
    requests: [
      {
        schedule_id: 'sched-1',
        status: 'due',
        source: 'operator_request',
        requested_by: { id: 'operator', kind: 'human_operator', display_name: null },
        scheduled_by: { id: 'scheduler-agent', kind: 'automated_actor', display_name: null },
        recurrence: { kind: 'one_shot' },
        recurrence_kind: 'one_shot',
        payload_kind: 'keeper.review',
        due_at_iso: '2026-06-21T01:00:00Z',
      },
    ],
  }
}

function availableProjection(
  data: DashboardScheduledAutomationAvailableData,
): DashboardScheduledAutomationProjection {
  return {
    state: 'available',
    data,
    page: {
      visibleCount: data.requests.length,
      totalCount: data.request_count,
      limit: data.request_limit,
      truncated: data.truncated,
    },
  }
}

/** The active-only page, which the calendar draws. */
function setActiveSchedules(data: DashboardScheduledAutomationAvailableData): void {
  mocks.activeSchedulesProjection.value = availableProjection(data)
}

/** The fleet page. The calendar's page holds the same rows unless a test
 *  hands it another with `setActiveSchedules`. */
function setAutomation(data: DashboardScheduledAutomationAvailableData): void {
  mocks.scheduledAutomationProjection.value = availableProjection(data)
  setActiveSchedules(data)
}

function sampleWaitingInventory(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v3',
    source: 'server_keeper_waiting_inventory',
    keeper_count_known: true,
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: 1,
    global_row_count: 1,
    global_pending_confirm_count: 0,
    source_counts: {
      schedule_waiting: 1,
    },
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'waiting',
        state_sources: ['schedule_waiting'],
        waiting_count: 1,
        sources: { schedule_waiting: 1 },
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'schedule_waiting',
            waiting_on: 'masc.board_post',
            what: '예약 실행 · masc.board_post',
            since_iso: '2026-07-04T00:00:00Z',
            next_action: 'schedule_runner_dispatch',
          },
        ],
      },
    ],
    global_waiting_on: [
      {
        source: 'schedule_waiting',
        waiting_on: 'masc.board_post',
        what: '예약 실행 · masc.board_post',
        due_at_iso: '2026-07-04T01:00:00Z',
        next_action: 'schedule_runner_dispatch',
      },
    ],
  }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

describe('ScheduleSurface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.loadTools.mockClear()
    mocks.pruneSchedules.mockReset()
    mocks.toolsData.value = null
    mocks.toolsLoading.value = false
    mocks.loadScheduledAutomation.mockClear()
    mocks.subscribeScheduledAutomationRefresh.mockClear()
    mocks.scheduledAutomationProjection.value = null
    mocks.scheduledAutomationLoading.value = false
    mocks.scheduledAutomationError.value = null
    mocks.activeSchedulesProjection.value = null
    mocks.activeSchedulesError.value = null
    mocks.stopActiveSchedulesRefresh.mockReset()
    mocks.subscribeActiveSchedulesRefresh.mockReset()
    mocks.subscribeActiveSchedulesRefresh.mockReturnValue(mocks.stopActiveSchedulesRefresh)
    mocks.fetchScheduledAutomationLookup.mockReset()
    mocks.replaceRoute.mockReset()
    mocks.route.value = { tab: 'schedule', params: {}, postId: null }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('loads the tools projection when the dedicated schedule surface mounts', async () => {
    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(mocks.loadTools).toHaveBeenCalledTimes(1)
    expect(container.querySelector('[data-testid="schedule-surface"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="schedule-reality-notice"]')?.textContent)
      .toContain('관측 전용')
    expect(container.querySelector('[data-testid="schedule-reality-notice"]')?.textContent)
      .toContain('keeper turn을 자동 구동하지 않습니다')
    // Calendar is the default view. With no projection nothing was read, so
    // no calendar is drawn: empty days and an empty polling strip would be
    // statements about schedules nobody has looked at.
    expect(container.querySelector('[data-testid="schedule-viewbar"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="sch-agenda"]')).toBeNull()
    expect(container.querySelector('[data-testid="sch-agenda-empty"]')).toBeNull()
    expect(container.querySelector('[data-testid="sch-polling-empty"]')).toBeNull()
    // Nor cadence counts, which would read zero.
    expect(container.querySelector('[data-testid="sch-cadsum"]')).toBeNull()
    expect(container.textContent).toContain('예약 자동화 projection 없음')
  })

  it('renders backed schedule summary and reuses read-only schedule cards', async () => {
    setAutomation(sampleAutomation())
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      keeper_waiting_inventory: sampleWaitingInventory(),
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(mocks.loadTools).not.toHaveBeenCalled()
    // v2 reskin: the KPI summary strip is now `.ov-kpis` (aria-label '예약 요약')
    // with Korean labels; due and running fold into one lifecycle KPI.
    const summary = container.querySelector('[aria-label="예약 요약"]')
    expect(summary?.textContent).toContain('due · 실행')
    expect(summary?.textContent).toContain('예약됨')
    expect(summary?.textContent).toContain('총 예약')
    // The folded summary still must not leak the diagnostics-only derived/FSM
    // vocabulary (활성/유효 도래) as separate KPIs.
    expect(summary?.textContent).not.toContain('활성')
    expect(summary?.textContent).not.toContain('유효 도래')
    // The diagnostic wake-signal feed lives in the 목록 (list) view; the surface
    // now defaults to the 캘린더 view, so toggle before asserting the feed.
    container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
    await flush()
    container.querySelector<HTMLButtonElement>('[data-schedule-filter="due"]')?.click()
    await flush()
    expect(container.textContent).toContain('wake signal 피드 · schedule_runner.tick')
    // The keeper-lane diagnostics are collapsed AND lazy-mounted by
    // default; open them before asserting their content.
    expect(container.querySelector('[data-testid="schedule-keeper-lanes"]')).toBeNull()
    container.querySelector<HTMLButtonElement>('[data-testid="schedule-diagnostics-toggle"]')?.click()
    await flush()
    expect(container.querySelector('[data-testid="schedule-keeper-lanes"]')?.textContent)
      .toContain('Keeper Lanes · wake evidence')
    expect(container.querySelector('[data-testid="schedule-keeper-lanes"]')?.textContent)
      .toContain('sangsu')
    expect(container.querySelector('[data-testid="schedule-keeper-lanes"]')?.textContent)
      .toContain('masc.board_post')
    // REMOVED: '출처 <signal_source>' feed attribution line is not rendered on
    // the v2 surface (it is diagnostics-only); no equivalent element exists to
    // retarget, so this coverage is dropped rather than weakened.
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
  })

  it('renders the read-only operations aside in a two-column shell', async () => {
    setAutomation(sampleAutomation())
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    // Two-column shell so the aside sits as a right rail beside the scroll column.
    expect(container.querySelector('main.ov-2col')).not.toBeNull()
    const aside = container.querySelector('[data-testid="schedule-aside"]')
    expect(aside).not.toBeNull()
    expect(aside?.querySelector('.wka-pulse')).not.toBeNull()
    // The aside is derived read-only: no mutation controls anywhere on the surface.
    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
  })

  it('merges sparse backend counts with materialized scheduled statuses', async () => {
    const automation = sampleAutomation()
    automation.counts = { scheduled: 1 }
    automation.requests = [
      {
        ...automation.requests[0]!,
        status: 'scheduled',
      },
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-later',
        status: 'scheduled',
      },
    ]
    setAutomation(automation)
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const scheduledKpi = Array.from(container.querySelectorAll('.ov-kpi'))
      .find(element => element.textContent?.includes('예약됨'))
    expect(scheduledKpi?.textContent).toContain('2')
  })

  it('counts genuine queue-drain misses in the KPI (not_found queue AND not_found reaction)', async () => {
    const automation = sampleAutomation()
    automation.requests = [
      // Healthy completion: not in queue but the keeper reacted → not a miss.
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-drained',
        keeper_queue_evidence: { projection_status: 'not_found' },
        keeper_reaction_evidence: { projection_status: 'matched_turn_started' },
      },
      // Genuine miss: dispatched, in no queue, no keeper reaction recorded.
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-miss',
        keeper_queue_evidence: { projection_status: 'not_found' },
        keeper_reaction_evidence: { projection_status: 'not_found' },
      },
    ]
    setAutomation(automation)
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const missKpi = container.querySelector('[data-testid="schedule-kpi-queue-miss"]')
    expect(missKpi?.textContent).toContain('큐 누락')
    expect(missKpi?.textContent).toContain('1')
    expect(missKpi?.querySelector('.ov-kpi-v')?.className).toContain('warn')
  })

  it('counts cancelled last executions and the store\'s retained wake failures in the KPI strip', async () => {
    const automation = sampleAutomation()
    automation.requests = [
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-orphan',
        keeper_queue_evidence: { projection_status: 'not_found' },
        keeper_reaction_evidence: { projection_status: 'matched_terminal_cancelled' },
      },
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-drained',
        keeper_queue_evidence: { projection_status: 'not_found' },
        keeper_reaction_evidence: { projection_status: 'matched_turn_finished' },
      },
    ]
    // 27 attempts failed in one burst and were retried to success: the rows
    // above are healthy now, and only the store-wide count still says so.
    automation.wake_counts = {
      retained: 61,
      running: 0,
      succeeded: 34,
      failed: 27,
      active_with_failed_newest_wake: 0,
      retention_per_schedule: 32,
    }
    setAutomation(automation)
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const cancelledKpi = container.querySelector('[data-testid="schedule-kpi-queue-cancelled"]')
    expect(cancelledKpi?.textContent).toContain('큐 취소')
    expect(cancelledKpi?.querySelector('.ov-kpi-v')?.textContent).toBe('1')
    expect(cancelledKpi?.querySelector('.ov-kpi-v')?.className).toContain('warn')
    // turn_finished is a reaction: the drained row is neither a miss nor a cancellation.
    expect(container.querySelector('[data-testid="schedule-kpi-queue-miss"] .ov-kpi-v')?.textContent).toBe('0')
    const failedKpi = container.querySelector('[data-testid="schedule-kpi-wake-failed"]')
    expect(failedKpi?.textContent).toContain('wake 실패')
    expect(failedKpi?.querySelector('.ov-kpi-v')?.textContent).toBe('27')
    expect(failedKpi?.querySelector('.ov-kpi-v')?.getAttribute('title')).toContain('예약당 최대 32')
  })

  it('shows the wake-failure KPI as unknown when the server did not count wakes', async () => {
    const automation = sampleAutomation()
    automation.wake_counts = null
    setAutomation(automation)
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(container.querySelector('[data-testid="schedule-kpi-wake-failed"] .ov-kpi-v')?.textContent).toBe('—')
  })

  it('surfaces projection load errors without hiding stale schedule data', async () => {
    mocks.scheduledAutomationError.value = 'schedule projection unavailable'
    setAutomation(sampleAutomation())
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(container.textContent).toContain('schedule projection unavailable')
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
  })

  it('renders an unreadable ledger as unavailable and keeps every KPI unknown', async () => {
    mocks.scheduledAutomationProjection.value = {
      state: 'unavailable',
      reason: 'schedule store read failed: corrupt ledger',
    }
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(container.querySelector('[data-testid="schedule-projection-unavailable"]')?.textContent)
      .toContain('schedule store read failed: corrupt ledger')
    expect(Array.from(container.querySelectorAll('.ov-kpi-v')).map(node => node.textContent))
      .toEqual(['—', '—', '—', '—', '—', '—'])
    expect(container.querySelector('[data-testid="schedule-viewbar"]')).toBeNull()
    expect(container.textContent).not.toContain('다가오는 7일에 예정된 예약이 없습니다')
  })

  it('distinguishes visible rows from the total when the projection is truncated', async () => {
    const automation = sampleAutomation()
    automation.request_count = 42
    automation.request_limit = 20
    automation.truncated = true
    setAutomation(automation)
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const summary = container.querySelector('[aria-label="예약 요약"]')
    const totalKpi = Array.from(summary?.querySelectorAll('.ov-kpi') ?? [])
      .find(element => element.textContent?.includes('총 예약'))
    expect(totalKpi?.textContent).toContain('42')
    // The rows left out are terminal ones: the one active schedule is on the
    // calendar's page, so the calendar is not short of anything. The fleet
    // page's numbers are not the calendar's, so they are not drawn above it.
    expect(container.querySelector('[data-testid="sch-calendar"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="sch-calendar-partial"]')).toBeNull()
    expect(container.querySelector('[data-testid="schedule-page-metadata"]')).toBeNull()

    container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
    await flush()

    expect(container.querySelector('[data-testid="schedule-page-metadata"]')?.textContent)
      .toContain('표시 1 / 전체 42 · 최대 20 · 일부만 표시')
  })

  it('says the calendar is partial when its own page leaves active schedules out (#52961)', async () => {
    setAutomation(sampleAutomation())
    const active = sampleAutomation()
    active.truncated = true
    // One active row on the calendar's page; the server counts five.
    active.request_count = 5
    active.fsm = { ...active.fsm, active_count: 5, terminal_count: 0 }
    setActiveSchedules(active)
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(container.querySelector('[data-testid="sch-calendar-partial"]')?.textContent).toContain('4건')
  })

  describe('the calendar reads the active-only page (#52961)', () => {
    const agendaEvent = (scheduleId: string) => container.querySelector(
      `[data-testid="sch-agenda-event"][data-schedule-id="${scheduleId}"]`,
    )
    const oneshotChipCount = () => container.querySelector(
      '[data-testid="sch-cadsum-oneshot"] .sch-cadsum-n',
    )?.textContent
    const later: DashboardScheduledAutomationRequest = {
      ...sampleAutomation().requests[0]!,
      schedule_id: 'sched-after-the-fleet-page',
    }
    // The fleet page is cut before `later`: the server counts two active
    // schedules and the page holds one.
    const cutFleetPage = (): DashboardScheduledAutomationAvailableData => {
      const fleet = sampleAutomation()
      fleet.request_count = 42
      fleet.truncated = true
      fleet.fsm = { ...fleet.fsm, active_count: 2 }
      return fleet
    }
    const wholeActivePage = (): DashboardScheduledAutomationAvailableData => {
      const active = sampleAutomation()
      active.request_count = 2
      active.request_limit = 200
      active.fsm = { ...active.fsm, active_count: 2, terminal_count: 0 }
      active.requests = [...active.requests, later]
      return active
    }
    const mount = async () => {
      mocks.toolsData.value = { tool_inventory: { tools: [] }, tool_usage: {} }
      render(html`<${ScheduleSurface} />`, container)
      await flush()
    }

    it('draws a schedule the fleet page was cut before, and calls nothing missing', async () => {
      setAutomation(cutFleetPage())
      setActiveSchedules(wholeActivePage())

      await mount()

      expect(agendaEvent('sched-1')).not.toBeNull()
      expect(agendaEvent(later.schedule_id)).not.toBeNull()
      expect(container.querySelector('[data-testid="sch-calendar-partial"]')).toBeNull()
      // The cadence chips count what the calendar draws.
      expect(oneshotChipCount()).toBe('2')
    })

    it('leaves the list on the fleet page', async () => {
      setAutomation(cutFleetPage())
      setActiveSchedules(wholeActivePage())
      await mount()

      container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
      await flush()
      // Both rows are due; the list shows due rows under this filter.
      container.querySelector<HTMLButtonElement>('[data-schedule-filter="due"]')?.click()
      await flush()

      expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
      expect(container.querySelector(`[data-schedule-id="${later.schedule_id}"]`)).toBeNull()
      expect(oneshotChipCount()).toBe('1')
    })

    it('opens a schedule of its own page without an exact lookup', async () => {
      setAutomation(cutFleetPage())
      setActiveSchedules(wholeActivePage())
      mocks.route.value = {
        tab: 'schedule',
        params: { schedule_id: later.schedule_id },
        postId: null,
      }

      await mount()

      expect(mocks.fetchScheduledAutomationLookup).not.toHaveBeenCalled()
      expect(container.querySelector(
        `[data-schedule-detail-panel="${later.schedule_id}"]`,
      )).not.toBeNull()
    })

    it('reads that page only while the calendar is open', async () => {
      setAutomation(sampleAutomation())
      await mount()
      expect(mocks.subscribeActiveSchedulesRefresh).toHaveBeenCalledTimes(1)
      expect(mocks.stopActiveSchedulesRefresh).not.toHaveBeenCalled()

      container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
      await flush()
      expect(mocks.stopActiveSchedulesRefresh).toHaveBeenCalledTimes(1)
      expect(mocks.subscribeActiveSchedulesRefresh).toHaveBeenCalledTimes(1)

      container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-calendar"]')?.click()
      await flush()
      expect(mocks.subscribeActiveSchedulesRefresh).toHaveBeenCalledTimes(2)
    })

    it('draws no calendar before that page is read', async () => {
      setAutomation(cutFleetPage())
      mocks.activeSchedulesProjection.value = null

      await mount()

      // The fleet page is not a stand-in: its rows would draw a week with
      // most of its schedules missing.
      expect(container.querySelector('[data-testid="sch-calendar"]')).toBeNull()
      expect(container.querySelector('[data-testid="sch-cadsum"]')).toBeNull()
      expect(container.textContent).toContain('캘린더에 쓸 예약 불러오는 중')
      // The KPI strip is the fleet page's and is already known.
      expect(container.querySelector('[aria-label="예약 요약"]')?.textContent).toContain('42')
    })

    it('says so when that page could not be read, and calls no day empty', async () => {
      setAutomation(cutFleetPage())
      mocks.activeSchedulesProjection.value = {
        state: 'unavailable',
        reason: 'schedule store read failed: fixture',
      }

      await mount()

      expect(container.querySelector('[data-testid="schedule-calendar-unavailable"]')?.textContent)
        .toContain('schedule store read failed: fixture')
      expect(container.querySelector('[data-testid="sch-calendar"]')).toBeNull()
      expect(container.textContent).not.toContain('캘린더에 쓸 예약 불러오는 중')
      expect(container.textContent).not.toContain('다가오는 7일에 예정된 예약이 없습니다')
    })

    it('keeps the last page on screen when reading it again fails', async () => {
      setAutomation(cutFleetPage())
      setActiveSchedules(wholeActivePage())
      mocks.activeSchedulesError.value = 'fixture: offline'

      await mount()

      expect(container.querySelector('[data-testid="schedule-calendar-unavailable"]')?.textContent)
        .toContain('fixture: offline')
      expect(agendaEvent(later.schedule_id)).not.toBeNull()
    })
  })

  it('prunes completed schedules through the live dashboard API and refreshes projection', async () => {
    setAutomation(sampleAutomation())
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }
    mocks.pruneSchedules.mockResolvedValue({ ok: true, pruned_count: 5 })
    const originalConfirm = window.confirm
    window.confirm = vi.fn().mockReturnValue(true)

    try {
      render(html`<${ScheduleSurface} />`, container)
      await flush()

      // The prune button lives on the view bar, not behind the diagnostics
      // toggle: succeeded rows are cleaned from where they are seen.
      container.querySelector<HTMLButtonElement>('[data-testid="schedule-prune-btn"]')?.click()
      await flush()

      expect(window.confirm).toHaveBeenCalledTimes(1)
      expect(mocks.pruneSchedules).toHaveBeenCalledTimes(1)
      // Prune refreshes the schedule projection, not the tool inventory.
      expect(mocks.loadScheduledAutomation).toHaveBeenCalledTimes(1)
    } finally {
      window.confirm = originalConfirm
    }
  })

  it('defaults to the calendar view with a cadence filter strip', async () => {
    setAutomation(sampleAutomation())
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    // Calendar view is active by default (aria-selected), and the cadence strip
    // renders a chip per operator cadence.
    expect(container.querySelector('[data-testid="schedule-view-calendar"]')?.getAttribute('aria-selected'))
      .toBe('true')
    expect(container.querySelector('[data-testid="sch-cadsum"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="sch-cadsum-oneshot"]')).not.toBeNull()
    // The sample request (one_shot, non-terminal) surfaces as an agenda event,
    // not the diagnostic list; the wake-signal feed is list-only.
    expect(container.querySelector('[data-testid="sch-agenda"]')).not.toBeNull()
    expect(container.textContent).not.toContain('wake signal 피드 · schedule_runner.tick')
  })

  it('toggles to the list view revealing the diagnostic wake-signal feed', async () => {
    setAutomation(sampleAutomation())
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
    await flush()

    expect(container.querySelector('[data-testid="schedule-view-list"]')?.getAttribute('aria-selected'))
      .toBe('true')
    expect(container.textContent).toContain('wake signal 피드 · schedule_runner.tick')
    // No mutation controls leak onto either view (surface stays read-only).
    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
  })

  it('narrows the list view rows when a cadence chip is active', async () => {
    const automation = sampleAutomation()
    automation.requests = [
      { ...automation.requests[0]!, schedule_id: 'sched-oneshot', recurrence: { kind: 'one_shot' }, recurrence_kind: 'one_shot' },
      { ...automation.requests[0]!, schedule_id: 'sched-interval', recurrence: { kind: 'interval', interval_sec: 3600 }, recurrence_kind: 'interval' },
    ]
    setAutomation(automation)
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
    await flush()
    container.querySelector<HTMLButtonElement>('[data-schedule-filter="due"]')?.click()
    await flush()
    container.querySelector<HTMLButtonElement>('[data-testid="sch-cadsum-interval"]')?.click()
    await flush()

    // Only the interval schedule survives the 폴링 cadence filter in the list.
    expect(container.querySelector('[data-schedule-id="sched-interval"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-oneshot"]')).toBeNull()
  })

  it('opens an exact route that is outside the truncated aggregate page', async () => {
    const exactRequest: DashboardScheduledAutomationRequest = {
      ...sampleAutomation().requests[0]!,
      schedule_id: 'sched-outside-page',
      payload_summary: 'Exact route payload',
    }
    setAutomation(sampleAutomation())
    mocks.route.value = {
      tab: 'schedule',
      params: { schedule_id: exactRequest.schedule_id, view: 'calendar' },
      postId: null,
    }
    mocks.fetchScheduledAutomationLookup.mockResolvedValue({
      status: 'found',
      scheduleId: exactRequest.schedule_id,
      request: exactRequest,
    })

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(mocks.fetchScheduledAutomationLookup).toHaveBeenCalledWith(
      exactRequest.schedule_id,
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
    expect(container.querySelector(
      '[data-schedule-detail-panel="sched-outside-page"]',
    )?.textContent).toContain('Exact route payload')

    container.querySelector<HTMLButtonElement>('.turn-close')?.click()
    expect(mocks.replaceRoute).toHaveBeenCalledWith('schedule', { view: 'calendar' })
  })

  describe('a selected schedule outside the page when the projection is refreshed', () => {
    // #52962: the detail was read once, when the schedule was selected.
    const outside: DashboardScheduledAutomationRequest = {
      ...sampleAutomation().requests[0]!,
      schedule_id: 'sched-outside-page',
      payload_summary: 'payload before the refresh',
    }
    const panel = () => container.querySelector('[data-schedule-detail-panel="sched-outside-page"]')
    const lookupStatus = () => container.querySelector('[data-testid="schedule-exact-lookup-status"]')
    const openOutsidePage = async () => {
      setAutomation(sampleAutomation())
      mocks.route.value = {
        tab: 'schedule',
        params: { schedule_id: outside.schedule_id, view: 'calendar' },
        postId: null,
      }
      render(html`<${ScheduleSurface} />`, container)
      await flush()
    }
    // The projection is a signal in the app and a plain object here, so a
    // changed prop stands in for the signal telling the surface to draw again.
    let drawn = 0
    const drawAgain = async () => {
      drawn += 1
      render(html`<${ScheduleSurface} drawn=${drawn} />`, container)
      await flush()
    }
    // The observation refresh publishes a new projection; the selected id is still not on its page.
    const refreshProjection = async () => {
      setAutomation(sampleAutomation())
      await drawAgain()
    }

    it('reads the schedule again and shows its new state', async () => {
      mocks.fetchScheduledAutomationLookup
        .mockResolvedValueOnce({ status: 'found', scheduleId: outside.schedule_id, request: outside })
        .mockResolvedValueOnce({
          status: 'found',
          scheduleId: outside.schedule_id,
          request: { ...outside, status: 'cancelled', payload_summary: 'payload after the refresh' },
        })
      await openOutsidePage()
      expect(panel()?.textContent).toContain('payload before the refresh')

      await refreshProjection()

      expect(mocks.fetchScheduledAutomationLookup).toHaveBeenCalledTimes(2)
      expect(panel()?.textContent).toContain('payload after the refresh')
    })

    it('closes the detail of a schedule the refresh no longer finds', async () => {
      mocks.fetchScheduledAutomationLookup
        .mockResolvedValueOnce({ status: 'found', scheduleId: outside.schedule_id, request: outside })
        .mockResolvedValueOnce({ status: 'not_found', scheduleId: outside.schedule_id })
      await openOutsidePage()
      expect(panel()).not.toBeNull()

      await refreshProjection()

      expect(panel()).toBeNull()
      expect(lookupStatus()).not.toBeNull()
    })

    it('keeps the detail on screen while it is being read again', async () => {
      mocks.fetchScheduledAutomationLookup
        .mockResolvedValueOnce({ status: 'found', scheduleId: outside.schedule_id, request: outside })
        .mockImplementationOnce(() => new Promise(() => {}))
      await openOutsidePage()

      await refreshProjection()

      expect(mocks.fetchScheduledAutomationLookup).toHaveBeenCalledTimes(2)
      expect(panel()?.textContent).toContain('payload before the refresh')
      expect(lookupStatus()).toBeNull()
    })

    it('keeps the last answer open and says it was not read again when the read fails', async () => {
      mocks.fetchScheduledAutomationLookup
        .mockResolvedValueOnce({ status: 'found', scheduleId: outside.schedule_id, request: outside })
        .mockRejectedValueOnce(new Error('fixture: lookup timed out'))
        .mockResolvedValueOnce({
          status: 'found',
          scheduleId: outside.schedule_id,
          request: { ...outside, payload_summary: 'payload after the second refresh' },
        })
      await openOutsidePage()

      await refreshProjection()

      // One failed read does not close a detail the operator is reading.
      expect(panel()?.textContent).toContain('payload before the refresh')
      expect(lookupStatus()?.textContent).toContain('fixture: lookup timed out')

      await refreshProjection()

      expect(mocks.fetchScheduledAutomationLookup).toHaveBeenCalledTimes(3)
      expect(panel()?.textContent).toContain('payload after the second refresh')
      expect(lookupStatus()).toBeNull()
    })

    it('does not read again when the same projection is drawn again', async () => {
      mocks.fetchScheduledAutomationLookup
        .mockResolvedValue({ status: 'found', scheduleId: outside.schedule_id, request: outside })
      await openOutsidePage()

      await drawAgain()

      expect(mocks.fetchScheduledAutomationLookup).toHaveBeenCalledTimes(1)
    })
  })

  it('uses an in-page route row without issuing a redundant exact lookup', async () => {
    setAutomation(sampleAutomation())
    mocks.route.value = {
      tab: 'schedule',
      params: { schedule_id: 'sched-1' },
      postId: null,
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(mocks.fetchScheduledAutomationLookup).not.toHaveBeenCalled()
    expect(container.querySelector('[data-schedule-detail-panel="sched-1"]')).not.toBeNull()
  })
})
