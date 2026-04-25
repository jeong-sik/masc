import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetrySummaryResponse, ToolQualityResponse } from '../api/dashboard'
import { normalizeKeepers } from '../keeper-store-normalize'
import type { DashboardExecutionResponse, DashboardNamespaceTruthResponse } from '../types'
import { filterFleetRows } from './fleet-telemetry-panel'
import type { FleetRow } from './fleet-telemetry-utils'

function makeRow(overrides: Partial<FleetRow> = {}): FleetRow {
  return {
    name: 'keeper-x',
    status: 'active',
    keepalive_running: true,
    diagnostic_health_state: null,
    diagnostic_summary: null,
    context_ratio: 0.3,
    turn_count: 0,
    last_latency_ms: 0,
    last_activity_ago_s: null,
    activity_label: '최근 활동',
    activity_source: 'none',
    model: '',
    tool_calls: 0,
    tool_success_pct: null,
    tool_activity_known: false,
    recent_tools: [],
    runtime_blocker_class: null,
    runtime_blocker_summary: null,
    tool_audit_at: null,
    goal_label: null,
    goal_linked: false,
    active_goal_count: 0,
    sandbox_profile: null,
    sandbox_last_error: null,
    effective_sandbox_image: null,
    decision_required: false,
    budget_source: null,
    ...overrides,
  }
}

describe('filterFleetRows', () => {
  const rows: FleetRow[] = [
    makeRow({ name: 'keeper-alpha', model: 'gpt-5.4' }),
    makeRow({ name: 'keeper-beta', model: 'claude-sonnet-4-6' }),
    makeRow({ name: 'watcher-gamma', model: 'gpt-5.4', runtime_blocker_class: 'turn_timeout' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterFleetRows(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterFleetRows(rows, '   ')).toBe(rows)
  })

  it('matches by name substring (case-insensitive)', () => {
    const result = filterFleetRows(rows, 'KEEPER')
    expect(result).toHaveLength(2)
    expect(result.map(r => r.name)).toEqual(['keeper-alpha', 'keeper-beta'])
  })

  it('matches by model substring', () => {
    const result = filterFleetRows(rows, 'claude')
    expect(result.map(r => r.name)).toEqual(['keeper-beta'])
  })

  it('matches by runtime_blocker_class substring', () => {
    const result = filterFleetRows(rows, 'turn_timeout')
    expect(result.map(r => r.name)).toEqual(['watcher-gamma'])
  })

  it('returns empty when no field matches', () => {
    expect(filterFleetRows(rows, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterFleetRows(rows, '  alpha  ')).toHaveLength(1)
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterFleetRows(rows, 'alpha')
    expect(rows).toEqual(copy)
  })

  it('handles rows with null model and null blocker safely', () => {
    const input: FleetRow[] = [makeRow({ name: 'orphan', model: '', runtime_blocker_class: null })]
    expect(filterFleetRows(input, 'orphan')).toHaveLength(1)
    expect(filterFleetRows(input, 'anything-else')).toHaveLength(0)
  })
})

const executionResponse = {
  generated_at: '2026-04-09T08:10:00Z',
  keepers: [
    {
      name: 'keeper-alpha',
      status: 'active',
      keepalive_running: true,
      context_ratio: 0.82,
      total_turns: 48,
      last_latency_ms: 2300,
      last_activity_ago_s: 30,
      last_model_used: 'gpt-5.4',
      recent_tool_names: ['masc_status', 'masc_dashboard'],
    },
    {
      name: 'keeper-beta',
      status: 'idle',
      keepalive_running: true,
      context_ratio: 0.12,
      total_turns: 9,
      last_latency_ms: 980,
      last_activity_ago_s: 320,
      last_model_used: 'glm-5',
      recent_tool_names: [],
    },
  ],
} satisfies DashboardExecutionResponse

const toolQualityResponse: ToolQualityResponse = {
  total: 22,
  success: 21,
  failure: 1,
  success_rate: 95.5,
  by_tool: [],
  by_keeper: [
    {
      name: 'keeper-alpha',
      calls: 22,
      success_pct: 95.5,
    },
  ],
  failure_categories: [
    {
      category: 'timeout',
      count: 1,
    },
  ],
  hourly_trend: [],
}

const telemetrySummaryResponse: TelemetrySummaryResponse = {
  generated_at: '2026-04-09T08:11:00Z',
  total_entries: 321,
  sources: [
    {
      source: 'keeper_metric',
      entry_count: 200,
      keeper_count: 2,
      exists: true,
    },
    {
      source: 'tool_metric',
      entry_count: 121,
      exists: true,
    },
  ],
}

const namespaceTruthResponse: DashboardNamespaceTruthResponse = {
  generated_at: '2026-04-09T08:11:30Z',
  root: {},
  execution: {
    summary: {
      active_sessions: 2,
      active_operations: 4,
      continuity_alerts: 1,
    },
    top_queue: null,
    provenance: 'test',
  },
  operator: {
    health: 'ok',
    pending_confirm_summary: {
      actor_filter: null,
      filter_active: false,
      visible_count: 1,
      total_count: 1,
      hidden_count: 0,
      hidden_actors: [],
      confirm_required_actions: [],
    },
    attention_summary: {
      count: 1,
      bad_count: 0,
      warn_count: 1,
      provenance: 'test',
      top_item: null,
    },
    recommendation_summary: null,
    provenance: 'test',
  },
  readiness: {
    status: 'warn',
    score: 0.67,
    decision_required_count: 1,
    blocking_count: 2,
    pillars: [
      {
        key: 'execution_safety',
        label: 'Execution Safety',
        status: 'ok',
        score: 1,
        summary: 'Sandbox and approval posture are visible.',
        blocking_reasons: [],
        metrics: { keeper_count: 2 },
      },
      {
        key: 'autonomy_reliability',
        label: 'Autonomy Reliability',
        status: 'warn',
        score: 0.5,
        summary: 'One keeper is asking for intervention.',
        blocking_reasons: ['1 keeper requires a continue gate decision.'],
        metrics: { decision_required: 1 },
      },
    ],
  },
  attention_events: [
    {
      severity: 'warn',
      kind: 'continue_gate',
      summary: 'keeper-alpha is blocked on a continue decision.',
      requires_decision: true,
      keeper_name: 'keeper-alpha',
      target_type: 'keeper',
      target_id: 'keeper-alpha',
      recommended_action: 'Open interventions and approve or pause the run.',
      provenance: 'test',
    },
  ],
  focus: null,
}

const metricSeriesPoint = {
  ts_unix: 1_744_186_600,
  context_ratio: 0.4,
  latency_ms: 1200,
  generation: 3,
  channel: 'turn',
}

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
    }
  })
}

function requireResolver<T>(
  resolver: ((value: T) => void) | null,
  label: string,
): (value: T) => void {
  if (!resolver) {
    throw new Error(label)
  }
  return resolver
}

async function loadPanel(mocks: {
  fetchDashboardExecution: (opts?: { signal?: AbortSignal }) => Promise<DashboardExecutionResponse>
  fetchToolQuality: (opts?: { n?: number; windowHours?: number; signal?: AbortSignal }) => Promise<ToolQualityResponse>
  fetchTelemetrySummary: (opts?: { signal?: AbortSignal }) => Promise<TelemetrySummaryResponse>
  fetchDashboardNamespaceTruth?: (opts?: { signal?: AbortSignal }) => Promise<DashboardNamespaceTruthResponse>
}) {
  vi.resetModules()
  vi.doMock('../api/dashboard', () => ({
    fetchDashboardExecution: mocks.fetchDashboardExecution,
    fetchToolQuality: mocks.fetchToolQuality,
    fetchTelemetrySummary: mocks.fetchTelemetrySummary,
    fetchDashboardNamespaceTruth:
      mocks.fetchDashboardNamespaceTruth
      ?? vi.fn().mockResolvedValue(namespaceTruthResponse),
  }))
  return import('./fleet-telemetry-panel')
}

describe('FleetTelemetryPanel', () => {
  let container: HTMLDivElement
  const originalVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState')

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
    vi.useRealTimers()
    if (originalVisibility) {
      Object.defineProperty(document, 'visibilityState', originalVisibility)
    }
  })

  it('renders the full fleet even when tool telemetry exists for only one keeper', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue(executionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue(toolQualityResponse)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const fetchDashboardNamespaceTruth = vi.fn().mockResolvedValue(namespaceTruthResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
      fetchDashboardNamespaceTruth,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)
    expect(fetchDashboardNamespaceTruth).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('Keeper 가동률')
    expect(container.textContent).toContain('1/2 keepers surfaced recent tool activity.')
    expect(container.textContent).toContain('keeper-alpha')
    expect(container.textContent).toContain('keeper-beta')
    expect(container.textContent).toContain('Keeper 턴 로그')
    expect(container.textContent).toContain('Failure Categories')
    expect(container.textContent).toContain('Fleet Control Room')
  }, 60_000)

  it('renders readiness cards, attention events, and keeper goal or sandbox badges', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue({
      ...executionResponse,
      keepers: [
        {
          ...executionResponse.keepers[0],
          active_goal_ids: ['goal-1'],
          short_goal: 'Ship safer keeper ops',
          sandbox_profile: 'docker',
          effective_sandbox_image: 'ghcr.io/acme/keeper:latest',
          sandbox_last_error: 'bind EPERM at /var/folders/tmp',
          runtime_blocker_continue_gate: true,
        },
      ],
    } satisfies DashboardExecutionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue(toolQualityResponse)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Readiness')
    expect(container.textContent).toContain('Approvals')
    expect(container.textContent).toContain('Attention Queue')
    expect(container.textContent).toContain('keeper-alpha is blocked on a continue decision.')
    expect(container.textContent).toContain('goal linked')
    expect(container.textContent).toContain('sandbox docker')
    expect(container.textContent).toContain('decision')
    expect(container.textContent).toContain('Ship safer keeper ops')
    expect(container.textContent).toContain('bind EPERM at /var/folders/tmp')
  }, 60_000)

  it('warns when keepers are stuck before reaching tool execution', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue({
      ...executionResponse,
      keepers: [
        {
          name: 'keeper-alpha',
          status: 'active',
          keepalive_running: true,
          context_ratio: 0.22,
          total_turns: 48,
          last_latency_ms: 45_000,
          last_activity_ago_s: 20,
          last_model_used: 'gpt-5.4',
          runtime_blocker_class: 'admission_queue_wait_timeout',
          runtime_blocker_summary: 'Admission queue wait timeout after 45.0s.',
          recent_tool_names: [],
        },
      ],
    } satisfies DashboardExecutionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue({
      ...toolQualityResponse,
      total: 0,
      success: 0,
      failure: 0,
      success_rate: 0,
      by_keeper: [],
      failure_categories: [],
    })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Partial telemetry')
    expect(container.textContent).toContain('keepers are blocked in the admission queue')
    expect(container.textContent).toContain('Admission queue wait timeout after 45.0s.')
  }, 30_000)

  it('surfaces snapshot diagnostic summaries for inactive keepers', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue({
      ...executionResponse,
      keepers: [
        {
          name: 'keeper-stale',
          status: 'inactive',
          keepalive_running: true,
          context_ratio: 0.22,
          total_turns: 11,
          last_latency_ms: 1200,
          last_activity_ago_s: 640,
          last_model_used: 'gpt-5.4',
          diagnostic: {
            health_state: 'stale',
            next_action_path: 'recover',
            last_reply_status: 'stale',
            summary: 'Keepalive heartbeat is stale; probe or recover before the next turn.',
          },
        },
      ],
    } satisfies DashboardExecutionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue({ ...toolQualityResponse, by_keeper: [] })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('keeper-stale')
    expect(container.textContent).toContain('Keepalive heartbeat is stale; probe or recover before the next turn.')
    expect(container.textContent).toContain('1 주의')
  }, 30_000)

  it('falls back to runtime model and tool audit data when quality rows are sparse', async () => {
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const keepers = normalizeKeepers([
      {
        name: 'keeper-sparse',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.41,
        total_turns: 12,
        last_activity_ago_s: 45,
        latest_tool_call_count: 3,
        tool_audit_source: 'heartbeat_result',
        tool_audit_at: '2026-04-09T08:10:30Z',
        metrics_window: {
          tool_call_count: 3,
          top_tools: [
            { tool: 'masc_status', count: 2 },
            { tool: 'keeper_stay_silent', count: 1 },
          ],
        },
        metrics_series: [
          {
            ...metricSeriesPoint,
            model_used: 'glm-5.1',
          },
        ],
      },
    ])

    const rows = buildFleetRows(keepers, {
      ...toolQualityResponse,
      by_keeper: [],
    })

    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      name: 'keeper-sparse',
      model: 'glm-5.1',
      tool_calls: 3,
      tool_activity_known: true,
    })
    expect(rows[0]?.recent_tools).toEqual(['masc_status', 'keeper_stay_silent'])
  })

  it('uses display model and freshest keeper activity helpers for fleet rows', async () => {
    vi.setSystemTime(new Date('2026-04-24T18:00:00Z'))
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const keepers = normalizeKeepers([
      {
        name: 'keeper-placeholder-model',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.3,
        total_turns: 5,
        last_model_used: 'unknown',
        last_autonomous_action_at: '2026-04-24T12:00:00Z',
        last_heartbeat: '2026-04-24T17:54:00Z',
        active_model: 'gpt-5.4',
        metrics_series: [
          { ...metricSeriesPoint, model_used: 'unknown' },
        ],
        metrics_window: {
          primary_model: 'none',
        },
      },
    ])

    const rows = buildFleetRows(keepers, { ...toolQualityResponse, by_keeper: [] })

    expect(rows).toHaveLength(1)
    expect(rows[0]?.model).toBe('gpt-5.4')
    expect(rows[0]).toMatchObject({
      activity_label: '하트비트',
      activity_source: 'heartbeat',
      last_activity_ago_s: 360,
    })
  })

  it('sorts attention keepers ahead of healthy and offline rows', async () => {
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const keepers = normalizeKeepers([
      {
        name: 'keeper-fresh',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.22,
        total_turns: 9,
        last_activity_ago_s: 20,
      },
      {
        name: 'keeper-hot',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.91,
        total_turns: 4,
        last_activity_ago_s: 1400,
      },
      {
        name: 'keeper-offline',
        status: 'offline',
        keepalive_running: false,
        context_ratio: 0.1,
        total_turns: 20,
      },
    ])

    const rows = buildFleetRows(keepers, {
      ...toolQualityResponse,
      by_keeper: [],
    })

    expect(rows.map(row => row.name)).toEqual([
      'keeper-hot',
      'keeper-fresh',
      'keeper-offline',
    ])
  })

  it('marks tool-quality-only fallback rows as known tool activity', async () => {
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const rows = buildFleetRows([], {
      ...toolQualityResponse,
      by_keeper: [
        {
          name: 'keeper-tool-only',
          calls: 5,
          success_pct: 100,
        },
      ],
    })

    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      name: 'keeper-tool-only',
      tool_calls: 5,
      tool_activity_known: true,
      model: 'unknown',
    })
  })

  it('prefers tool-quality call counts when success data is present', async () => {
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const keepers = normalizeKeepers([
      {
        name: 'keeper-quality-preferred',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.25,
        total_turns: 4,
        latest_tool_call_count: 8,
        metrics_window: {
          tool_call_count: 11,
        },
      },
    ])

    const rows = buildFleetRows(keepers, {
      ...toolQualityResponse,
      by_keeper: [
        {
          name: 'keeper-quality-preferred',
          calls: 3,
          success_pct: 66.7,
        },
      ],
    })

    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      name: 'keeper-quality-preferred',
      tool_calls: 3,
      tool_success_pct: 66.7,
    })
  })

  it('ignores placeholder audit sources when deciding tool telemetry availability', async () => {
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const keepers = normalizeKeepers([
      {
        name: 'keeper-placeholder-audit',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.11,
        total_turns: 2,
        tool_audit_source: 'none',
        latest_tool_call_count: null,
      },
    ])

    const rows = buildFleetRows(keepers, {
      ...toolQualityResponse,
      by_keeper: [],
    })

    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      name: 'keeper-placeholder-audit',
      tool_calls: 0,
      tool_activity_known: false,
    })
  })

  it('keeps low-success active rows ahead of paused rows without penalizing null success rates', async () => {
    const { buildFleetRows } = await loadPanel({
      fetchDashboardExecution: vi.fn().mockResolvedValue(executionResponse),
      fetchToolQuality: vi.fn().mockResolvedValue(toolQualityResponse),
      fetchTelemetrySummary: vi.fn().mockResolvedValue(telemetrySummaryResponse),
    })

    const keepers = normalizeKeepers([
      {
        name: 'keeper-healthy-null',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.2,
        total_turns: 8,
        last_activity_ago_s: 40,
      },
      {
        name: 'keeper-low-success',
        status: 'active',
        keepalive_running: true,
        context_ratio: 0.2,
        total_turns: 8,
        last_activity_ago_s: 40,
      },
      {
        name: 'keeper-paused',
        status: 'paused',
        keepalive_running: true,
        context_ratio: 0.2,
        total_turns: 8,
        last_activity_ago_s: 40,
      },
    ])

    const rows = buildFleetRows(keepers, {
      ...toolQualityResponse,
      by_keeper: [
        {
          name: 'keeper-low-success',
          calls: 4,
          success_pct: 70,
        },
      ],
    })

    expect(rows.map(row => row.name)).toEqual([
      'keeper-low-success',
      'keeper-healthy-null',
      'keeper-paused',
    ])
  })

  it('renders tool activity fallback copy instead of misleading no-tools text', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue({
      ...executionResponse,
      keepers: [
        executionResponse.keepers[0],
        {
          ...executionResponse.keepers[1],
          last_model_used: '',
          latest_tool_call_count: 3,
          tool_audit_source: 'heartbeat_result',
          tool_audit_at: '2026-04-09T08:10:30Z',
          metrics_series: [
            {
              ...metricSeriesPoint,
              model_used: 'glm-5.1',
            },
          ],
        },
      ],
    } as DashboardExecutionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue(toolQualityResponse)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('3 tool calls')
    expect(container.textContent).not.toContain('No recent tools')
    expect(container.textContent).toContain('glm-5.1')
  })

  it('shows partial telemetry warnings while keeping degraded data visible', async () => {
    const fetchDashboardExecution = vi.fn().mockRejectedValue(new Error('execution down'))
    const fetchToolQuality = vi.fn().mockResolvedValue({
      ...toolQualityResponse,
      by_keeper: [
        {
          name: 'keeper-fallback',
          calls: 3,
          success_pct: 100,
        },
      ],
    })
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Partial telemetry')
    expect(container.textContent).toContain('Execution snapshot unavailable: execution down')
    expect(container.textContent).toContain('keeper-fallback')
    expect(container.textContent).toContain('Telemetry Stores')
  }, 60_000)

  it('warns when the OAS relay lags behind fresher agent telemetry', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue(executionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue(toolQualityResponse)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue({
      generated_at: '2026-04-09T08:11:00Z',
      total_entries: 366,
      sources: [
        {
          source: 'agent_event',
          entry_count: 220,
          exists: true,
          latest_ts_unix: 2_000,
          latest_age_s: 30,
        },
        {
          source: 'oas_event',
          entry_count: 146,
          exists: true,
          latest_ts_unix: 1_000,
          latest_age_s: 1_030,
        },
      ],
    } satisfies TelemetrySummaryResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Partial telemetry')
    expect(container.textContent).toContain('OAS event relay trails agent events by 16m 40s.')
    expect(container.textContent).toContain('last 17m 10s ago')
  }, 60_000)

  it('refreshes automatically on a visible page', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue(executionResponse)
    const fetchToolQuality = vi.fn().mockResolvedValue(toolQualityResponse)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(telemetrySummaryResponse)
    const fetchDashboardNamespaceTruth = vi.fn().mockResolvedValue(namespaceTruthResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
      fetchDashboardNamespaceTruth,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)
    expect(fetchDashboardNamespaceTruth).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(2)
    expect(fetchToolQuality).toHaveBeenCalledTimes(2)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(2)
    expect(fetchDashboardNamespaceTruth).toHaveBeenCalledTimes(2)
    expect(container.textContent).toContain('30초 자동 갱신')
  }, 60_000)

  it('ignores out-of-order fleet telemetry refresh responses', async () => {
    let executionCall = 0
    let toolQualityCall = 0
    let summaryCall = 0
    let resolveExecutionSecond: ((value: DashboardExecutionResponse) => void) | null = null
    let resolveExecutionThird: ((value: DashboardExecutionResponse) => void) | null = null
    let resolveToolQualitySecond: ((value: ToolQualityResponse) => void) | null = null
    let resolveToolQualityThird: ((value: ToolQualityResponse) => void) | null = null
    let resolveSummarySecond: ((value: TelemetrySummaryResponse) => void) | null = null
    let resolveSummaryThird: ((value: TelemetrySummaryResponse) => void) | null = null
    let resolveNamespaceSecond: ((value: DashboardNamespaceTruthResponse) => void) | null = null
    let resolveNamespaceThird: ((value: DashboardNamespaceTruthResponse) => void) | null = null

    const fetchDashboardExecution = vi.fn().mockImplementation(() => {
      executionCall += 1
      if (executionCall === 1) return Promise.resolve(executionResponse)
      return new Promise<DashboardExecutionResponse>(resolve => {
        if (executionCall === 2) resolveExecutionSecond = resolve
        else resolveExecutionThird = resolve
      })
    })
    const fetchToolQuality = vi.fn().mockImplementation(() => {
      toolQualityCall += 1
      if (toolQualityCall === 1) return Promise.resolve(toolQualityResponse)
      return new Promise<ToolQualityResponse>(resolve => {
        if (toolQualityCall === 2) resolveToolQualitySecond = resolve
        else resolveToolQualityThird = resolve
      })
    })
    const fetchTelemetrySummary = vi.fn().mockImplementation(() => {
      summaryCall += 1
      if (summaryCall === 1) return Promise.resolve(telemetrySummaryResponse)
      return new Promise<TelemetrySummaryResponse>(resolve => {
        if (summaryCall === 2) resolveSummarySecond = resolve
        else resolveSummaryThird = resolve
      })
    })
    let namespaceCall = 0
    const fetchDashboardNamespaceTruth = vi.fn().mockImplementation(() => {
      namespaceCall += 1
      if (namespaceCall === 1) return Promise.resolve(namespaceTruthResponse)
      return new Promise<DashboardNamespaceTruthResponse>(resolve => {
        if (namespaceCall === 2) resolveNamespaceSecond = resolve
        else resolveNamespaceThird = resolve
      })
    })
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
      fetchDashboardNamespaceTruth,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('새로고침'))
    expect(refreshButton).toBeTruthy()

    await act(async () => {
      refreshButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      refreshButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })

    const applyExecutionThird = requireResolver(resolveExecutionThird, 'missing newest execution resolver')
    const applyToolQualityThird = requireResolver(resolveToolQualityThird, 'missing newest tool quality resolver')
    const applySummaryThird = requireResolver(resolveSummaryThird, 'missing newest summary resolver')
    const applyNamespaceThird = requireResolver(resolveNamespaceThird, 'missing newest namespace resolver')
    applyExecutionThird({
      ...executionResponse,
      keepers: [
        {
          ...executionResponse.keepers[0],
          name: 'keeper-gamma',
        },
      ],
    })
    applyToolQualityThird({
      ...toolQualityResponse,
      by_keeper: [
        {
          name: 'keeper-gamma',
          calls: 7,
          success_pct: 100,
        },
      ],
    })
    applySummaryThird({
      ...telemetrySummaryResponse,
      total_entries: 999,
    })
    applyNamespaceThird({
      ...namespaceTruthResponse,
      attention_events: [],
      readiness: {
        ...namespaceTruthResponse.readiness!,
        score: 0.9,
        status: 'ok',
      },
    })
    await flushUi()

    expect(container.textContent).toContain('keeper-gamma')
    expect(container.textContent).toContain('999')

    const applyExecutionSecond = requireResolver(resolveExecutionSecond, 'missing stale execution resolver')
    const applyToolQualitySecond = requireResolver(resolveToolQualitySecond, 'missing stale tool quality resolver')
    const applySummarySecond = requireResolver(resolveSummarySecond, 'missing stale summary resolver')
    const applyNamespaceSecond = requireResolver(resolveNamespaceSecond, 'missing stale namespace resolver')
    applyExecutionSecond({
      ...executionResponse,
      keepers: [
        {
          ...executionResponse.keepers[0],
          name: 'keeper-stale',
        },
      ],
    })
    applyToolQualitySecond({
      ...toolQualityResponse,
      by_keeper: [
        {
          name: 'keeper-stale',
          calls: 1,
          success_pct: 0,
        },
      ],
    })
    applySummarySecond({
      ...telemetrySummaryResponse,
      total_entries: 123,
    })
    applyNamespaceSecond(namespaceTruthResponse)
    await flushUi()

    expect(container.textContent).toContain('keeper-gamma')
    expect(container.textContent).not.toContain('keeper-stale')
  }, 60_000)

  it('aborts superseded fleet telemetry requests before a newer refresh settles', async () => {
    const abortedSignals: AbortSignal[] = []

    const createAbortableResponse = <T,>(value: T) => {
      let callCount = 0
      return vi.fn().mockImplementation((opts?: { signal?: AbortSignal }) => {
        callCount += 1
        if (callCount > 1) return Promise.resolve(value)
        return new Promise<T>((_resolve, reject) => {
          opts?.signal?.addEventListener('abort', () => {
            abortedSignals.push(opts.signal as AbortSignal)
            reject(new DOMException('superseded request', 'AbortError'))
          }, { once: true })
        })
      })
    }

    const fetchDashboardExecution = createAbortableResponse(executionResponse)
    const abortableToolQuality = createAbortableResponse(toolQualityResponse)
    const fetchToolQuality = vi.fn().mockImplementation((opts?: { n?: number; windowHours?: number; signal?: AbortSignal }) => (
      abortableToolQuality(opts)
    ))
    const fetchTelemetrySummary = createAbortableResponse(telemetrySummaryResponse)
    const fetchDashboardNamespaceTruth = createAbortableResponse(namespaceTruthResponse)
    const { FleetTelemetryPanel } = await loadPanel({
      fetchDashboardExecution,
      fetchToolQuality,
      fetchTelemetrySummary,
      fetchDashboardNamespaceTruth,
    })

    await act(async () => {
      render(html`<${FleetTelemetryPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(2)
    expect(fetchToolQuality).toHaveBeenCalledTimes(2)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(2)
    expect(fetchDashboardNamespaceTruth).toHaveBeenCalledTimes(2)
    expect(abortedSignals.length).toBeGreaterThan(0)
    expect(abortedSignals.every(signal => signal.aborted)).toBe(true)
    expect(container.textContent).toContain('keeper-alpha')
  }, 60_000)
})
