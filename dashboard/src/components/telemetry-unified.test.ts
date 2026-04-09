import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetryResponse, TelemetrySummaryResponse } from '../api/dashboard'

void vi

const baseTelemetry: TelemetryResponse = {
  generated_at: '2026-04-09T05:10:00Z',
  count: 1,
  entries: [
    {
      source: 'tool_metric',
      ts: 1_775_709_000,
      tool_name: 'mcp__masc__masc_status',
      duration_ms: 42,
      success: true,
    },
  ],
}

const baseSummary: TelemetrySummaryResponse = {
  generated_at: '2026-04-09T05:10:00Z',
  sources: [
    {
      source: 'tool_metric',
      entry_count: 1,
      keeper_count: 1,
      exists: true,
    },
  ],
  total_entries: 1,
}

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

async function loadPanel(
  fetchTelemetry: () => Promise<TelemetryResponse>,
  fetchTelemetrySummary: () => Promise<TelemetrySummaryResponse>,
) {
  vi.resetModules()
  vi.doMock('../api/dashboard', () => ({
    fetchTelemetry,
    fetchTelemetrySummary,
    fetchDashboardShell: vi.fn().mockResolvedValue({ counts: { keepers: 2, agents: 0, tasks: 5 }, status: { version: '0.2.0', build: { uptime_seconds: 600 } } }),
    fetchDashboardTools: vi.fn().mockResolvedValue({ tool_inventory: { count: 10, tools: [], surface_summary: { public_mcp: { count: 5, tools: [] } } }, tool_usage: { total_calls: 100, never_called_count: 0 } }),
    fetchDashboardNamespaceTruth: vi.fn().mockResolvedValue({ execution: { summary: { active_sessions: 1, active_operations: 3, continuity_alerts: 0 } } }),
  }))
  return import('./telemetry-unified')
}

describe('TelemetryUnified', () => {
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

  it('does not poll automatically after the initial load', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(15_000)
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)
    expect(fetchTelemetrySummary).toHaveBeenCalledTimes(1)
  })

  it('renders runtime diagnosis metadata for operators', async () => {
    const fetchTelemetry = vi.fn().mockResolvedValue(baseTelemetry)
    const fetchTelemetrySummary = vi.fn().mockResolvedValue(baseSummary)
    const { TelemetryUnified } = await loadPanel(fetchTelemetry, fetchTelemetrySummary)

    await act(async () => {
      render(html`<${TelemetryUnified} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Runtime Diagnosis')
    expect(container.textContent).toContain('MASC telemetry store')
    expect(container.textContent).toContain('Refresh')
    expect(container.textContent).toContain('MASC telemetry store entries')
    expect(container.textContent).toContain('mcp__masc__masc_status')

    // MASC Store Diagnosis cards
    expect(container.textContent).toContain('Keeper Store')
    expect(container.textContent).toContain('Tool Store')
    expect(container.textContent).toContain('Agent Store')
    expect(container.textContent).toContain('1 활성 세션')
    expect(container.textContent).toContain('5 public')
  })
})
