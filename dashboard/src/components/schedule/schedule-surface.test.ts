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

vi.mock('../../api/dashboard-governance', () => ({
  pruneSchedules: mocks.pruneSchedules,
}))

import { ScheduleSurface } from './schedule-surface'

function sampleAutomation(): DashboardScheduledAutomation {
  return {
    schema: 'masc.dashboard.scheduled_automation.v1',
    source: 'schedule_runner_signals',
    generated_at: '2026-06-21T00:00:00Z',
    request_count: 1,
    request_limit: 20,
    truncated: false,
    counts: { pending_approval: 1, scheduled: 3, running: 1 },
    derived_counts: {
      due_effective: 2,
      blocked_approval: 1,
      due_execution_ready: 1,
      expired_effective: 0,
    },
    fsm: {
      state: 'blocked_approval',
      active_count: 1,
      terminal_count: 0,
      next_due_at: '2026-06-21T01:00:00Z',
    },
    signal_count: 1,
    signals: [
      {
        signal_id: 'sig-1',
        kind: 'schedule.due_candidate',
        event_type: 'schedule.due_candidate',
        schedule_id: 'sched-1',
        emitted_at_iso: '2026-06-21T00:30:00Z',
        risk_class: 'workspace_write',
      },
    ],
    requests: [
      {
        schedule_id: 'sched-1',
        status: 'pending_approval',
        effective_status: 'blocked_approval',
        execution_readiness: 'blocked_approval',
        operator_action: 'approve_or_reject',
        keeper_next_tool: 'masc_schedule_get',
        keeper_next_action: 'Inspect details and wait for explicit approval.',
        risk_class: 'workspace_write',
        approval_required: true,
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
      hitl_pending: 1,
    },
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'waiting',
        waiting_count: 1,
        sources: { hitl_pending: 1 },
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'hitl_pending',
            waiting_on: 'schedule approval',
            since_iso: '2026-07-04T00:00:00Z',
            next_action: 'operator_resolve_hitl',
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
            max_failures: 3,
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
    // with Korean labels; pending/scheduled stay distinct and due+running fold
    // into the single 'due · 실행' KPI (counts unchanged).
    const summary = container.querySelector('[aria-label="예약 요약"]')
    expect(summary?.textContent).toContain('승인 대기')
    expect(summary?.textContent).toContain('due · 실행')
    expect(summary?.textContent).toContain('예약됨')
    expect(summary?.textContent).toContain('총 예약')
    // The folded summary still must not leak the diagnostics-only derived/FSM
    // vocabulary (활성/유효 도래/승인 차단) as separate KPIs.
    expect(summary?.textContent).not.toContain('활성')
    expect(summary?.textContent).not.toContain('유효 도래')
    expect(summary?.textContent).not.toContain('승인 차단')
    // The diagnostic wake-signal feed lives in the 목록 (list) view; the surface
    // now defaults to the 캘린더 view, so toggle before asserting the feed.
    container.querySelector<HTMLButtonElement>('[data-testid="schedule-view-list"]')?.click()
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
    // REMOVED: keeper_next_tool ('masc_schedule_get') is not rendered anywhere
    // on the v2 surface — neither the card nor the SchDetail overlay use
    // KeeperActionCell — so this coverage is dropped (genuinely gone from v2).
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

  it('merges sparse backend counts with materialized request statuses', async () => {
    const automation = sampleAutomation()
    automation.counts = { pending: 1, scheduled: 3, running: 1 }
    automation.requests = [
      {
        ...automation.requests[0]!,
        effective_status: undefined,
        status: 'pending_approval',
      },
      {
        ...automation.requests[0]!,
        schedule_id: 'sched-awaiting',
        effective_status: undefined,
        status: 'awaiting_approval',
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

    // v2 reskin: the pending KPI label is Korean ('승인 대기'). The sparse-count
    // merge still resolves to 2 (counts.pending=1 vs 2 materialized pending-family
    // requests → max), so the assertion intent is unchanged.
    const pendingKpi = Array.from(container.querySelectorAll('.ov-kpi'))
      .find(element => element.textContent?.includes('승인 대기'))
    expect(pendingKpi?.textContent).toContain('2')
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
    container.querySelector<HTMLButtonElement>('[data-testid="sch-cadsum-interval"]')?.click()
    await flush()

    // Only the interval schedule survives the 폴링 cadence filter in the list.
    expect(container.querySelector('[data-schedule-id="sched-interval"]')).not.toBeNull()
    expect(container.querySelector('[data-schedule-id="sched-oneshot"]')).toBeNull()
  })
})
