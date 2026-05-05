import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import * as Vitest from 'vitest'

const { afterEach, beforeEach, describe, expect, it } = Vitest

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadPanels(options: {
  fetchActivityGraph: ReturnType<typeof Vitest.vi.fn>
  getRange: () => '5m' | '1h' | '6h' | '24h' | '7d' | null
}) {
  Vitest.vi.resetModules()
  Vitest.vi.doMock('../api', () => ({
    fetchActivityGraph: options.fetchActivityGraph,
  }))
  Vitest.vi.doMock('../sse-store', () => ({
    registerActivityRefresh: Vitest.vi.fn(() => () => {}),
  }))
  Vitest.vi.doMock('../router', () => ({
    hashForRoute: Vitest.vi.fn(() => '#'),
  }))
  Vitest.vi.doMock('../observatory-filter-store', () => ({
    currentTimeRangeFilter: Vitest.vi.fn(() => options.getRange()),
    timeRangeLabel: Vitest.vi.fn((value: string) => value),
  }))
  Vitest.vi.doMock('./common/card', () => ({
    Card: ({ children, testId, title }: { children?: unknown; testId?: string; title?: string }) =>
      html`<section data-testid=${testId ?? undefined}><h2>${title ?? ''}</h2>${children}</section>`,
  }))
  Vitest.vi.doMock('./common/feedback-state', () => ({
    EmptyState: ({ children, message }: { children?: unknown; message?: string }) =>
      html`<div>${message ?? children}</div>`,
    LoadingState: ({ children }: { children?: unknown }) =>
      html`<div>${children}</div>`,
    ErrorState: ({ message }: { message?: string }) =>
      html`<div>${message ?? ''}</div>`,
  }))
  Vitest.vi.doMock('./common/button', () => ({
    ActionButton: ({ children, onClick }: { children?: unknown; onClick?: () => void }) =>
      html`<button onClick=${onClick}>${children}</button>`,
  }))
  Vitest.vi.doMock('./common/filter-chips', () => ({
    FilterChips: () => null,
  }))
  Vitest.vi.doMock('./common/time-ago', () => ({
    TimeAgo: () => null,
  }))
  Vitest.vi.doMock('./common/sparkline', () => ({
    Sparkline: () => null,
  }))
  Vitest.vi.doMock('./activity-graph-view', () => ({
    GraphView: () => null,
  }))
  Vitest.vi.doMock('./activity-swimlane', () => ({
    ActivitySwimlane: () => null,
  }))
  Vitest.vi.doMock('./activity-heatmap', () => ({
    ActivityHeatmap: () => null,
  }))
  Vitest.vi.doMock('./keeper-phase-strip', () => ({
    KeeperPhaseTimeline: () => null,
  }))
  Vitest.vi.doMock('./common/collapsible', () => ({
    CollapsibleSection: ({ children, title }: { children?: unknown; title?: string }) =>
      html`<section><h3>${title ?? ''}</h3>${children}</section>`,
  }))
  return import('./activity-graph')
}

describe('ObservatoryActivityPanels', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    Vitest.vi.resetModules()
    Vitest.vi.clearAllMocks()
  })

  it('refetches the graph when the observatory time range changes', async () => {
    const range = signal<'1h' | '24h'>('1h')
    const fetchActivityGraph = Vitest.vi.fn().mockResolvedValue(null)

    const { ObservatoryActivityPanels } = await loadPanels({
      fetchActivityGraph,
      getRange: () => range.value,
    })

    render(html`<${ObservatoryActivityPanels} />`, container)
    await flushUi()

    range.value = '24h'
    await flushUi()

    expect(fetchActivityGraph).toHaveBeenCalledTimes(2)
    expect(fetchActivityGraph.mock.calls[0]?.[0]).toBe('1h')
    expect(fetchActivityGraph.mock.calls[1]?.[0]).toBe('24h')
  }, 20000)

  it('shows a warm-up state when activity endpoints return not initialized', async () => {
    const fetchActivityGraph = Vitest.vi.fn().mockResolvedValue(null)

    const { ObservatoryActivityPanels } = await loadPanels({
      fetchActivityGraph,
      getRange: () => '1h',
    })

    render(html`<${ObservatoryActivityPanels} />`, container)
    await flushUi()

    expect(container.querySelector('[data-testid="activity_graph.warming"]')).toBeTruthy()
    expect(container.textContent).toContain('활동 분석 초기화 중')
  }, 20000)
})
