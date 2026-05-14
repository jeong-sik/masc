// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../api/dashboard'
import { hydrateOasRuntimeFromTelemetryEntries } from '../oas-runtime-store'
import { OasHealthChip } from './oas-health-chip'

function resetRuntimeState() {
  hydrateOasRuntimeFromTelemetryEntries([])
}

describe('OasHealthChip', () => {
  beforeEach(resetRuntimeState)

  afterEach(() => {
    cleanup()
    resetRuntimeState()
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
  })
})
