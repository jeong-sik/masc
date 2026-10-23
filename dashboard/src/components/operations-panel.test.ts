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
  vi.doMock('./keeper-asks/keeper-asks-surface', () => ({
    KeeperAsksSurface: () => html`<div data-testid="keeper-asks">Questions</div>`,
  }))
  vi.doMock('./server-config', () => ({
    ServerConfig: () => html`<div data-testid="server-config">ServerConfig</div>`,
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
    vi.doUnmock('./keeper-asks/keeper-asks-surface')
    vi.doUnmock('./server-config')
  })

  it('renders interventions and keeper questions by default', async () => {
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.querySelector('[data-testid="keeper-asks"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
  })

  it('renders only Ops when view is ops', async () => {
    route.value.params = { section: 'operations', view: 'ops' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="ops"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="keeper-asks"]')).toBeNull()
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
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
    expect(container.querySelector('[data-testid="keeper-asks"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="surfaces"]')).toBeNull()
  })

  it('opens server configuration without intervention or question panels', async () => {
    route.value.params = { section: 'operations', view: 'inspector' }
    const { OperationsPanel } = await loadPanel()
    render(html`<${OperationsPanel} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="server-config"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="ops"]')).toBeNull()
    expect(container.querySelector('[data-testid="keeper-asks"]')).toBeNull()
  })
})
