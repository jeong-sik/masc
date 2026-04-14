import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const route = { value: { tab: 'command' as string, params: {} as Record<string, string> } }

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadOperations() {
  vi.resetModules()
  vi.doMock('../router', () => ({ route }))
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
  return import('./control')
}

describe('Operations control surface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'command', params: {} }
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
  })

  it('renders Ops by default when section is not set', async () => {
    route.value.params = {}
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).not.toContain('Governance')
    expect(container.textContent).not.toContain('Connectors')
  })

  it('renders Ops when section is intervene', async () => {
    route.value.params = { section: 'intervene' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
  })

  it('renders Governance when section is governance', async () => {
    route.value.params = { section: 'governance' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Governance')
    expect(container.textContent).not.toContain('Ops')
  })

  it('renders ConnectorStatusPanel when section is connectors', async () => {
    route.value.params = { section: 'connectors' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Connectors')
    expect(container.textContent).not.toContain('Ops')
    expect(container.textContent).not.toContain('Governance')
  })

  it('renders LabInspector when section is inspector', async () => {
    route.value.params = { section: 'inspector' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Inspector')
    expect(container.textContent).not.toContain('Ops')
  })

  it('falls back to Ops for unknown section values', async () => {
    route.value.params = { section: 'unknown-section' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
  })
})
