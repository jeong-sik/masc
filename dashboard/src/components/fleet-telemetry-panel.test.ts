import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetrySummaryResponse, ToolQualityResponse } from '../api/dashboard'
import { normalizeKeepers } from '../keeper-store-normalize'
import type { DashboardExecutionResponse } from '../types'

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
  fetchToolQuality: (opts?: { n?: number; signal?: AbortSignal }) => Promise<ToolQualityResponse>
  fetchTelemetrySummary: (opts?: { signal?: AbortSignal }) => Promise<TelemetrySummaryResponse>
}) {
  vi.resetModules()
  vi.doMock('../api/dashboard', () => ({
    fetchDashboardExecution: mocks.fetchDashboardExecution,
    fetchToolQuality: mocks.fetchToolQuality,
    fetchTelemetrySummary: mocks.fetchTelemetrySummary,
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

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('Fleet Coverage')
    expect(container.textContent).toContain('1/2 keepers emitted recent tool telemetry.')
    expect(container.textContent).toContain('keeper-alpha')
    expect(container.textContent).toContain('keeper-beta')
    expect(container.textContent).toContain('Keeper 턴 로그')
    expect(container.textContent).toContain('Failure Categories')
  })

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
  })

  it('refreshes automatically on a visible page', async () => {
    const fetchDashboardExecution = vi.fn().mockResolvedValue(executionResponse)
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

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(2)
    expect(fetchToolQuality).toHaveBeenCalledTimes(2)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(2)
    expect(container.textContent).toContain('30초 자동 갱신')
  })

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
    await flushUi()

    expect(container.textContent).toContain('keeper-gamma')
    expect(container.textContent).toContain('999')

    const applyExecutionSecond = requireResolver(resolveExecutionSecond, 'missing stale execution resolver')
    const applyToolQualitySecond = requireResolver(resolveToolQualitySecond, 'missing stale tool quality resolver')
    const applySummarySecond = requireResolver(resolveSummarySecond, 'missing stale summary resolver')
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
    await flushUi()

    expect(container.textContent).toContain('keeper-gamma')
    expect(container.textContent).not.toContain('keeper-stale')
  })

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
    const fetchToolQuality = vi.fn().mockImplementation((opts?: { n?: number; signal?: AbortSignal }) => (
      abortableToolQuality(opts)
    ))
    const fetchTelemetrySummary = createAbortableResponse(telemetrySummaryResponse)
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

    await vi.advanceTimersByTimeAsync(30_000)
    await flushUi()

    expect(fetchDashboardExecution).toHaveBeenCalledTimes(2)
    expect(fetchToolQuality).toHaveBeenCalledTimes(2)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(2)
    expect(abortedSignals.length).toBeGreaterThan(0)
    expect(abortedSignals.every(signal => signal.aborted)).toBe(true)
    expect(container.textContent).toContain('keeper-alpha')
  })
})
