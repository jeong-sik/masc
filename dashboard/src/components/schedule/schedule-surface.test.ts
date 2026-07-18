import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardKeeperBackground,
  DashboardKeeperWaitingInventory,
  DashboardScheduledAutomation,
} from '../../api'

type MockToolsResponse = {
  generated_at?: string
  tool_inventory: { tools: unknown[] }
  tool_usage: Record<string, unknown>
  scheduled_automation?: DashboardScheduledAutomation
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
  keeper_background?: DashboardKeeperBackground
}

const mocks = vi.hoisted(() => ({
  loadTools: vi.fn(),
  toolsData: { value: null as null | MockToolsResponse },
  toolsLoading: { value: false },
  toolsError: { value: null as string | null },
  pruneSchedules: vi.fn(),
}))

vi.mock('../tools/tool-state', () => ({
  loadTools: mocks.loadTools,
  toolsData: mocks.toolsData,
  toolsError: mocks.toolsError,
  toolsLoading: mocks.toolsLoading,
}))

vi.mock('../../api/dashboard-schedule', () => ({
  pruneSchedules: mocks.pruneSchedules,
}))

import { ScheduleSurface } from './schedule-surface'

function sampleAutomation(): DashboardScheduledAutomation {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    source: 'schedule_store',
    generated_at: '2026-06-21T00:00:00Z',
    generated_at_unix: 1_782_000_000,
    status: 'ok',
    schedule_store_known: true,
    schedule_store_read_error: null,
    request_projection: {
      returned_count: 1,
      total_count: 1,
      limit: 20,
      truncated: false,
    },
    counts: { scheduled: 3, due: 1, running: 1 },
    payload_support: {
      supported_kinds: [],
      unsupported_request_count: 0,
      unsupported_kinds: [],
      unknown_request_count: 0,
    },
    live_supported_non_terminal_evidence: null,
    fsm: {
      state: 'due',
      active_count: 1,
      terminal_count: 0,
      next_due_at: '2026-06-21T01:00:00Z',
    },
    signal_count: 1,
    signal_error_count: 0,
    signal_limit: 20,
    signal_source: 'schedule_runner_signals',
    signal_errors: [],
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

function sampleWaitingInventory(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v2',
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
        waiting_count: 1,
        sources: { schedule_waiting: 1 },
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'schedule_waiting',
            waiting_on: 'masc.board_post',
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
        due_at_iso: '2026-07-04T01:00:00Z',
        next_action: 'schedule_runner_dispatch',
      },
    ],
  }
}

function sampleKeeperBackground(): DashboardKeeperBackground {
  return {
    schema: 'masc.dashboard.keeper_background.v1',
    source: 'server_keeper_background',
    keeper_count: 1,
    recurring_keeper_count: 1,
    recurring_count: 1,
    keepers: [
      {
        keeper_name: 'sangsu',
        loop: { phase: 'running', restart_count: 0, started_at_iso: '2026-07-08T00:00:00Z' },
        recurring_count: 1,
        recurring: [
          {
            id: 'loop-1-1',
            label: 'heartbeat-check',
            action_kind: 'broadcast',
            interval_sec: 30,
            enabled: true,
            run_count: 3,
            failure_count: 0,
            last_run_at_iso: '2026-07-08T00:01:00Z',
            next_run_at_iso: '2026-07-08T00:01:30Z',
          },
        ],
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
    mocks.toolsError.value = null
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
    // Calendar is the default view; with no projection it renders the empty
    // agenda/polling states rather than the diagnostic panel's placeholder.
    expect(container.querySelector('[data-testid="schedule-viewbar"]')).not.toBeNull()
    expect(container.textContent).toContain('다가오는 7일에 예정된 예약이 없습니다')
    expect(container.textContent).toContain('활성 폴링 없음')
  })

  it('renders backed schedule summary and reuses read-only schedule cards', async () => {
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
      keeper_waiting_inventory: sampleWaitingInventory(),
      keeper_background: sampleKeeperBackground(),
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
    // The keeper-lane / background diagnostics are collapsed AND lazy-mounted by
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
    // Keeper background panel renders as a sibling card on the same surface,
    // reading data.keeper_background (recurring tasks + loop liveness).
    expect(container.querySelector('[data-testid="schedule-keeper-background"]')?.textContent)
      .toContain('Keeper Background · recurring tasks')
    expect(container.querySelector('[data-testid="schedule-keeper-background"]')?.textContent)
      .toContain('heartbeat-check')
    // REMOVED: '출처 <signal_source>' feed attribution line is not rendered on
    // the v2 surface (it is diagnostics-only); no equivalent element exists to
    // retarget, so this coverage is dropped rather than weakened.
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
  })

  it('renders the read-only operations aside in a two-column shell', async () => {
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
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

  it('keeps backend counts authoritative and exposes row-envelope disagreement', async () => {
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
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: automation,
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const scheduledKpi = Array.from(container.querySelectorAll('.ov-kpi'))
      .find(element => element.textContent?.includes('예약됨'))
    expect(scheduledKpi?.textContent).toContain('1')
    expect(container.textContent).toContain('schedule projection integrity failure')
    expect(container.textContent).toContain('returned_count=1 rows=2')
    expect(container.textContent).toContain('status=scheduled projected=2 exact=1')
  })

  it('counts genuine queue-drain misses in the KPI (not_found queue AND not_found reaction)', async () => {
    const automation = sampleAutomation()
    automation.requests = [
      // Healthy completion: not in queue and the latest reaction is ACK.
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-drained',
        keeper_queue_evidence: { projection_status: 'not_found' },
        keeper_reaction_evidence: {
          projection_status: 'matched_consumed_ack',
          latest_reaction: {
            kind: 'event_queue_ack',
            sequence: '3',
            event_id: 'event-3',
            recorded_at: 203,
            recorded_at_iso: '1970-01-01T00:03:23Z',
            transition_id: 'transition-3',
            source_index: 0,
            source_count: 1,
          },
        },
      },
      // Genuine miss: dispatched, in no queue, no keeper reaction recorded.
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-miss',
        keeper_queue_evidence: { projection_status: 'not_found' },
        keeper_reaction_evidence: { projection_status: 'not_found' },
      },
    ]
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: automation,
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const missKpi = container.querySelector('[data-testid="schedule-kpi-queue-miss"]')
    expect(missKpi?.textContent).toContain('큐 누락')
    expect(missKpi?.textContent).toContain('1')
    expect(missKpi?.querySelector('.ov-kpi-v')?.className).toContain('warn')
  })

  it('surfaces projection load errors without hiding stale schedule data', async () => {
    mocks.toolsError.value = 'dashboard tools unavailable'
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(container.textContent).toContain('dashboard tools unavailable')
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
  })

  it('keeps exact store totals distinct from a truncated request projection', async () => {
    const automation = sampleAutomation()
    automation.request_projection = {
      returned_count: 1,
      total_count: 43,
      limit: 20,
      truncated: true,
    }
    automation.counts = { scheduled: 40, due: 2, running: 1 }
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: automation,
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const notice = container.querySelector('[data-schedule-projection-notice="true"]')
    expect(notice?.getAttribute('data-schedule-projection-truncated')).toBe('true')
    expect(notice?.textContent).toContain('예약 목록 일부만 표시')
    expect(notice?.textContent).toContain('1 / 43')
    const summary = container.querySelector('[aria-label="예약 요약"]')
    const totalKpi = Array.from(summary?.querySelectorAll('.ov-kpi') ?? [])
      .find(element => element.textContent?.includes('총 예약'))
    expect(totalKpi?.textContent).toContain('43')
    const scheduledKpi = Array.from(summary?.querySelectorAll('.ov-kpi') ?? [])
      .find(element => element.textContent?.includes('예약됨'))
    expect(scheduledKpi?.textContent).toContain('40')
    const queueMissKpi = container.querySelector('[data-testid="schedule-kpi-queue-miss"]')
    expect(queueMissKpi?.textContent).toContain('알 수 없음')
    expect(queueMissKpi?.querySelector('.ov-kpi-v')?.className).not.toContain('ok')
  })

  it('renders unknown store counts and durable signal decode failures explicitly', async () => {
    const automation: DashboardScheduledAutomation = {
      ...sampleAutomation(),
      status: 'unknown',
      schedule_store_known: false,
      schedule_store_read_error: 'schedule ledger checksum mismatch',
      request_projection: {
        returned_count: 0,
        total_count: null,
        limit: 20,
        truncated: false,
      },
      counts: null,
      payload_support: null,
      live_supported_non_terminal_evidence: null,
      fsm: {
        state: 'unknown',
        active_count: null,
        terminal_count: null,
        next_due_at: null,
      },
      requests: [],
      signals: [],
      signal_count: 0,
      signal_error_count: 1,
      signal_errors: [{ ordinal: 4, error: 'invalid occurrence envelope' }],
    }
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: automation,
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    const notice = container.querySelector('[data-schedule-projection-notice="true"]')
    expect(notice?.getAttribute('data-schedule-store-known')).toBe('false')
    expect(notice?.getAttribute('data-schedule-signal-error-count')).toBe('1')
    expect(notice?.textContent).toContain('schedule ledger checksum mismatch')
    expect(notice?.textContent).toContain('durable wake signal decode 실패')
    expect(notice?.textContent).toContain('invalid occurrence envelope')
    expect(container.querySelector('[aria-label="예약 요약"]')?.textContent)
      .toContain('알 수 없음')
    expect(container.querySelector('[data-schedule-store-unavailable="true"]')?.textContent)
      .toContain('판단할 수 없습니다')
    expect(container.textContent).not.toContain('예약 요청 없음')
    expect(container.querySelector('[data-testid="schedule-viewbar"]')).toBeNull()
  })

  it('prunes completed schedules through the live dashboard API and refreshes projection', async () => {
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
    }
    mocks.pruneSchedules.mockResolvedValue({ ok: true, pruned_count: 5 })
    const originalConfirm = window.confirm
    window.confirm = vi.fn().mockReturnValue(true)

    try {
      render(html`<${ScheduleSurface} />`, container)
      await flush()

      container.querySelector<HTMLButtonElement>('[data-testid="schedule-diagnostics-toggle"]')?.click()
      await flush()
      container.querySelector<HTMLButtonElement>('[data-testid="schedule-prune-btn"]')?.click()
      await flush()

      expect(window.confirm).toHaveBeenCalledTimes(1)
      expect(mocks.pruneSchedules).toHaveBeenCalledTimes(1)
      expect(mocks.loadTools).toHaveBeenCalledTimes(1)
    } finally {
      window.confirm = originalConfirm
    }
  })

  it('defaults to the calendar view with a cadence filter strip', async () => {
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
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
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
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
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: automation,
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
})
