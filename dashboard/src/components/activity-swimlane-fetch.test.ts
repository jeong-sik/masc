import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

function emptySwimlane() {
  return {
    agents: [],
    spans: [],
    time_range: {
      min_ms: 0,
      max_ms: 0,
    },
  }
}

async function loadSwimlane(options: {
  fetchSwimlane: ReturnType<typeof vi.fn>
  onRegisterRefresh?: (fn: () => void) => void
}) {
  vi.resetModules()
  vi.doMock('../api', () => ({
    fetchSwimlane: options.fetchSwimlane,
  }))
  vi.doMock('../sse-store', () => ({
    registerActivityRefresh: vi.fn((fn: () => void) => {
      options.onRegisterRefresh?.(fn)
      return () => {}
    }),
  }))
  vi.doMock('./common/card', () => ({
    Card: ({ children, testId, title }: { children?: unknown; testId?: string; title?: string }) =>
      html`<section data-testid=${testId ?? undefined}><h2>${title ?? ''}</h2>${children}</section>`,
  }))
  vi.doMock('./common/feedback-state', () => ({
    EmptyState: ({ children }: { children?: unknown }) => html`<div>${children}</div>`,
    LoadingState: ({ children }: { children?: unknown }) => html`<div>${children}</div>`,
  }))
  vi.doMock('./activity-graph-view', () => ({
    selectedNodeId: signal<string | null>(null),
    highlightedAgentId: signal<string | null>(null),
  }))
  vi.doMock('../lib/format-time', () => ({
    formatDurationMs: (ms: number) => `${ms}ms`,
  }))
  vi.doMock('../lib/escape-html', () => ({
    escapeHtml: (value: string) => value,
    tooltipHtml: (lines: string[]) => lines.join(' | '),
  }))
  vi.doMock('vis-data', () => ({
    DataSet: class MockDataSet<T> {
      readonly items: T[]

      constructor(items: T[]) {
        this.items = items
      }

      get(): undefined {
        return undefined
      }
    },
  }))
  vi.doMock('vis-timeline', () => ({
    Timeline: class MockTimeline {
      on(): void {}

      setSelection(): void {}

      focus(): void {}

      destroy(): void {}
    },
  }))
  return import('./activity-swimlane')
}

describe('ActivitySwimlane fetch wiring', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
  })

  it('fetches swimlane for the mounted range and the updated range', async () => {
    const fetchSwimlane = vi.fn().mockResolvedValue(emptySwimlane())
    const { ActivitySwimlane } = await loadSwimlane({ fetchSwimlane })

    render(html`<${ActivitySwimlane} since="1h" />`, container)
    await flushUi()

    render(html`<${ActivitySwimlane} since="24h" />`, container)
    await flushUi()

    expect(fetchSwimlane).toHaveBeenCalledTimes(2)
    expect(fetchSwimlane.mock.calls[0]?.[0]).toBe('1h')
    expect(fetchSwimlane.mock.calls[1]?.[0]).toBe('24h')
  })

  it('re-fetches swimlane with the latest range when activity refresh fires', async () => {
    let activityRefreshCallback: (() => void) | undefined
    const fetchSwimlane = vi.fn().mockResolvedValue(emptySwimlane())
    const { ActivitySwimlane } = await loadSwimlane({
      fetchSwimlane,
      onRegisterRefresh: (fn) => { activityRefreshCallback = fn },
    })

    render(html`<${ActivitySwimlane} since="1h" />`, container)
    await flushUi()

    render(html`<${ActivitySwimlane} since="24h" />`, container)
    await flushUi()

    expect(activityRefreshCallback).toBeTypeOf('function')
    const callback = activityRefreshCallback
    if (callback == null) throw new Error('missing activity refresh callback')
    callback()
    await flushUi()

    expect(fetchSwimlane).toHaveBeenCalledTimes(3)
    expect(fetchSwimlane.mock.calls[2]?.[0]).toBe('24h')
  })
})
