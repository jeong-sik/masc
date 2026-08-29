import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardKeeperWaitingInventory,
  DashboardScheduledAutomationProjection,
  DashboardToolsResponse,
} from '../../api'

type MockToolsResponse = {
  generated_at?: string
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

vi.mock('./tool-state', () => ({
  loadTools: mocks.loadTools,
  toolsData: mocks.toolsData,
  toolsError: mocks.toolsError,
  toolsLoading: mocks.toolsLoading,
  KEEPER_WAITING_INVENTORY_REFRESH_MS: 15_000,
}))

vi.mock('../../lib/auto-refresh', () => ({
  setupVisibleAutoRefresh: () => () => {},
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

function keeperReceiptFixture(
  keeperName: string,
  sessionId = 'trace-one',
): DashboardToolsResponse {
  const reference = {
    identity: {
      source_id: 'project-masc',
      package_id: 'ocaml-coding',
      name: 'ocaml-coding',
    },
    content_revision: 'a'.repeat(64),
  }
  return {
    tool_inventory: { count: 0, tools: [] },
    tool_usage: {
      total_calls: 0,
      distinct_tools_called: 0,
      top_20: [],
      never_called_count: 0,
      registered_count: 0,
    },
    effective_keeper_surface: {
      status: 'available',
      keeper_name: keeperName,
      runtime_id: 'openai.codex',
      official_client_kind: 'codex',
      tool_delivery: { status: 'delivered' },
      native_posture: 'read',
      skill_selection: { mode: 'all' },
      unavailable_skill_names: [],
      current_task_id: 'task-001',
      skill_snapshot_revision: 'd'.repeat(64),
      skill_resource_read_max_bytes: 65_536,
      instruction_skills: [reference],
      composition_skills: [],
      skill_profiles: [{
        reference,
        kind: 'instruction',
        execution: 'on_demand',
        context: {
          body_bytes: 840,
          eager_body_bytes: 0,
          discovery_bytes: 160,
          tool_schema_bytes: null,
        },
        load_reasons: [
          { kind: 'task', task_id: 'task-001' },
          { kind: 'keeper_profile' },
        ],
      }],
      tool_surface_bytes: 4_800,
      skill_tool_surface_bytes: 320,
      skill_discovery_bytes: 160,
      skill_eager_body_bytes: 0,
      skill_body_bytes: 840,
      skills_left_out: [],
      count: 2,
      tools: [],
      tool_surface_sha256: 'b'.repeat(64),
    },
    skill_activations: {
      status: 'available',
      keeper_name: keeperName,
      summary: {
        instruction_invocations: 1,
        skill_bodies_served: 1,
        skill_resources_served: 0,
        instruction_provider_deliveries: 1,
        instruction_official_client_handoffs: 0,
        instruction_actions_observed: 1,
        composition_invocations: 0,
        composition_provider_deliveries: 0,
        composition_official_client_handoffs: 0,
        composition_actions_observed: 0,
        invalid_transitions: 0,
      },
      scoped_summaries: [{
        scope: {
          snapshot_revision: 'd'.repeat(64),
          turn_ref: `${sessionId}#1`,
          invocation_runtime_id: 'openai.codex',
          reference,
        },
        summary: {
          instruction_invocations: 1,
          skill_bodies_served: 1,
          skill_resources_served: 0,
          instruction_provider_deliveries: 1,
          instruction_official_client_handoffs: 0,
          instruction_actions_observed: 1,
          composition_invocations: 0,
          composition_provider_deliveries: 0,
          composition_official_client_handoffs: 0,
          composition_actions_observed: 0,
          invalid_transitions: 0,
        },
        provider_delivery_runtime_counts: [{ runtime_id: 'anthropic.claude', count: 1 }],
        official_client_handoff_runtime_counts: [],
        action_runtime_counts: [{ runtime_id: 'anthropic.claude', count: 1 }],
      }],
      ledger: {
        schema: 'masc.skill-activations/v5',
        workspace_key: 'e'.repeat(64),
        session_id: sessionId,
        revision: 'c'.repeat(64),
        activations: [
          {
            ...reference,
            snapshot_revision: 'd'.repeat(64),
            turn_ref: `${sessionId}#1`,
            runtime_id: 'openai.codex',
            skill_tool_use_id: 'call-skill-1',
            agent_core_turn: 0,
            invocation: {
              kind: 'instruction',
              origin: { kind: 'task_instruction', task_ids: ['task-001', 'task-held'] },
              served_content: {
                kind: 'skill_body',
                bytes: 12,
                sha256: 'f'.repeat(64),
              },
            },
            delivery: {
              boundary: { kind: 'model_response', agent_core_turn: 1 },
              runtime_id: 'anthropic.claude',
              delivered_at: '2026-08-26T00:00:01Z',
              content_bytes: 12,
              content_sha256: 'f'.repeat(64),
            },
            actions: [{
              identity: {
                kind: 'provider_step',
                conversation_id: 'conversation-antigravity',
                step_index: 7,
              },
              tool_name: 'keeper_time_now',
              runtime_id: 'anthropic.claude',
              agent_core_turn: 1,
              observed_at: '2026-08-26T00:00:02Z',
            }],
            activated_at: '2026-08-26T00:00:00Z',
          },
        ],
        transition_rejections: [],
      },
    },
  }
}

function selectKeeper(container: HTMLElement, keeperName: string): void {
  const selector = container.querySelector('select') as HTMLSelectElement
  selector.value = keeperName
  selector.dispatchEvent(new Event('change', { bubbles: true }))
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
    // #30068 moved this panel onto the shared lane row, where a waiting
    // source renders through LANE_SOURCE_LABELS instead of the raw enum.
    // The row still names which queue the keeper is waiting on; only the
    // wording changed.
    expect(container.textContent).toContain('자율 이벤트')
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
    expect(container.textContent).toContain('Keeper Skill Receipts')
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

  it('loads and renders exact Keeper Skill receipts', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }
    const receipt = keeperReceiptFixture('sangsu')
    if (receipt.effective_keeper_surface?.status !== 'available') {
      throw new Error('fixture effective surface is not available')
    }
    receipt.effective_keeper_surface.skill_selection = {
      mode: 'names',
      names: ['ocaml-coding', 'proof-harness'],
    }
    receipt.effective_keeper_surface.unavailable_skill_names = [{
      name: 'proof-harness',
      reason: 'not_in_turn_skill_catalog',
    }]
    mocks.fetchDashboardTools.mockResolvedValue(receipt)

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(mocks.fetchDashboardTools).toHaveBeenCalledWith(expect.objectContaining({
      keeperName: 'sangsu',
    }))
    expect(container.textContent).toContain('project-masc/ocaml-coding:ocaml-coding@')
    expect(container.querySelector('[data-testid="skill-context-totals"]')?.textContent)
      .toContain('profile discovery 160 B · eager 0 B · deferred bodies 840 B')
    expect(container.querySelector('[data-testid="skill-load-reason"]')?.textContent)
      .toContain('Task task-001 + Keeper profile')
    expect(container.textContent).toContain('Task instruction · task-001, task-held')
    expect(container.textContent).toContain(`snapshot ${'d'.repeat(64)}`)
    expect(container.querySelector('[data-testid="skill-selection"]')?.textContent)
      .toContain('ocaml-coding')
    expect(container.querySelector('[data-testid="skill-selection"]')?.textContent)
      .toContain('proof-harness')
    expect(container.querySelectorAll('[data-testid="unavailable-skill-name"]'))
      .toHaveLength(1)
    expect(container.querySelector('[data-testid="unavailable-skill-names"]')?.textContent)
      .toContain('proof-harness · not_in_turn_skill_catalog')
    expect(container.textContent).toContain('session totals')
    expect(container.textContent).toContain('proof project-masc/ocaml-coding:ocaml-coding')
    expect(container.textContent).toContain('invoked 1')
    expect(container.textContent).toContain('provider deliveries 1')
    expect(container.textContent).toContain('official handoffs 0')
    expect(container.textContent).toContain('actions 1')
    expect(container.textContent).toContain('invalid 0')
    expect(container.textContent).toContain('call-skill-1')
    expect(container.textContent).toContain('keeper_time_now')
    expect(container.textContent).toContain('invocation runtime openai.codex')
    expect(container.textContent).toContain('provider delivery runtimes anthropic.claude:1')
    expect(container.textContent).toContain('official handoff runtimes none')
    expect(container.textContent).toContain('action runtimes anthropic.claude:1')
    expect(container.textContent).toContain('provider delivered turn 1 · runtime anthropic.claude')
    expect(container.textContent).toContain('action turn 1 · runtime anthropic.claude')
    expect(
      container.querySelector('[data-testid="skill-activation-ledger"]')
        ?.getAttribute('data-ledger-revision'),
    ).toBe('c'.repeat(64))
    expect(
      container.querySelector('[data-testid="skill-activation-ledger"]')
        ?.getAttribute('data-keeper-name'),
    ).toBe('sangsu')
    expect(
      Array.from(container.querySelectorAll('[data-testid="skill-activation-row"]'))
        .map(row => row.getAttribute('data-skill-tool-use-id')),
    ).toEqual(['call-skill-1'])
  })

  it('distinguishes inherited all Skills from an explicit empty selection', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }
    const allReceipt = keeperReceiptFixture('sangsu')
    mocks.fetchDashboardTools.mockResolvedValueOnce(allReceipt)

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(container.querySelector('[data-testid="skill-selection"]')?.textContent)
      .toContain('All published Skills')

    const noneReceipt = keeperReceiptFixture('sangsu')
    if (noneReceipt.effective_keeper_surface?.status !== 'available') {
      throw new Error('fixture effective surface is not available')
    }
    noneReceipt.effective_keeper_surface.skill_selection = { mode: 'names', names: [] }
    mocks.fetchDashboardTools.mockResolvedValueOnce(noneReceipt)
    selectKeeper(container, '')
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(container.querySelector('[data-testid="skill-selection"]')?.textContent)
      .toContain('No Skills selected')
  })

  it('shows an official-client handoff without a later action as incomplete proof', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }
    const receipt = keeperReceiptFixture('sangsu')
    if (receipt.skill_activations?.status !== 'available') {
      throw new Error('expected available Skill activation fixture')
    }
    receipt.skill_activations.summary.instruction_provider_deliveries = 0
    receipt.skill_activations.summary.instruction_official_client_handoffs = 1
    receipt.skill_activations.summary.instruction_actions_observed = 0
    const scoped = receipt.skill_activations.scoped_summaries[0]!
    scoped.summary.instruction_provider_deliveries = 0
    scoped.summary.instruction_official_client_handoffs = 1
    scoped.summary.instruction_actions_observed = 0
    scoped.provider_delivery_runtime_counts = []
    scoped.official_client_handoff_runtime_counts = [
      { runtime_id: 'openai.codex', count: 1 },
    ]
    scoped.action_runtime_counts = []
    const activation = receipt.skill_activations.ledger.activations[0]!
    if (activation.delivery === null) throw new Error('expected delivery fixture')
    activation.delivery.boundary = {
      kind: 'official_client_result_handoff',
      agent_core_turn: 0,
    }
    activation.delivery.runtime_id = 'openai.codex'
    activation.actions = []
    mocks.fetchDashboardTools.mockResolvedValue(receipt)

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(container.textContent).toContain('provider deliveries 0')
    expect(container.textContent).toContain('official handoffs 1')
    expect(container.textContent).toContain('official handoff runtimes openai.codex:1')
    expect(container.textContent).toContain('official client handoff turn 0 · runtime openai.codex')
    expect(container.textContent).toContain('proof incomplete: no later action')
  })

  it('fails loudly when one Keeper projection is omitted', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }
    const partial = keeperReceiptFixture('sangsu')
    delete partial.skill_activations
    mocks.fetchDashboardTools.mockResolvedValue(partial)

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(container.textContent).toContain('Server response omitted skill_activations')
    expect(container.querySelector('[data-testid="skill-effective-surface"]')).toBeNull()
  })

  it('shows runtime capability suppression as a normal typed posture', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }
    const receipt = keeperReceiptFixture('sangsu')
    if (receipt.effective_keeper_surface?.status !== 'available') {
      throw new Error('fixture effective surface is not available')
    }
    receipt.effective_keeper_surface.tool_delivery = {
      status: 'suppressed',
      reason: 'runtime_tools_unsupported',
    }
    receipt.effective_keeper_surface.instruction_skills = []
    receipt.effective_keeper_surface.composition_skills = []
    receipt.effective_keeper_surface.skill_profiles = []
    receipt.effective_keeper_surface.skill_discovery_bytes = 0
    receipt.effective_keeper_surface.skill_eager_body_bytes = 0
    receipt.effective_keeper_surface.skill_body_bytes = 0
    receipt.effective_keeper_surface.skill_tool_surface_bytes = 0
    receipt.effective_keeper_surface.tools = []
    receipt.effective_keeper_surface.count = 0
    mocks.fetchDashboardTools.mockResolvedValue(receipt)

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(container.querySelector('[data-testid="skill-tool-delivery-suppressed"]'))
      .not.toBeNull()
    expect(container.textContent).toContain('runtime_tools_unsupported')
  })

  it('rejects a receipt belonging to another Keeper', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(),
    }
    mocks.fetchDashboardTools.mockResolvedValue(keeperReceiptFixture('other-keeper'))

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'sangsu')
    await flush()

    expect(container.textContent).toContain(
      'effective_keeper_surface belongs to other-keeper, not sangsu',
    )
    expect(container.querySelector('[data-testid="skill-effective-surface"]')).toBeNull()
  })

  it('does not render a late receipt after the selected Keeper changes', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
      },
      keeper_waiting_inventory: waitingInventoryFixture(['alpha', 'beta']),
    }
    let resolveAlpha: ((value: DashboardToolsResponse) => void) | undefined
    let resolveBeta: ((value: DashboardToolsResponse) => void) | undefined
    mocks.fetchDashboardTools.mockImplementation(({ keeperName }: { keeperName: string }) =>
      new Promise<DashboardToolsResponse>(resolve => {
        if (keeperName === 'alpha') resolveAlpha = resolve
        if (keeperName === 'beta') resolveBeta = resolve
      }))

    render(html`<${Tools} />`, container)
    await flush()
    selectKeeper(container, 'alpha')
    await flush()
    selectKeeper(container, 'beta')
    await flush()

    resolveBeta?.(keeperReceiptFixture('beta', 'trace-beta'))
    await flush()
    expect(container.textContent).toContain('session trace-beta')

    resolveAlpha?.(keeperReceiptFixture('alpha', 'trace-alpha'))
    await flush()
    expect(container.textContent).toContain('session trace-beta')
    expect(container.textContent).not.toContain('session trace-alpha')
  })
})
