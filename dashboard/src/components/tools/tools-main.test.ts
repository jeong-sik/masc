import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardKeeperWaitingInventory,
  DashboardScheduledAutomationProjection,
} from '../../api'
import { confirmRuntimeTestWorkspace } from '../../lib/runtime-workspace.test-fixture'

type MockToolsResponse = {
  generated_at?: string
  // The warming envelope the server answers a cold read with carries both.
  status?: string
  is_warming?: boolean
  tool_inventory: { tools: unknown[] }
  tool_usage: Record<string, unknown> & {
    registered_count: number
    distinct_tools_called: number
    never_called_count: number
  }
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
}

const mocks = vi.hoisted(() => ({
  loadTools: vi.fn(),
  subscribeToolsAutoRefresh: vi.fn(() => () => {}),
  fetchDashboardTools: vi.fn(),
  navigate: vi.fn(),
  configResolutionPanel: vi.fn(),
  toolsData: { value: null as null | MockToolsResponse },
  toolsLoading: { value: false },
  toolsError: { value: null as string | null },
  scheduledAutomationProjection: { value: null as null | DashboardScheduledAutomationProjection },
}))

vi.mock('../../api', async importOriginal => ({
  ...await importOriginal<typeof import('../../api')>(),
  fetchDashboardTools: mocks.fetchDashboardTools,
}))

vi.mock('../schedule/schedule-state', () => ({
  scheduledAutomationProjection: mocks.scheduledAutomationProjection,
  subscribeScheduledAutomationRefresh: () => () => {},
}))

// An explicit factory, so every export tools-main reaches for has to be
// listed here: a name added to tool-state and used in the component fails
// this file with "No <name> export is defined on the mock" rather than
// anything about the behaviour.
vi.mock('./tool-state', () => ({
  loadTools: mocks.loadTools,
  subscribeToolsAutoRefresh: mocks.subscribeToolsAutoRefresh,
  toolsData: mocks.toolsData,
  toolsError: mocks.toolsError,
  toolsLoading: mocks.toolsLoading,
  KEEPER_WAITING_INVENTORY_REFRESH_MS: 15_000,
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
  // Echo whether usage was handed over at all: the warming envelope's
  // tool_usage is a placeholder of zeroes and must not reach this pane.
  ToolMetrics: ({ data }: { data: unknown }) =>
    html`<div>ToolMetrics:${data ? 'usage' : 'none'}</div>`,
}))

vi.mock('./tool-full-inventory', () => ({
  FullInventoryView: () => html`<div>FullInventoryView</div>`,
}))

// The series panel loads its own endpoint on mount; its behaviour is covered in
// tool-series-panel.test.ts and tool-series-state.test.ts.
vi.mock('./tool-series-panel', () => ({
  ToolSeriesPanel: () => html`<div>ToolSeriesPanel</div>`,
}))

vi.mock('../../router', () => ({
  navigate: mocks.navigate,
}))

vi.mock('./config-resolution-panel', () => ({
  ConfigResolutionPanel: (props: unknown) => {
    mocks.configResolutionPanel(props)
    return html`<div>ConfigResolutionPanel</div>`
  },
}))

vi.mock('../tool-executor/tool-executor', () => ({
  ToolExecutor: () => html`<div>ToolExecutor</div>`,
}))

import { Tools } from './tools-main'

function waitingInventoryFixture(
  keeperNames: string[] = ['sangsu'],
): DashboardKeeperWaitingInventory {
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v3',
    source: 'server_keeper_waiting_inventory',
    keeper_count_known: true,
    keeper_count: keeperNames.length,
    waiting_keeper_count: keeperNames.length,
    row_count: keeperNames.length,
    global_row_count: 0,
    keepers: keeperNames.map(keeperName =>
      ({
        keeper_name: keeperName,
        state: 'waiting',
        state_sources: ['event_queue_pending'],
        waiting_count: 1,
        waiting_on: [
          {
            keeper_name: keeperName,
            source: 'event_queue_pending',
            waiting_on: 'bootstrap',
            what: '기동 직후 첫 턴',
            wake_producer: 'keeper_supervisor',
            next_action: 'keeper_drain_event_queue',
          },
        ],
      })),
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
    confirmRuntimeTestWorkspace()
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.loadTools.mockClear()
    mocks.subscribeToolsAutoRefresh.mockClear()
    mocks.fetchDashboardTools.mockReset()
    mocks.configResolutionPanel.mockClear()
    mocks.toolsData.value = null
    mocks.toolsLoading.value = false
    mocks.toolsError.value = null
    mocks.scheduledAutomationProjection.value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('does not draw the warming envelope placeholder as observed usage', async () => {
    // A cold read answers with status/is_warming set and a tool_usage of
    // zeroes (server_dashboard_http_runtime_info.ml). Handing that object to
    // ToolMetrics drew "0 calls, 0 tools observed" as a measurement, which
    // reads as "nothing has ever been called" rather than "not built yet".
    mocks.toolsData.value = {
      status: 'warming',
      is_warming: true,
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
    }

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.textContent).toContain('ToolMetrics:none')
    expect(container.textContent).not.toContain('ToolMetrics:usage')
  })

  it('hands real usage to the metrics pane once the projection is built', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 103,
        distinct_tools_called: 26,
        never_called_count: 77,
      },
    }

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.textContent).toContain('ToolMetrics:usage')
  })

  it('loads tool data and renders full inventory with prompt registry inside the tools surface', async () => {
    render(html`<${Tools} />`, container)
    await flush()

    expect(container.querySelector('.v2-lab-surface')).not.toBeNull()
    expect(container.querySelectorAll('.v2-lab-action')).toHaveLength(2)
    // The surface subscribes rather than loading once by hand.
    // subscribeToolsAutoRefresh performs the first load itself and keeps a
    // visibility-aware poller, which is what brings the finished projection
    // in after a cold read answered with the warming envelope.
    expect(mocks.subscribeToolsAutoRefresh).toHaveBeenCalledTimes(1)
    expect(mocks.loadTools).not.toHaveBeenCalled()
    expect(container.textContent).toContain('ConfigResolutionPanel')
    expect(container.textContent).toContain('예약 자동화 FSM')
    expect(container.textContent).toContain('시스템 도구 목록')
    expect(container.textContent).toContain('FullInventoryView')
    expect(container.textContent).toContain('도구 사용 현황')
    expect(container.textContent).toContain('ToolMetrics')
    expect(container.textContent).toContain('ToolSeriesPanel')
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
    mocks.scheduledAutomationProjection.value = {
      state: 'available',
      page: { visibleCount: 1, totalCount: 1, limit: 20, truncated: false },
      data: {
        schema: 'masc.dashboard.scheduled_automation.v1',
        source: 'schedule_store',
        generated_at: '2026-06-13T00:00:00Z',
        status: 'ok',
        schedule_store_known: true,
        schedule_store_read_error: null,
        request_count: 1,
        request_limit: 20,
        truncated: false,
        counts: { due: 1 },
        payload_support: {
          supported_kinds: ['masc.board_post'],
          unsupported_request_count: 1,
          unsupported_kinds: [{ kind: 'test.reminder', count: 1 }],
          unknown_request_count: 0,
        },
        fsm: {
          state: 'due',
          active_count: 1,
          terminal_count: 0,
          next_due_at: '2026-06-13T01:00:00Z',
        },
        requests: [
          {
            schedule_id: 'sched-1',
            status: 'due',
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
            last_wake: {
              schedule_id: 'sched-1',
              started_at_iso: '2026-06-13T00:30:00Z',
              finished_at_iso: '2026-06-13T00:30:01Z',
              status: 'succeeded',
            },
          },
        ],
      },
    }
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.textContent).toContain('due')
    expect(container.querySelectorAll('[data-schedule-mutation]')).toHaveLength(0)
    expect(container.textContent).toContain('sched-1')
    expect(container.textContent).toContain('cron 0 9 * * 1-5 Asia/Seoul')
    expect(container.textContent).toContain('succeeded')
    expect(container.textContent).toContain('test.reminder')
    expect(container.textContent).toContain('unsupported payload')
    expect(container.textContent).toContain('unsupported')
    expect(container.textContent).toContain('wake signal feed')
    expect(container.textContent).toContain('operator (human operator)')
    expect(container.textContent).toContain('Keeper Waiting Inventory')
    expect(container.textContent).toContain('sangsu')
    // The shared lane row shows a waiting source as the server word, the
    // raw enum, and does not rewrite it into a humanized label.
    expect(container.textContent).toContain('event_queue_pending')
    expect(container.textContent).not.toContain('event queue pending')
    expect(container.querySelector('[data-schedule-id="sched-1"]')).not.toBeNull()
    expect(container.querySelector('.v2-lab-card')).not.toBeNull()
  })

  it('keeps the Tools surface alive while config projections warm', async () => {
    mocks.toolsData.value = {
      config_resolution: { status: 'warming' },
      runtime_resolution: { status: 'warming' },
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    } as MockToolsResponse

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.querySelector('[data-testid="tools-config-resolution-warming"]'))
      .not.toBeNull()
    expect(container.textContent).toContain('Keeper Waiting Inventory')
    expect(container.textContent).toContain('FullInventoryView')
    expect(mocks.configResolutionPanel).toHaveBeenLastCalledWith({
      resolution: undefined,
      runtimeResolution: undefined,
    })
  })

  it('renders tool usage coverage gap provenance', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
        non_public_call_log: {
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
