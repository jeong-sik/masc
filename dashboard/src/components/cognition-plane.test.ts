// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const route = { value: { tab: 'monitoring' as string, params: {} as Record<string, string> } }

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadPlane() {
  vi.resetModules()
  vi.doMock('../router', () => ({ route, navigate: vi.fn() }))
  vi.doMock('./agents-unified', () => ({
    AgentsUnified: () => html`<div data-testid="agents-unified">AgentsUnified</div>`,
  }))
  vi.doMock('./autoresearch', () => ({
    Autoresearch: () => html`<div data-testid="autoresearch">Autoresearch</div>`,
  }))
  vi.doMock('./keeper-decisions-stream', () => ({
    KeeperDecisionsStream: () => html`<div data-testid="keeper-decisions-stream">KeeperDecisionsStream</div>`,
  }))
  vi.doMock('./keeper-cognition-inspector', () => ({
    KeeperCognitionInspector: () => html`<div data-testid="keeper-cognition-inspector">KeeperCognitionInspector</div>`,
  }))
  vi.doMock('./keeper-token-stats', () => ({
    KeeperTokenStats: () => html`<div data-testid="keeper-token-stats">KeeperTokenStats</div>`,
  }))
  vi.doMock('./memory-subsystems', () => ({
    MemorySubsystems: () => html`<div data-testid="memory-subsystems">MemorySubsystems</div>`,
  }))
  return import('./cognition-plane')
}

describe('CognitionPlane', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'monitoring', params: { section: 'cognition' } }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../router')
    vi.doUnmock('./agents-unified')
    vi.doUnmock('./autoresearch')
    vi.doUnmock('./keeper-decisions-stream')
    vi.doUnmock('./keeper-cognition-inspector')
    vi.doUnmock('./keeper-token-stats')
    vi.doUnmock('./memory-subsystems')
  })

  it('renders the keeper cognition inspector for the keeper view', async () => {
    route.value.params = { section: 'cognition', view: 'keeper', focus: 'bdi' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="keeper-cognition-inspector"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="agents-unified"]')).toBeNull()
  })

  it('renders the live decisions stream for the decisions view', async () => {
    route.value.params = { section: 'cognition', view: 'decisions' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="keeper-decisions-stream"]')).not.toBeNull()
    expect(container.textContent).not.toContain('backend-blocked')
  })
})
