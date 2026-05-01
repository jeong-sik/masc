import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const route = { value: { tab: 'command' as string, params: {} as Record<string, string> } }

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadPanel() {
  vi.resetModules()
  vi.doMock('../router', () => ({ route, replaceRoute: vi.fn() }))
  vi.doMock('./ops', () => ({
    Ops: () => html`<div data-testid="ops">Ops</div>`,
  }))
  vi.doMock('./governance', () => ({
    Governance: () => html`<div data-testid="governance">Governance</div>`,
  }))
  vi.doMock('./connector-status', () => ({
    ConnectorStatusPanel: () => html`<div data-testid="connectors">Connectors</div>`,
  }))
  vi.doMock('./lab-inspector', () => ({
    LabInspector: () => html`<div data-testid="inspector">Inspector</div>`,
  }))
  vi.doMock('./safe-autonomy', () => ({
    SafeAutonomyPanel: () => html`<div data-testid="safety">Safety</div>`,
  }))
  return import('./operations-panel')
}

describe('OperationsPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'command', params: { section: 'operations' } }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../router')
    vi.doUnmock('./ops')
    vi.doUnmock('./governance')
    vi.doUnmock('./connector-status')
    vi.doUnmock('./lab-inspector')
    vi.doUnmock('./safe-autonomy')
  })

  it('renders Ops, Governance, and Safety when view is not set (default)', async () => {
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).toContain('Governance')
    expect(container.textContent).toContain('Safety')
  })

  it('renders only Ops when view is ops', async () => {
    route.value.params = { section: 'operations', view: 'ops' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="ops"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="governance"]')).toBeNull()
    expect(container.querySelector('[data-testid="safety"]')).toBeNull()
  })

  it('renders only Governance when view is governance', async () => {
    route.value.params = { section: 'operations', view: 'governance' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('Ops')
    expect(container.textContent).toContain('Governance')
    expect(container.querySelector('[data-testid="safety"]')).toBeNull()
  })

  it('renders FilterChips options without legacy connectors view', async () => {
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    const tablist = container.querySelector('[role="tablist"]')
    const buttons = tablist?.querySelectorAll('[role="tab"]') ?? []
    expect(buttons.length).toBe(5)
    const labels = Array.from(buttons).map(b => b.textContent?.trim())
    expect(labels).toContain('All')
    expect(labels).toContain('Intervene')
    expect(labels).toContain('Governance')
    expect(labels).toContain('Safety')
    expect(labels).toContain('Inspector')
    expect(labels).not.toContain('Connectors')
  })

  it('falls back to default for unknown view param', async () => {
    route.value.params = { section: 'operations', view: 'unknown' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).toContain('Governance')
    expect(container.querySelector('[data-testid="safety"]')).not.toBeNull()
  })

  it('marks the active chip with aria-selected=true', async () => {
    route.value.params = { section: 'operations', view: 'governance' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    const buttons = container.querySelectorAll('button[type="button"]')
    const governanceBtn = Array.from(buttons).find(b => b.textContent?.trim() === 'Governance')
    expect(governanceBtn?.getAttribute('aria-selected')).toBe('true')

    const defaultBtn = Array.from(buttons).find(b => b.textContent?.trim() === 'All')
    expect(defaultBtn?.getAttribute('aria-selected')).toBe('false')
  })
})
