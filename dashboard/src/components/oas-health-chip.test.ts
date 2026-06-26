// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TelemetryEntry } from '../api/dashboard'
import { hydrateOasRuntimeFromTelemetryEntries } from '../oas-runtime-store'
import { OasHealthChip } from './oas-health-chip'

const fetchTelemetryMock = vi.hoisted(() => vi.fn())

vi.mock('../api/dashboard', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/dashboard')>()
  return {
    ...actual,
    fetchTelemetry: fetchTelemetryMock,
  }
})

function resetRuntimeState() {
  hydrateOasRuntimeFromTelemetryEntries([])
}

describe('OasHealthChip', () => {
  beforeEach(() => {
    fetchTelemetryMock.mockReset()
    resetRuntimeState()
  })

  afterEach(() => {
    cleanup()
    resetRuntimeState()
    vi.restoreAllMocks()
  })

  it('renders OAS runtime evidence refs in the health summary', () => {
    hydrateOasRuntimeFromTelemetryEntries([
      {
        source: 'oas_event',
        type: 'oas:runtime.artifact_attached',
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
        source: 'oas_event',
        type: 'oas:runtime.session_completed',
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

    const { container } = render(html`<${OasHealthChip} />`)

    expect(container.textContent).toContain('OAS 런타임')
    expect(container.textContent).toContain('증거 참조')
    expect(container.textContent).toContain('trace')
    expect(container.textContent).toContain('report')
    expect(container.textContent).toContain('proof')
    expect(fetchTelemetryMock).not.toHaveBeenCalled()
  })

  it('starts durable OAS replay when mounted without an existing replay window', async () => {
    fetchTelemetryMock.mockResolvedValue({
      generated_at: '2026-04-15T12:00:00Z',
      count: 0,
      total_matching_entries: 0,
      truncated: false,
      entries: [],
    })

    render(html`<${OasHealthChip} />`)

    await waitFor(() => {
      expect(fetchTelemetryMock).toHaveBeenCalledWith({
        source: 'oas_event',
        n: 500,
        signal: undefined,
      })
    })
  })

  it('surfaces durable replay failures in the chip', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    fetchTelemetryMock.mockRejectedValue(new Error('journal unavailable'))

    const { container } = render(html`<${OasHealthChip} />`)

    await waitFor(() => {
      expect(container.textContent).toContain('OAS 리플레이를 불러오지 못했습니다')
      expect(container.textContent).toContain('journal unavailable')
    })
  })
})
