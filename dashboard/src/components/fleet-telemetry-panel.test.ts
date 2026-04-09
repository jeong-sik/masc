import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetrySummaryResponse, ToolQualityResponse } from '../api/dashboard'
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
  fetchDashboardExecution: () => Promise<DashboardExecutionResponse>
  fetchToolQuality: () => Promise<ToolQualityResponse>
  fetchTelemetrySummary: () => Promise<TelemetrySummaryResponse>
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
})
