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
  vi.doMock('./runtime-health-snapshot', () => ({
    RuntimeHealthSnapshot: () => html`<div data-testid="runtime-health-snapshot">RuntimeHealthSnapshot</div>`,
  }))
  vi.doMock('./runtime-toml-editor', () => ({
    RuntimeTomlEditor: () => html`<div data-testid="runtime-toml-editor">RuntimeTomlEditor</div>`,
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
    vi.doUnmock('./runtime-health-snapshot')
    vi.doUnmock('./runtime-toml-editor')
    vi.doUnmock('./verification-specs-panel')
    vi.doUnmock('./cost-dashboard')
    vi.doUnmock('./common/filter-chips')
    vi.doUnmock('./common/route-link')
  })

  it('renders first-screen runtime snapshot and diagnostics links by default', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeHealthSnapshot')
    expect(container.textContent?.indexOf('RuntimeHealthSnapshot')).toBeLessThan(
      container.textContent?.indexOf('OasHealthChip') ?? Number.POSITIVE_INFINITY,
    )
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

    // #20492 promoted "providers" from a collapsed details to its own
    // selectable view and made RuntimeMonitor a visible default lane, so only
    // verification remains as collapsed progressive-disclosure detail here.
    const detailIds = [
      'runtime-details-verification',
    ]
    for (const id of detailIds) {
      const el = container.querySelector(`#${id}`)
      expect(el, `missing #${id}`).not.toBeNull()
      expect(el?.tagName.toLowerCase()).toBe('details')
      expect((el as HTMLDetailsElement).open).toBe(false)
    }
    expect(container.textContent).toContain('RuntimeHealthSnapshot')
    expect(container.textContent).toContain('RuntimeMonitor')
  })

  it('explicit drill-down views bypass progressive disclosure', async () => {
    route.value.params = { view: 'verification' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const specs = container.querySelector('[data-testid="verification-specs"]')
    expect(specs).not.toBeNull()
    expect(specs?.closest('details')).toBeNull()
  })

  it('renders snapshot, OasHealthChip, and RuntimeMonitor for providers view', async () => {
    route.value.params = { view: 'providers' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('RuntimeHealthSnapshot')
    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeMonitor')
  })

  it('renders the raw runtime.toml editor for config view', async () => {
    route.value.params = { view: 'config' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('RuntimeTomlEditor')
    expect(container.textContent).not.toContain('RuntimeHealthSnapshot')
    expect(container.textContent).not.toContain('OasHealthChip')
    expect(container.textContent).not.toContain('RuntimeMonitor')
  })

  it('renders FilterChips with runtime view options', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const chips = container.querySelectorAll('[data-testid="chip"]')
    // Chips are split across two FilterChips strips (Primary then Advanced)
    // with a divider between them. The positional order reflects the
    // Primary[default, providers, runtime.toml] → Advanced[cost, audit,
    // verification] layout.
    expect(chips.length).toBe(6)
    expect(chips[0]?.textContent).toBe('전체')
    expect(chips[1]?.textContent).toBe('런타임')
    expect(chips[2]?.textContent).toBe('runtime.toml')
    expect(chips[3]?.textContent).toBe('비용 / 지연')
    expect(chips[4]?.textContent).toBe('감사')
    expect(chips[5]?.textContent).toBe('형식검증')
  })

  it('routes runtime diagnostic views through CostDashboard', async () => {
    route.value.params = { view: 'audit' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const costDashboard = container.querySelector('[data-testid="cost-dashboard"]')
    expect(costDashboard).not.toBeNull()
    expect(costDashboard?.getAttribute('data-view')).toBe('audit')
    expect(container.textContent).not.toContain('RuntimeMonitor')
  })

  it('falls back to default for unknown view param', async () => {
    route.value.params = { view: 'unknown-view' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('OasHealthChip')
    expect(container.textContent).toContain('RuntimeHealthSnapshot')
    expect(container.textContent).toContain('RuntimeMonitor')
  })

  it('passes current view value to FilterChips', async () => {
    route.value.params = { view: 'providers' }
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const filterChips = container.querySelector('[data-testid="filter-chips"]')
    expect(filterChips?.getAttribute('data-value')).toBe('providers')
  })

  it('wraps the panel in the v2 monitoring surface class', async () => {
    route.value.params = {}
    const { RuntimePanel } = await loadRuntimePanel()
    render(html`<${RuntimePanel} />`, container)
    await flushUi()

    const surface = container.querySelector('.v2-monitoring-surface')
    expect(surface).not.toBeNull()
  })
})
