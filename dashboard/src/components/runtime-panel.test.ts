import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const route = { value: { tab: 'monitoring' as string, params: {} as Record<string, string> } }

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadRuntimePanel() {
  vi.resetModules()
  vi.doMock('../router', () => ({ route, replaceRoute: vi.fn() }))
  vi.doMock('./oas-health-chip', () => ({
    OasHealthChip: () => html`<div data-testid="oas-health">OasHealthChip</div>`,
  }))
  vi.doMock('./runtime-monitor', () => ({
    RuntimeMonitor: () => html`<div data-testid="runtime-monitor">RuntimeMonitor</div>`,
  }))
  vi.doMock('./otel-metrics', () => ({
    OtelMetrics: () => html`<div data-testid="metrics">OtelMetrics</div>`,
  }))
  vi.doMock('./verification-specs-panel', () => ({
    VerificationSpecsPanel: () => html`<div data-testid="verification-specs">VerificationSpecsPanel</div>`,
  }))
  vi.doMock('./cost-dashboard', () => ({
    CostDashboard: ({ view }: { view?: string }) => html`<div data-testid="cost-dashboard" data-view=${view ?? 'cost'}>CostDashboard</div>`,
  }))
  vi.doMock('./common/filter-chips', () => ({
    FilterChips: ({ chips, value }: { chips: { key: string; label: string }[]; value: string }) => html`
      <div data-testid="filter-chips" data-value=${value}>
        ${chips.map((c: { key: string; label: string }) =>
          html`<span data-testid="chip" data-key=${c.key}>${c.label}</span>`,
        )}
      </div>
    `,
  }))
  vi.doMock('./common/route-link', () => ({
    RouteLink: ({ children, params }: { children?: unknown; params?: Record<string, string> }) => html`
      <a data-testid="route-link" data-section=${params?.section ?? ''}>${children}</a>
    `,
  }))
  return import('./runtime-panel')
}

describe('RuntimePanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'monitoring', params: {} }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../router')
    vi.doUnmock('./oas-health-chip')
    vi.doUnmock('./runtime-monitor')
    vi.doUnmock('./otel-metrics')
    vi.doUnmock('./verification-specs-panel')
    vi.doUnmock('./cost-dashboard')
    vi.doUnmock('./common/filter-chips')
    vi.doUnmock('./common/route-link')
  })

  it('renders runtime panels and diagnostics links by default', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    const routeLinks = Array.from(container.querySelectorAll('[data-testid="route-link"]'))
      .map(link => link.getAttribute('data-section'))
    expect(routeLinks).toEqual([
      'transport-health',
      'feature-health',
    ])
    expect(container.textContent).toContain('Diagnostics')
    expect(container.textContent).toContain('Transport diagnostics')
    expect(container.textContent).toContain('Feature cleanup')
    expect(container.textContent).toContain('RuntimeMonitor')
    expect(container.textContent).toContain('OtelMetrics')
    expect(container.textContent).toContain('VerificationSpecsPanel')
  })

  it('default view uses progressive disclosure: Signal open, Diagnostic/Raw in collapsed <details>', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const oas = container.querySelector('[data-testid="oas-health"]')
    expect(oas).not.toBeNull()
    expect(oas?.closest('details')).toBeNull()

    const detailIds = [
      'runtime-details-providers',
      'runtime-details-metrics',
      'runtime-details-verification',
    ]
    for (const id of detailIds) {
      const el = container.querySelector(`#${id}`)
      expect(el, `missing #${id}`).not.toBeNull()
      expect(el?.tagName.toLowerCase()).toBe('details')
      expect((el as HTMLDetailsElement).open).toBe(false)
    }
  })

  it('explicit drill-down views bypass progressive disclosure', async () => {
    route.value.params = { view: 'metrics' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const metrics = container.querySelector('[data-testid="metrics"]')
    expect(metrics).not.toBeNull()
    expect(metrics?.closest('details')).toBeNull()
  })

  it('renders only OasHealthChip and RuntimeMonitor for providers view', async () => {
    route.value.params = { view: 'providers' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeMonitor')
    expect(container.textContent).not.toContain('OtelMetrics')
  })

  it('renders only OtelMetrics for metrics view', async () => {
    route.value.params = { view: 'metrics' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('OasHealthChip')
    expect(container.textContent).not.toContain('RuntimeMonitor')
    expect(container.textContent).toContain('OtelMetrics')
  })

  it('renders FilterChips with runtime view options', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const chips = container.querySelectorAll('[data-testid="chip"]')
    // Chips are split across two FilterChips strips (Primary then Advanced)
    // with a divider between them. The positional order reflects the
    // Primary[default, providers] → Advanced[cost, audit, stress,
    // metrics, verification] layout.
    expect(chips.length).toBe(7)
    expect(chips[0]?.textContent).toBe('전체')
    expect(chips[1]?.textContent).toBe('런타임')
    expect(chips[2]?.textContent).toBe('비용 / 지연')
    expect(chips[3]?.textContent).toBe('감사')
    expect(chips[4]?.textContent).toBe('스트레스')
    expect(chips[5]?.textContent).toBe('메트릭')
    expect(chips[6]?.textContent).toBe('형식검증')
  })

  it('routes runtime diagnostic views through CostDashboard', async () => {
    route.value.params = { view: 'stress' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const costDashboard = container.querySelector('[data-testid="cost-dashboard"]')
    expect(costDashboard).not.toBeNull()
    expect(costDashboard?.getAttribute('data-view')).toBe('stress')
    expect(container.textContent).not.toContain('RuntimeMonitor')
  })

  it('falls back to default for unknown view param', async () => {
    route.value.params = { view: 'unknown-view' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeMonitor')
    expect(container.textContent).toContain('OtelMetrics')
  })

  it('passes current view value to FilterChips', async () => {
    route.value.params = { view: 'providers' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const filterChips = container.querySelector('[data-testid="filter-chips"]')
    expect(filterChips?.getAttribute('data-value')).toBe('providers')
  })
})
