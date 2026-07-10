// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const route = { value: { tab: 'monitoring' as string, params: {} as Record<string, string> } }
const navigateMock = vi.fn()

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadPlane() {
  vi.resetModules()
  vi.doMock('../router', () => ({ route, navigate: navigateMock }))
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
    MemorySubsystems: ({ focus }: { focus?: string }) =>
      html`<div data-testid="memory-subsystems" data-focus=${focus ?? ''}>MemorySubsystems</div>`,
  }))
  vi.doMock('./common/route-link', () => ({
    RouteLink: ({ children, params }: { children?: unknown; params?: Record<string, string> }) => html`
      <a data-testid="route-link" data-section=${params?.section ?? ''} data-view=${params?.view ?? ''}>${children}</a>
    `,
  }))
  return import('./cognition-plane')
}

describe('CognitionPlane', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    route.value = { tab: 'monitoring', params: { section: 'cognition' } }
    navigateMock.mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../router')
    vi.doUnmock('./keeper-decisions-stream')
    vi.doUnmock('./keeper-cognition-inspector')
    vi.doUnmock('./keeper-token-stats')
    vi.doUnmock('./memory-subsystems')
    vi.doUnmock('./common/route-link')
  })

  it('renders a cognition overview without embedding the agent roster', async () => {
    route.value.params = { section: 'cognition' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('.v2-monitoring-surface')).not.toBeNull()
    expect(container.textContent).toContain('Keeper')
    expect(container.textContent).toContain('Keeper Fleet')
    expect(container.querySelector('[data-testid="agents-unified"]')).toBeNull()
    expect(container.querySelector('[data-testid="keeper-token-stats"]')).toBeNull()
    expect(container.querySelector('[data-section="agents"]')).not.toBeNull()
  })

  it('renders the keeper cognition inspector for the keeper view', async () => {
    route.value.params = { section: 'cognition', view: 'keeper', focus: 'tool-access' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="keeper-cognition-inspector"]')).not.toBeNull()
    expect(container.querySelector('[data-section="agents"]')).toBeNull()
  })

  it('renders the live decisions stream for the decisions view', async () => {
    route.value.params = { section: 'cognition', view: 'decisions' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="keeper-decisions-stream"]')).not.toBeNull()
    expect(container.textContent).not.toContain('backend-blocked')
  })

  it('routes memory focus into the memory subsystem entries surface', async () => {
    route.value.params = { section: 'cognition', view: 'memory', focus: 'entries' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="memory-subsystems"]')?.getAttribute('data-focus')).toBe('entries')
  })

  it('keeps entries focus when re-clicking the active memory view chip', async () => {
    route.value.params = { section: 'cognition', view: 'memory', focus: 'entries' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    const memoryChip = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === 'Memory')
    expect(memoryChip).not.toBeUndefined()

    memoryChip?.dispatchEvent(new MouseEvent('click', { bubbles: true }))

    expect(navigateMock).not.toHaveBeenCalled()
    expect(route.value.params.focus).toBe('entries')
  })

  it('uses the episodes focus for the episodes view', async () => {
    route.value.params = { section: 'cognition', view: 'episodes' }
    const { CognitionPlane } = await loadPlane()

    render(html`<${CognitionPlane} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="memory-subsystems"]')?.getAttribute('data-focus')).toBe('episodes')
  })
})
