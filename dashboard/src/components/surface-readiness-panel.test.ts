import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { SurfaceReadinessData, SurfaceReadinessEntry } from './surface-readiness-panel'

const payload: SurfaceReadinessData = {
  generated_at: '2026-05-14T00:00:00Z',
  proof_bar: 'live:3/3 logs:2/3 metrics:3/3',
  surfaces: [
    {
      id: 'command.operations',
      label: 'Operations',
      exposure_status: 'main',
      hidden_from_nav: false,
      meets_main_gate: true,
      proof_bar: 'fixture+live_spotcheck+logs+metrics+tool',
      rationale: 'Canonical command surface.',
      route_hash: '#command?section=operations',
      verification_refs: [
        { kind: 'script', label: 'live_spotcheck', value: './scripts/harness_dashboard_execution_smoke.sh' },
        { kind: 'route', label: 'logs', value: '/api/v1/dashboard/logs' },
        { kind: 'route', label: 'metrics', value: '/metrics' },
        { kind: 'tool', label: 'tool_name', value: 'masc_operator_digest' },
      ],
    },
    {
      id: 'lab.harness',
      label: 'Harness',
      exposure_status: 'lab',
      hidden_from_nav: false,
      meets_main_gate: false,
      proof_bar: 'live_spotcheck+logs+metrics',
      rationale: 'Lab safety harness surface.',
      route_hash: '#lab?section=harness',
      verification_refs: [
        { kind: 'route', label: 'live_spotcheck', value: '/api/v1/dashboard/harness-health' },
        { kind: 'route', label: 'logs', value: '/api/v1/dashboard/logs' },
        { kind: 'route', label: 'metrics', value: '/metrics' },
      ],
    },
    {
      id: 'workspace.gap',
      label: 'Gap Surface',
      exposure_status: 'main',
      hidden_from_nav: false,
      meets_main_gate: true,
      proof_bar: 'live_spotcheck+metrics',
      rationale: 'Intentionally missing logs for regression coverage.',
      route_hash: '#workspace?section=gap',
      verification_refs: [
        { kind: 'route', label: 'live_spotcheck', value: '/api/v1/dashboard/gap' },
        { kind: 'route', label: 'metrics', value: '/metrics' },
      ],
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

async function loadPanel(getMock = vi.fn().mockResolvedValue(payload)) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({
    get: getMock,
  }))
  return {
    getMock,
    module: await import('./surface-readiness-panel'),
  }
}

describe('SurfaceReadinessPanel', () => {
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
    vi.doUnmock('../api/core')
  })

  it('loads and renders dashboard surface verification refs', async () => {
    const { getMock, module } = await loadPanel()
    const { SurfaceReadinessPanel } = module

    await act(async () => {
      render(html`<${SurfaceReadinessPanel} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(getMock).toHaveBeenCalledWith('/api/v1/dashboard/surface-readiness')
    expect(container.textContent).toContain('Surface Readiness')
    expect(container.textContent).toContain('2 main / 3 total')
    expect(container.textContent).toContain('live:3/3 logs:2/3 metrics:3/3')
    expect(container.textContent).toContain('command.operations')
    expect(container.textContent).toContain('#command?section=operations')
    expect(container.textContent).toContain('live_spotcheck')
    expect(container.textContent).toContain('/api/v1/dashboard/logs')
    expect(container.textContent).toContain('missing logs')
  })

  it('filters gap surfaces by missing proof refs', async () => {
    const { module } = await loadPanel()
    const { filterSurfaceReadiness } = module

    const filtered = filterSurfaceReadiness(payload.surfaces, 'gaps')

    expect(filtered.map(surface => surface.id)).toEqual(['workspace.gap'])
  })

  it('summarizes main, lab, hidden, and gap counts', async () => {
    const { module } = await loadPanel()
    const { summarizeSurfaceReadiness } = module
    const diagnosticHidden: SurfaceReadinessEntry = {
      ...payload.surfaces[0]!,
      id: 'monitoring.hidden',
      exposure_status: 'diagnostic',
      hidden_from_nav: true,
      meets_main_gate: false,
    }

    expect(summarizeSurfaceReadiness([...payload.surfaces, diagnosticHidden])).toMatchObject({
      total: 4,
      main: 2,
      lab: 1,
      diagnostic: 1,
      hidden: 1,
      gaps: 1,
    })
  })
})
