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
        runtimes: 1,
        local_models: 0,
        cloud_models: 1,
        cli_models: 0,
        default_runtime_id: 'runpod_mtp.qwen',
      },
      providers: [
        {
          provider: 'runpod_mtp.qwen',
          runtime_id: 'runpod_mtp.qwen',
          provider_id: 'runpod_mtp',
          provider_display_name: 'RunPod MTP',
          model_id: 'qwen',
          model_api_name: 'Qwen/Qwen3-32B',
          protocol: 'provider_d-http',
          transport: 'http',
          kind: 'cloud',
          runtime_kind: 'http',
          auth_kind: 'env:RUNPOD_API_KEY',
          status: 'configured',
          available: true,
          is_default_runtime: true,
          max_context: 200000,
          tools_support: true,
          streaming: true,
          model_count: 1,
          models: ['Qwen/Qwen3-32B'],
          source: 'runtime.toml',
          endpoint_url: 'https://example.invalid/v1',
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

  it('shows runtime.toml binding identity on provider status cards', async () => {
    const { RuntimeMonitor } = await import('./runtime-monitor')

    render(h(RuntimeMonitor, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'runtime binding',
    )

    expect(container.textContent).toContain('runpod_mtp.qwen')
    expect(container.textContent).toContain('runpod_mtp')
    expect(container.textContent).toContain('Qwen/Qwen3-32B')
  })
})
