import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardKeeperWaitingInventory, DashboardScheduledAutomation } from '../../api'

type MockToolsResponse = {
  generated_at?: string
  tool_inventory: { tools: unknown[] }
  tool_usage: Record<string, unknown>
  scheduled_automation?: DashboardScheduledAutomation
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
}

const mocks = vi.hoisted(() => ({
  loadTools: vi.fn(),
  toolsData: { value: null as null | MockToolsResponse },
  toolsLoading: { value: false },
  toolsError: { value: null as string | null },
}))

vi.mock('../tools/tool-state', () => ({
  loadTools: mocks.loadTools,
  toolsData: mocks.toolsData,
  toolsError: mocks.toolsError,
  toolsLoading: mocks.toolsLoading,
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
    schema: 'masc.dashboard.keeper_waiting_inventory.v1',
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
    expect(container.textContent).toContain('예약 자동화')
    expect(container.textContent).toContain('예약 자동화 projection 없음')
  })

  it('renders backed schedule summary and reuses read-only schedule cards', async () => {
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
      keeper_waiting_inventory: sampleWaitingInventory(),
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
    // The wake-signal feed header is renamed in v2.
    expect(container.textContent).toContain('wake signal 피드 · schedule_runner.tick')
    expect(container.querySelector('[data-testid="schedule-waiting-inventory"]')?.textContent)
      .toContain('Keeper Waiting Inventory')
    expect(container.querySelector('[data-testid="schedule-waiting-inventory"]')?.textContent)
      .toContain('sangsu')
    expect(container.querySelector('[data-testid="schedule-waiting-inventory"]')?.textContent)
      .toContain('masc.board_post')
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
})
