import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardScheduledAutomation } from '../../api'

type MockToolsResponse = {
  generated_at?: string
  tool_inventory: { tools: unknown[] }
  tool_usage: Record<string, unknown>
  scheduled_automation?: DashboardScheduledAutomation
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
    expect(container.textContent).toContain('예약 자동화')
    expect(container.textContent).toContain('예약 자동화 projection 없음')
  })

  it('renders backed schedule summary and reuses read-only schedule cards', async () => {
    mocks.toolsData.value = {
      generated_at: '2026-06-21T00:00:00Z',
      tool_inventory: { tools: [] },
      tool_usage: {},
      scheduled_automation: sampleAutomation(),
    }

    render(html`<${ScheduleSurface} />`, container)
    await flush()

    expect(mocks.loadTools).not.toHaveBeenCalled()
    const summary = container.querySelector('[aria-label="Schedule summary"]')
    expect(summary?.textContent).toContain('pending')
    expect(summary?.textContent).toContain('due')
    expect(summary?.textContent).toContain('scheduled')
    expect(summary?.textContent).toContain('running')
    expect(summary?.textContent).not.toContain('active')
    expect(summary?.textContent).not.toContain('due effective')
    expect(summary?.textContent).not.toContain('blocked approval')
    expect(container.textContent).toContain('출처 schedule_runner_signals')
    expect(container.textContent).toContain('masc_schedule_get')
    expect(container.textContent).toContain('durable wake signal feed')
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
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

    const pendingKpi = Array.from(container.querySelectorAll('.ov-kpi'))
      .find(element => element.textContent?.includes('pending'))
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
