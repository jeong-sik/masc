// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const route = { value: { tab: 'lab' as string, params: {} as Record<string, string> } }

async function loadLab() {
  vi.resetModules()
  vi.doMock('../router', () => ({ route, hashForRoute: () => '#lab' }))
  vi.doMock('./tools/tools-main', () => ({
    Tools: () => html`<div data-testid="lab-tools">Tools</div>`,
  }))
  vi.doMock('./harness-health', () => ({
    HarnessHealth: () => html`<div data-testid="lab-harness">Harness</div>`,
  }))
  vi.doMock('./design-canvas', () => ({
    DesignCanvas: () => html`<div data-testid="lab-design-canvas">DesignCanvas</div>`,
  }))
  vi.doMock('./lab-perf', () => ({
    LabPerf: () => html`<div data-testid="lab-perf">LabPerf</div>`,
  }))
  vi.doMock('./memory/memory-explore', () => ({
    MemoryExplore: () => html`<div data-testid="lab-memory-explore">MemoryExplore</div>`,
  }))
  vi.doMock('./memory/keeper-memory-health', () => ({
    KeeperMemoryHealth: () => html`<div data-testid="lab-keeper-memory-health">KeeperMemoryHealth</div>`,
  }))
  return import('./lab')
}

describe('Lab', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'lab', params: { section: 'tools' } }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../router')
    vi.doUnmock('./tools/tools-main')
    vi.doUnmock('./harness-health')
    vi.doUnmock('./design-canvas')
    vi.doUnmock('./lab-perf')
    vi.doUnmock('./memory/memory-explore')
    vi.doUnmock('./memory/keeper-memory-health')
  })

  it('renders tools section by default', async () => {
    route.value.params = { section: 'tools' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-surface"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="lab-tools"]')).not.toBeNull()
  })

  it('renders harness section', async () => {
    route.value.params = { section: 'harness' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-harness"]')).not.toBeNull()
  })

  it('renders design-canvas section', async () => {
    route.value.params = { section: 'design-canvas' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-design-canvas"]')).not.toBeNull()
  })

  it('renders performance section', async () => {
    route.value.params = { section: 'performance' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-perf"]')).not.toBeNull()
  })

  it('renders memory-explore section', async () => {
    route.value.params = { section: 'memory-explore' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-memory-explore"]')).not.toBeNull()
  })

  it('renders keeper memory health section', async () => {
    route.value.params = { section: 'keeper-memory-health' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-keeper-memory-health"]')).not.toBeNull()
  })

  it('falls back to tools for unknown lab section', async () => {
    route.value.params = { section: 'unknown' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-tools"]')).not.toBeNull()
  })
})
