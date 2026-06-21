// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

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
  vi.doMock('./lab-perf', () => ({
    LabPerf: () => html`<div data-testid="lab-performance">Performance</div>`,
  }))
  vi.doMock('./memory-subsystems', () => ({
    MemorySubsystems: ({ focus }: { focus?: string }) =>
      html`<div data-testid="lab-memory-subsystems" data-focus=${focus ?? ''}>MemorySubsystems</div>`,
  }))
  vi.doMock('./memory/keeper-memory-health', () => ({
    KeeperMemoryHealth: () => html`<div data-testid="lab-keeper-memory-health">KeeperMemoryHealth</div>`,
  }))
  vi.doMock('./common/surface-header', () => ({
    SurfaceHeader: () => html`<header data-testid="surface-header">Lab</header>`,
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
    vi.resetModules()
    vi.doUnmock('../router')
    vi.doUnmock('./tools/tools-main')
    vi.doUnmock('./harness-health')
    vi.doUnmock('./lab-perf')
    vi.doUnmock('./memory/keeper-memory-health')
    vi.doUnmock('./memory-subsystems')
    vi.doUnmock('./common/surface-header')
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

  it('renders performance section', async () => {
    route.value.params = { section: 'performance' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-performance"]')).not.toBeNull()
  })

  it('renders keeper memory health section', async () => {
    route.value.params = { section: 'keeper-memory-health' }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)
    expect(container.querySelector('[data-testid="lab-keeper-memory-health"]')).not.toBeNull()
  })

  it('renders the live Memory OS subsystem section and passes through focus', async () => {
    route.value = { tab: 'lab', params: { section: 'memory-subsystems', focus: 'episodes' } }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)

    const memory = container.querySelector('[data-testid="lab-memory-subsystems"]')
    expect(memory).not.toBeNull()
    expect(memory?.getAttribute('data-focus')).toBe('episodes')
    expect(container.querySelector('[data-testid="lab-tools"]')).toBeNull()
  })

  it('falls back to tools for unknown lab sections', async () => {
    route.value = { tab: 'lab', params: { section: 'unknown' } }
    const { Lab } = await loadLab()

    render(html`<${Lab} />`, container)

    expect(container.querySelector('[data-testid="lab-tools"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="lab-memory-subsystems"]')).toBeNull()
  })
})
