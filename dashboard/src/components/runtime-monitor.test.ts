// @vitest-environment happy-dom
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchRuntimeProviders: vi.fn(),
  fetchRuntimeModelMetrics: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

async function waitFor(assertion: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 20; i += 1) {
    if (assertion()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

describe('RuntimeMonitor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.resetModules()
    apiMocks.fetchRuntimeProviders.mockReset().mockResolvedValue({
      updated_at: '2026-05-13T13:00:00Z',
      summary: {
        providers: 1,
        local_models: 0,
        cloud_models: 1,
        cli_models: 0,
      },
      providers: [
        {
          provider: 'runtime_lane_deadbeef1234',
          kind: 'runtime',
          runtime_kind: 'cloud',
          auth_kind: null,
          status: 'available',
          available: true,
          supports_single_agent_run: true,
          default_model: null,
          model_count: 1,
          models: [],
          source: 'runtime',
          endpoint_url: null,
          note: null,
          discovery: {
            healthy: true,
            ctx_size: 200000,
            total_slots: 4,
            busy_slots: 1,
            idle_slots: 3,
          },
        },
      ],
    })
    apiMocks.fetchRuntimeModelMetrics.mockReset().mockResolvedValue({
      window_minutes: 30,
      bucket_minutes: 5,
      total_entries: 0,
      total_error_entries: 0,
      latency_buckets: [],
      models: [],
    })
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('shows the stable API runtime lane on provider status cards', async () => {
    const { RuntimeMonitor } = await import('./runtime-monitor')

    render(h(RuntimeMonitor, {}), container)
    await waitFor(
      () => container.textContent?.includes('runtime_lane_deadbeef1234') ?? false,
      'runtime provider lane',
    )

    expect(container.textContent).toContain('runtime_lane_deadbeef1234')
    expect(container.textContent).not.toContain('runtime 1')
  })
})
