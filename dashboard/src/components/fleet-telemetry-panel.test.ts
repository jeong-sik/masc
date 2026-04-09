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

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
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
    expect(container.textContent).toContain('Keeper metrics')
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
})
