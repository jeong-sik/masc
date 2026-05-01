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
  vi.doMock('./prometheus-metrics', () => ({
    PrometheusMetrics: () => html`<div data-testid="prometheus">PrometheusMetrics</div>`,
  }))
  vi.doMock('./cascade-config-panel', () => ({
    CascadeConfigPanel: () => html`<div data-testid="cascade-config">CascadeConfigPanel</div>`,
  }))
  vi.doMock('./verification-specs-panel', () => ({
    VerificationSpecsPanel: () => html`<div data-testid="verification-specs">VerificationSpecsPanel</div>`,
  }))
  vi.doMock('./cost-dashboard', () => ({
    CostDashboard: () => html`<div data-testid="cost-dashboard">CostDashboard</div>`,
  }))
  vi.doMock('./cascade-inspector', () => ({
    CascadeInspector: () => html`<div data-testid="cascade-inspector">CascadeInspector</div>`,
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
    vi.doUnmock('./prometheus-metrics')
    vi.doUnmock('./cascade-config-panel')
    vi.doUnmock('./verification-specs-panel')
    vi.doUnmock('./cost-dashboard')
    vi.doUnmock('./cascade-inspector')
    vi.doUnmock('./common/filter-chips')
  })

  it('renders all 5 panels by default (Signal + collapsed Diagnostic/Raw)', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('CascadeConfigPanel')
    expect(container.textContent).toContain('RuntimeMonitor')
    expect(container.textContent).toContain('PrometheusMetrics')
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
      'runtime-details-cascade',
      'runtime-details-providers',
      'runtime-details-prometheus',
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
    route.value.params = { view: 'cascade' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const cascade = container.querySelector('[data-testid="cascade-config"]')
    expect(cascade).not.toBeNull()
    expect(cascade?.closest('details')).toBeNull()
  })

  it('renders only OasHealthChip and RuntimeMonitor for providers view', async () => {
    route.value.params = { view: 'providers' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeMonitor')
    expect(container.textContent).not.toContain('PrometheusMetrics')
  })

  it('renders only PrometheusMetrics for prometheus view', async () => {
    route.value.params = { view: 'prometheus' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('OasHealthChip')
    expect(container.textContent).not.toContain('RuntimeMonitor')
    expect(container.textContent).toContain('PrometheusMetrics')
  })

  it('renders FilterChips with runtime view options', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const chips = container.querySelectorAll('[data-testid="chip"]')
    expect(chips.length).toBe(7)
    expect(chips[0]?.textContent).toBe('전체')
    expect(chips[1]?.textContent).toBe('Cascade')
    expect(chips[2]?.textContent).toBe('프로바이더')
    expect(chips[3]?.textContent).toBe('비용 / 지연')
    expect(chips[4]?.textContent).toBe('검사기')
    expect(chips[5]?.textContent).toBe('메트릭')
    expect(chips[6]?.textContent).toBe('형식검증')
  })

  it('falls back to default for unknown view param', async () => {
    route.value.params = { view: 'unknown-view' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeMonitor')
    expect(container.textContent).toContain('PrometheusMetrics')
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
