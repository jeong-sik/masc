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
  vi.doMock('../router', () => ({ route, replaceRoute: vi.fn(), hashForRoute: () => '#command' }))
  vi.doMock('./ops', () => ({
    Ops: () => html`<div data-testid="ops">Ops</div>`,
  }))
  vi.doMock('./approvals/approvals-surface', () => ({
    ApprovalsSurface: () => html`<div data-testid="gate-hitl">Gate / HITL</div>`,
  }))
  vi.doMock('./lab-inspector', () => ({
    LabInspector: () => html`<div data-testid="inspector">Inspector</div>`,
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
    vi.doUnmock('./approvals/approvals-surface')
    vi.doUnmock('./lab-inspector')
  })

  it('renders Ops and Gate/HITL when view is not set (default)', async () => {
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).toContain('Gate / HITL')
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
  })

  it('renders only Ops when view is ops', async () => {
    route.value.params = { section: 'operations', view: 'ops' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="ops"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="gate-hitl"]')).toBeNull()
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
  })

  it('renders only Gate/HITL when view is gate', async () => {
    route.value.params = { section: 'operations', view: 'gate' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('Ops')
    expect(container.textContent).toContain('Gate / HITL')
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
  })

  it('renders FilterChips options for the current operations views', async () => {
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    const tablist = container.querySelector('[role="tablist"]')
    const buttons = tablist?.querySelectorAll('[role="tab"]') ?? []
    expect(buttons.length).toBe(4)
    const labels = Array.from(buttons).map(b => b.textContent?.trim())
    expect(labels).toContain('All')
    expect(labels).toContain('Intervene')
    expect(labels).toContain('Gate / HITL')
    expect(labels).toContain('Inspector')
  })

  it('wraps the panel in the v2 command surface class', async () => {
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.querySelector('.v2-command-surface')).not.toBeNull()
  })

  it('falls back to default for unknown view param', async () => {
    route.value.params = { section: 'operations', view: 'unknown' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).toContain('Gate / HITL')
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
  })

  it('marks the active chip with aria-selected=true', async () => {
    route.value.params = { section: 'operations', view: 'gate' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    const buttons = container.querySelectorAll('button[type="button"]')
    const gateButton = Array.from(buttons).find(b => b.textContent?.trim() === 'Gate / HITL')
    expect(gateButton?.getAttribute('aria-selected')).toBe('true')

    const defaultBtn = Array.from(buttons).find(b => b.textContent?.trim() === 'All')
    expect(defaultBtn?.getAttribute('aria-selected')).toBe('false')
  })
})
