// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetryEntry } from '../api/dashboard'
import { hydrateAgentCoreRuntimeFromTelemetryEntries } from '../agent-core-runtime-store'
import { noteAgentCoreReplayWindow } from '../store'
import { AgentCoreHealthChip } from './agent-core-health-chip'

const fetchTelemetryMock = vi.hoisted(() => vi.fn())

vi.mock('../api/dashboard', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/dashboard')>()
  return {
    ...actual,
    fetchTelemetry: fetchTelemetryMock,
  }
})

function resetRuntimeState() {
  hydrateAgentCoreRuntimeFromTelemetryEntries([])
}

describe('AgentCoreHealthChip', () => {
  beforeEach(() => {
    fetchTelemetryMock.mockReset()
    resetRuntimeState()
  })

  afterEach(() => {
    cleanup()
    resetRuntimeState()
    vi.restoreAllMocks()
  })

  it('renders Agent Core runtime evidence refs in the health summary', () => {
    hydrateAgentCoreRuntimeFromTelemetryEntries([
      {
        source: 'agent_core_event',
        type: 'agent_core:runtime.artifact_attached',
        event_type: 'runtime.artifact_attached',
        ts_unix: 500,
        correlation_id: 'sess-evidence',
        run_id: 'run-evidence',
        payload: {
          kind: [
            'Artifact_attached',
            {
              artifact_id: 'art-raw',
              name: 'runtime-raw-trace-json',
              path: '/tmp/runtime-raw-trace-json.json',
            },
          ],
        },
      },
      {
        source: 'agent_core_event',
        type: 'agent_core:runtime.session_completed',
        event_type: 'runtime.session_completed',
        ts_unix: 510,
        correlation_id: 'sess-evidence',
        run_id: 'run-evidence',
        payload: {
          evidence: {
            files: [
              { label: 'report_json', path: '/tmp/report.json' },
              { label: 'proof_json', path: '/tmp/proof.json' },
              { label: 'telemetry_json', path: '/tmp/runtime-telemetry-json.json' },
            ],
          },
        },
      },
    ] as TelemetryEntry[])

    const { container } = render(html`<${AgentCoreHealthChip} />`)

    expect(container.textContent).toContain('Agent Core 런타임')
    expect(container.textContent).toContain('증거 참조')
    expect(container.textContent).toContain('trace')
    expect(container.textContent).toContain('report')
    expect(container.textContent).toContain('proof')
    expect(fetchTelemetryMock).not.toHaveBeenCalled()
  })

  it('starts durable Agent Core replay when mounted without an existing replay window', async () => {
    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 0,
      offset: 0,
      total_matching_entries: 0,
      truncated: false,
      entries: [],
    })

    render(html`<${AgentCoreHealthChip} />`)

    await waitFor(() => {
      expect(fetchTelemetryMock).toHaveBeenCalledWith({
        source: 'agent_core_event',
        n: 500,
        signal: undefined,
      })
    })
  })

  it('surfaces durable replay failures in the chip', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    fetchTelemetryMock.mockRejectedValue(new Error('journal unavailable'))

    const { container } = render(html`<${AgentCoreHealthChip} />`)

    await waitFor(() => {
      expect(container.textContent).toContain('Agent Core 리플레이를 불러오지 못했습니다')
      expect(container.textContent).toContain('journal unavailable')
    })
  })

  it('shows the server replay cap without offering another duplicate page', () => {
    hydrateAgentCoreRuntimeFromTelemetryEntries([{
      source: 'agent_core_event',
      type: 'agent_core:masc:keeper:lifecycle',
      event_id: 'visible-capped-window',
      payload: { agent_name: 'a', detail: 'b', event: 'started' },
    }] as TelemetryEntry[])
    noteAgentCoreReplayWindow({
      loadedEvents: 1,
      totalMatchingEvents: 6000,
      truncated: false,
      capped: true,
    })

    const { container } = render(html`<${AgentCoreHealthChip} />`)

    expect(container.textContent).toContain('서버 조회 한도')
    expect(container.textContent).not.toContain('더 보기')
  })
})
