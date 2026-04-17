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

  it('renders both Ops and Governance by default when section is not set', async () => {
    route.value.params = {}
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).toContain('Governance')
    expect(container.textContent).not.toContain('Connectors')
  })

  it('renders both Ops and Governance when section is operations', async () => {
    route.value.params = { section: 'operations' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
    expect(container.textContent).toContain('Governance')
  })

  // Phase 7: Connectors was promoted to its own top-level surface so the
  // Operations panel no longer routes `view=connectors`. Legacy URLs are
  // handled by a redirect in operations-panel.ts (covered separately by
  // operations-panel.test.ts). The chip-under-operations rendering test
  // was removed here because it pinned dead behavior.

  it('renders LabInspector when view is inspector (Phase 6)', async () => {
    route.value.params = { section: 'operations', view: 'inspector' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Inspector')
    expect(container.textContent).not.toContain('Ops')
  })

  it('falls back to Ops+Governance for unknown section values', async () => {
    route.value.params = { section: 'unknown-section' }
    const { Operations } = await loadOperations()
    render(html`<${Operations} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Ops')
  })
})
