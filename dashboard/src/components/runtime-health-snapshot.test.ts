// @vitest-environment happy-dom
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardRuntimeProbe: vi.fn(),
  fetchRuntimeProviders: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

async function waitFor(assertion: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 30; i += 1) {
    if (assertion()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

function providerPayload(overrides: Record<string, unknown> = {}) {
  return {
    updated_at: '2026-06-06T07:24:08Z',
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
        model_api_name: 'Qwen/Qwen3-32B',
        transport: 'http',
        runtime_kind: 'http',
        status: 'configured',
        available: true,
        is_default_runtime: true,
        models: ['Qwen/Qwen3-32B'],
        endpoint_url: 'https://runpod.example/v1',
        ...overrides,
      },
    ],
  }
}

function probePayload(overrides: Record<string, unknown> = {}) {
  return {
    generated_at: '2026-06-06T07:24:08Z',
    cache_hit: false,
    probe: {
      source: 'runtime.toml',
      status: 'reachable',
      checked_at: '2026-06-06T07:24:08Z',
      probe_ok: true,
      server_url: 'https://runpod.example/v1',
      ps_endpoint: 'https://runpod.example/v1/models',
      generate_endpoint: 'https://runpod.example/v1/chat/completions',
      summary: {
        runtimes: 1,
        probed: 1,
        reachable: 1,
        failed: 0,
        skipped: 0,
        default_runtime_id: 'runpod_mtp.qwen',
      },
      providers: [
        {
          runtime_id: 'runpod_mtp.qwen',
          provider_id: 'runpod_mtp',
          model_api_name: 'Qwen/Qwen3-32B',
          status: 'reachable',
          reachable: true,
          http_status: 200,
          latency_ms: 42,
          credential_required: true,
          auth_present: true,
          probe_url: 'https://runpod.example/v1/models',
        },
      ],
      ...overrides,
    },
  }
}

describe('RuntimeHealthSnapshot', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.resetModules()
    apiMocks.fetchRuntimeProviders.mockReset().mockResolvedValue(providerPayload())
    apiMocks.fetchDashboardRuntimeProbe.mockReset().mockResolvedValue(probePayload())
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('surfaces live reachability, default runtime, and probe endpoints on the first screen', async () => {
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('runpod_mtp.qwen') ?? false,
      'default runtime',
    )

    expect(container.textContent).toContain('런타임 상태 체크')
    expect(container.textContent).toContain('1 reachable')
    expect(container.textContent).toContain('default runtime')
    expect(container.textContent).toContain('ready')
    expect(container.textContent).toContain('https://runpod.example/v1')
    expect(container.textContent).toContain('provider details')
    expect(container.textContent).toContain('runtime.toml')
    expect(container.textContent).toContain('transport health')
    const endpointCards = container.querySelectorAll('[data-testid="runtime-health-endpoints"] .v2-monitoring-card')
    expect(endpointCards.length).toBeGreaterThan(0)
  })

  it('does not hide failed live probe details behind the full runtime monitor', async () => {
    apiMocks.fetchDashboardRuntimeProbe.mockResolvedValueOnce(probePayload({
      status: 'network_error',
      probe_ok: false,
      summary: {
        runtimes: 1,
        probed: 1,
        reachable: 0,
        failed: 1,
        skipped: 0,
        default_runtime_id: 'runpod_mtp.qwen',
      },
      providers: [
        {
          runtime_id: 'runpod_mtp.qwen',
          provider_id: 'runpod_mtp',
          status: 'network_error',
          reachable: false,
          credential_required: true,
          auth_present: true,
          error: 'connect ECONNREFUSED 127.0.0.1:3000',
          probe_url: 'https://runpod.example/v1/models',
        },
      ],
    }))
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('1 failing') ?? false,
      'failed probe summary',
    )

    expect(container.textContent).toContain('needs attention')
    expect(container.textContent).toContain('network_error')
    expect(container.textContent).toContain('connect ECONNREFUSED 127.0.0.1:3000')
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('runpod_mtp.qwen')
  })

  it('keeps provider config visible when the live probe request itself fails', async () => {
    apiMocks.fetchDashboardRuntimeProbe.mockRejectedValueOnce(new Error('500 Internal Server Error: Eio mutex poisoned'))
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('live probe request failed') ?? false,
      'probe request failure',
    )

    expect(container.textContent).toContain('runpod_mtp.qwen')
    expect(container.textContent).toContain('needs attention')
    expect(container.textContent).toContain('500 Internal Server Error: Eio mutex poisoned')
  })

  it('surfaces runtime assignment governance warnings on the first screen', async () => {
    apiMocks.fetchRuntimeProviders.mockResolvedValueOnce({
      ...providerPayload(),
      assignment_governance: {
        schema: 'masc.runtime_assignment_governance.v1',
        source: 'runtime.toml',
        status: 'degraded',
        degraded: true,
        operator_action_required: true,
        blast_radius: 'single_runtime_assignment_pin',
        assignment_count: 2,
        assigned_keeper_count: 2,
        assigned_runtime_count: 1,
        default_assignment_count: 0,
        default_runtime_id: 'runpod_mtp.qwen',
        librarian_runtime_id: null,
        warnings: ['explicit_assignments_present', 'single_runtime_assignment_pin'],
        assigned_runtimes: ['openai.gpt'],
        assignments: [
          { keeper: 'budgettest', runtime_id: 'openai.gpt', matches_default: false },
          { keeper: 'routingtest', runtime_id: 'openai.gpt', matches_default: false },
        ],
      },
    })
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => container.textContent?.includes('runtime assignment governance') ?? false,
      'assignment governance warning',
    )

    expect(container.textContent).toContain('runtime assignment review')
    expect(container.textContent).toContain('2 explicit')
    expect(container.textContent).toContain('assigned runtimes: openai.gpt')
    expect(container.textContent).toContain('single_runtime_assignment_pin')
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('runtime assignment governance')
  })

  it('uses force=1 when the operator clicks Live probe', async () => {
    const { RuntimeHealthSnapshot } = await import('./runtime-health-snapshot')

    render(h(RuntimeHealthSnapshot, {}), container)
    await waitFor(
      () => apiMocks.fetchDashboardRuntimeProbe.mock.calls[0]?.[0] === false,
      'initial unforced probe',
    )

    container.querySelector('button')?.click()
    await waitFor(
      () => apiMocks.fetchDashboardRuntimeProbe.mock.calls.length >= 2,
      'forced refresh',
    )

    expect(apiMocks.fetchDashboardRuntimeProbe.mock.calls[0]?.[0]).toBe(false)
    expect(apiMocks.fetchDashboardRuntimeProbe.mock.calls.at(-1)?.[0]).toBe(true)
  })
})
