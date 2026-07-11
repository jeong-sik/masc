import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardKeeperWaitingInventory, DashboardScheduledAutomation } from '../../api'

type MockToolsResponse = {
  generated_at?: string
  tool_inventory: { tools: unknown[] }
  tool_usage: Record<string, unknown> & {
    registered_count: number
    distinct_tools_called: number
    never_called_count: number
  }
  scheduled_automation?: DashboardScheduledAutomation
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
}

const mocks = vi.hoisted(() => ({
  loadTools: vi.fn(),
  navigate: vi.fn(),
  toolsData: { value: null as null | MockToolsResponse },
  toolsLoading: { value: false },
  toolsError: { value: null as string | null },
}))

vi.mock('./tool-state', () => ({
  loadTools: mocks.loadTools,
  toolsData: mocks.toolsData,
  toolsError: mocks.toolsError,
  toolsLoading: mocks.toolsLoading,
}))

vi.mock('../common/card', () => ({
  SectionCard: ({ label, children }: { label: string; children: unknown }) => html`
    <section data-card-title=${label}>
      <h2>${label}</h2>
      ${children}
    </section>
  `,
}))

vi.mock('../tool-metrics', () => ({
  ToolMetrics: () => html`<div>ToolMetrics</div>`,
}))

vi.mock('./tool-full-inventory', () => ({
  FullInventoryView: () => html`<div>FullInventoryView</div>`,
}))

vi.mock('../../router', () => ({
  navigate: mocks.navigate,
}))

vi.mock('./config-resolution-panel', () => ({
  ConfigResolutionPanel: () => html`<div>ConfigResolutionPanel</div>`,
}))

vi.mock('../tool-executor/tool-executor', () => ({
  ToolExecutor: () => html`<div>ToolExecutor</div>`,
}))

import { Tools } from './tools-main'

function waitingInventoryFixture(): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v2',
    source: 'server_keeper_waiting_inventory',
    keeper_count_known: true,
    keeper_count: 1,
    waiting_keeper_count: 1,
    row_count: 1,
    global_row_count: 0,
    keepers: [
      {
        keeper_name: 'sangsu',
        state: 'waiting',
        waiting_count: 1,
        waiting_on: [
          {
            keeper_name: 'sangsu',
            source: 'event_queue_pending',
            waiting_on: 'bootstrap',
            wake_producer: 'keeper_supervisor',
            next_action: 'keeper_drain_event_queue',
          },
        ],
      },
    ],
    global_waiting_on: [],
  }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

describe('Tools', () => {
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

  it('loads tool data and renders full inventory with prompt registry inside the tools surface', async () => {
    render(html`<${Tools} />`, container)
    await flush()

    expect(container.querySelector('.v2-lab-surface')).not.toBeNull()
    expect(container.querySelectorAll('.v2-lab-action')).toHaveLength(2)
    expect(mocks.loadTools).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('ConfigResolutionPanel')
    expect(container.textContent).toContain('예약 자동화 FSM')
    expect(container.textContent).toContain('시스템 도구 목록')
    expect(container.textContent).toContain('FullInventoryView')
    expect(container.textContent).toContain('도구 사용 현황')
    expect(container.textContent).toContain('ToolMetrics')
    // Prompt editing was consolidated into Settings › Prompts; Lab now only
    // shows a read-only pointer, not the editable PromptRegistryPanel.
    expect(container.textContent).not.toContain('PromptRegistryPanel')
    expect(container.textContent).toContain('프롬프트 레지스트리')
    const promptCta = container.querySelector('.v2-lab-prompt-cta') as HTMLElement | null
    expect(promptCta).not.toBeNull()
    promptCta!.click()
    expect(mocks.navigate).toHaveBeenCalledWith('settings', { section: 'prompts' })
  })

  it('renders scheduled automation FSM projection', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      scheduled_automation: {
        schema: 'masc.dashboard.scheduled_automation.v1',
        source: 'schedule_store',
        generated_at: '2026-06-13T00:00:00Z',
        request_count: 1,
        request_limit: 20,
        truncated: false,
        counts: { pending_approval: 1 },
        derived_counts: {
          due_effective: 0,
          blocked_approval: 1,
          due_execution_ready: 0,
          expired_effective: 0,
          unsupported_payload_kind: 1,
          unknown_payload_kind: 0,
        },
        payload_support: {
          supported_kinds: ['masc.board_post'],
          unsupported_request_count: 1,
          unsupported_kinds: [{ kind: 'test.reminder', count: 1 }],
          unknown_request_count: 0,
        },
        fsm: {
          state: 'blocked_approval',
          active_count: 1,
          terminal_count: 0,
          next_due_at: '2026-06-13T01:00:00Z',
        },
        requests: [
          {
            schedule_id: 'sched-1',
            status: 'pending_approval',
            effective_status: 'blocked_approval',
            execution_readiness: 'blocked_approval',
            operator_action: 'approve_or_reject',
            keeper_next_tool: 'masc_schedule_get',
            keeper_next_tool_status: {
              name: 'masc_schedule_get',
              registered_schema: true,
              dispatch_registered: true,
              direct_call_allowed: true,
              visibility: 'hidden',
              surfaces: [],
              surface_count: 0,
              effect_domain: 'read_only',
              read_only: true,
              requires_actor_binding: null,
            },
            keeper_next_action:
              'Inspect details, then wait for the dashboard operator approval or rejection action to resolve this schedule.',
            risk_class: 'workspace_write',
            approval_required: true,
            source: 'operator_request',
            requested_by: { id: 'operator', kind: 'human_operator', display_name: null },
            scheduled_by: { id: 'scheduler-agent', kind: 'automated_actor', display_name: null },
            recurrence: { kind: 'cron', expression: '0 9 * * 1-5', timezone: 'Asia/Seoul' },
            recurrence_kind: 'cron',
            payload_kind: 'test.reminder',
            payload_support: 'unsupported',
            requested_at_iso: '2026-06-13T00:00:00Z',
            due_at_iso: '2026-06-13T01:00:00Z',
            expires_at_iso: '2026-06-13T02:00:00Z',
            last_execution: {
              execution_id: 'exec-1',
              schedule_id: 'sched-1',
              started_at_iso: '2026-06-13T00:30:00Z',
              finished_at_iso: '2026-06-13T00:30:01Z',
              status: 'succeeded',
            },
          },
        ],
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.textContent).toContain('blocked approval')
    expect(container.textContent).toContain('원본 pending approval')
    expect(container.textContent).toContain('approve or reject')
    expect(container.textContent).toContain('masc_schedule_get')
    expect(container.textContent).toContain('dashboard operator approval or rejection')
    expect(container.textContent).toContain('Approve')
    expect(container.textContent).toContain('Reject')
    expect(container.textContent).toContain('callable')
    expect(container.textContent).toContain('hidden')
    expect(container.textContent).toContain('no surface')
    expect(container.textContent).toContain('sched-1')
    expect(container.textContent).toContain('workspace write')
    expect(container.textContent).toContain('cron 0 9 * * 1-5 Asia/Seoul')
    expect(container.textContent).toContain('succeeded')
    expect(container.textContent).toContain('test.reminder')
    expect(container.textContent).toContain('unsupported payload')
    expect(container.textContent).toContain('unsupported')
    expect(container.textContent).toContain('wake signal feed')
    expect(container.textContent).toContain('키퍼 다음 단계')
    expect(container.textContent).toContain('operator (human operator)')
    expect(container.textContent).toContain('Keeper Waiting Inventory')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('event queue pending')
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
    expect(container.querySelector('.v2-lab-card')).not.toBeNull()
  })

  it('renders tool usage coverage gap provenance', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
        source: 'tool_usage',
        health: 'coverage_gap',
        stale_reason: 'tool_usage_append_failed',
        entry_count: 0,
        coverage_gap_count: 1,
        coverage_gaps: [
          {
            schema: 'masc.telemetry_coverage_gap.v1',
            source: 'tool_usage',
            producer: 'tool_usage_log',
            durable_store: '.masc/tool_usage',
            dashboard_surface: '/api/v1/dashboard/tools',
            stale_reason: 'tool_usage_append_failed',
            error: 'synthetic append failure',
          },
        ],
      },
    }

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.textContent).toContain('Telemetry write failed · 1 recorded gap')
    expect(container.textContent).toContain('reason tool_usage_append_failed')
    expect(container.textContent).toContain('producer tool_usage_log')
    expect(container.textContent).toContain('store .masc/tool_usage')
    expect(container.textContent).toContain('surface /api/v1/dashboard/tools')
    expect(container.textContent).toContain('error synthetic append failure')
  })
})
