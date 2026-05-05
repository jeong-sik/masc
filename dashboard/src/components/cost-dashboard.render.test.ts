// @vitest-environment happy-dom
import { h } from 'preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchRuntimeModelMetrics: vi.fn(),
  fetchKeeperCostMetrics: vi.fn(),
  fetchHeuristics: vi.fn(),
  fetchHeuristicCoverage: vi.fn(),
  fetchStress: vi.fn(),
  fetchAuditLedger: vi.fn(),
  fetchKeeperDecisions: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

function modelMetrics({
  models = [
    {
      model_id: 'glm-5-air',
      provider: 'zai',
      total_cost_usd: 0.12,
      total_input_tokens: 1200,
      total_output_tokens: 500,
      p50_latency_ms: 1200,
      p95_latency_ms: 3200,
    },
  ],
  latency_buckets = [
    { lo_ms: 0, hi_ms: 1000, count: 2 },
    { lo_ms: 1000, hi_ms: 4000, count: 3 },
  ],
} = {}) {
  return {
    window_minutes: 60,
    models,
    latency_buckets,
  }
}

function keeperMetrics() {
  return {
    window_minutes: 60,
    keepers: [
      {
        keeper_name: 'sangsu',
        total_cost_usd: 0.2,
        total_input_tokens: 2000,
        total_output_tokens: 700,
        total_tokens: 2700,
        p50_latency_ms: 900,
        p95_latency_ms: 2100,
        sample_count: 4,
        model_breakdown: [{ model: 'glm-5-air', cost_usd: 0.2 }],
      },
    ],
  }
}

async function waitFor(assertion: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 20; i += 1) {
    if (assertion()) return
    await new Promise(resolve => setTimeout(resolve, 0))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

describe('CostDashboard route-backed focus behavior', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.resetModules()
    apiMocks.fetchRuntimeModelMetrics.mockReset().mockResolvedValue(modelMetrics())
    apiMocks.fetchKeeperCostMetrics.mockReset().mockResolvedValue(keeperMetrics())
    apiMocks.fetchHeuristics.mockReset().mockResolvedValue({ events: [], limit: 0 })
    apiMocks.fetchHeuristicCoverage.mockReset().mockResolvedValue({ modules: [], sites: [] })
    apiMocks.fetchStress.mockReset().mockResolvedValue({ events: [], limit: 0 })
    apiMocks.fetchAuditLedger.mockReset().mockResolvedValue({ entries: [], limit: 0 })
    apiMocks.fetchKeeperDecisions.mockReset().mockResolvedValue({ events: [], limit: 0 })
    window.history.replaceState(null, '', '#overview')
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('keeps an existing model focus when the active model radio is clicked', async () => {
    const { route } = await import('../router')
    const { CostDashboard } = await import('./cost-dashboard')
    route.value = {
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost', focus: 'matrix' },
      postId: null,
    }

    render(h(CostDashboard, { view: 'cost' }), container)
    await waitFor(() => container.textContent?.includes('glm-5-air') ?? false, 'model metrics')

    const modelButton = Array.from(container.querySelectorAll('button[role="radio"]'))
      .find(button => button.textContent?.trim() === '모델') as HTMLButtonElement | undefined
    expect(modelButton?.getAttribute('aria-checked')).toBe('true')

    modelButton?.click()
    expect(route.value.params.focus).toBe('matrix')
  })

  it('leaves every focus chip unselected in the unfocused model overview', async () => {
    const { route } = await import('../router')
    const { CostDashboard } = await import('./cost-dashboard')
    route.value = {
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost' },
      postId: null,
    }

    render(h(CostDashboard, { view: 'cost' }), container)
    await waitFor(() => container.textContent?.includes('glm-5-air') ?? false, 'model overview metrics')

    const tabs = Array.from(
      container.querySelectorAll('[data-testid="cost-focus-rail"] [role="tab"]'),
    )
    expect(tabs).toHaveLength(3)
    expect(tabs.map(tab => tab.getAttribute('aria-selected'))).toEqual(['false', 'false', 'false'])
  })

  it('shows focused latency empty copy when the route has no latency buckets', async () => {
    apiMocks.fetchRuntimeModelMetrics.mockResolvedValueOnce(modelMetrics({
      models: [],
      latency_buckets: [],
    }))
    const { route } = await import('../router')
    const { CostDashboard } = await import('./cost-dashboard')
    route.value = {
      tab: 'monitoring',
      params: { section: 'runtime', view: 'cost', focus: 'latency' },
      postId: null,
    }

    render(h(CostDashboard, { view: 'cost' }), container)
    await waitFor(
      () => container.textContent?.includes('이 시간 창에서 기록된 모델 지연 분포가 없습니다.') ?? false,
      'focused latency empty state',
    )

    expect(container.querySelector('[aria-label^="Latency histogram"]')).toBeNull()
  })
})
