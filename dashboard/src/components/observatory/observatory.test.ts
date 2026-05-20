import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { signal } from '@preact/signals'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const fetchTelemetry = vi.fn().mockResolvedValue({
  entries: [],
  total_matching_entries: 0,
  truncated: false,
})

const fetchToolQuality = vi.fn().mockResolvedValue({
  hourly_trend: [],
})

const routeSignal = signal<{ tab: string; params: Record<string, string>; postId: string | null }>({
  tab: 'monitoring',
  params: { section: 'observatory' },
  postId: null,
})

vi.mock('../../api/dashboard', () => ({
  fetchTelemetry,
  fetchToolQuality,
}))

vi.mock('../../router', () => ({
  route: routeSignal,
  replaceRoute: (tab: string, params?: Record<string, string>) => {
    routeSignal.value = { tab, params: params ?? {}, postId: null }
  },
}))

vi.mock('../../observatory-filter-store', () => ({
  currentKeeperFilter: () => null,
  currentTimeRangeFilter: () => '1h',
  setTimeRangeFilter: vi.fn(),
  timeRangeLabel: () => '최근 1시간',
  timeRangeShortLabel: () => '1시간',
  timeRangeToMs: () => 60 * 60_000,
  TIME_RANGE_PRESETS: ['5m', '1h', '6h', '24h', '7d'],
}))

vi.mock('../../sse-store', () => ({
  registerActivityRefresh: () => () => {},
}))

vi.mock('./event-track', () => ({
  EventTrack: () => html`<div>event-track</div>`,
}))

vi.mock('./tool-call-track', () => ({
  ToolCallTrack: () => html`<div>tool-call-track</div>`,
}))

vi.mock('./metric-track', () => ({
  MetricTrack: () => html`<div>metric-track</div>`,
}))

vi.mock('./cross-signal-readout', () => ({
  CrossSignalReadout: () => html`<div>cross-signal-readout</div>`,
}))

vi.mock('./detail-pane', () => ({
  DetailPane: () => html`<div>detail-pane</div>`,
}))

const cursorPosition = signal<number | null>(null)
vi.mock('./cursor-store', () => ({
  cursorPosition,
}))

vi.mock('../live', () => ({
  Live: () => html`<section>live-monitor-stub</section>`,
}))

vi.mock('../activity-graph', () => ({
  ObservatoryActivityPanels: () => html`<section>activity-panels-stub</section>`,
}))

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
    }
  })
}

async function setRoute(params: Record<string, string>) {
  const router = await import('../../router')
  router.route.value = { tab: 'monitoring', params, postId: null }
}

describe('Observatory', () => {
  let container: HTMLDivElement

  beforeEach(async () => {
    container = document.createElement('div')
    document.body.appendChild(container)
    await setRoute({ section: 'observatory' })
    fetchTelemetry.mockClear()
    fetchToolQuality.mockClear()
    cursorPosition.value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
  })

  it('shows timeline panels by default', async () => {
    const { Observatory } = await import('./observatory')

    await act(async () => {
      render(html`<${Observatory} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
    await waitFor(() => {
      expect(container.textContent).toContain('Evidence Timeline')
    })
    expect(container.textContent).not.toContain('activity-panels-stub')
    expect(container.textContent).not.toContain('live-monitor-stub')
    expect(container.textContent).toContain('최근 1시간')
    expect(container.textContent).toContain('자동 갱신')
    expect(container.textContent).toContain('Timeline')
  }, 30000)

  it('switches to activity graph without rendering timeline tracks', async () => {
    const { Observatory, refreshObservatorySurface } = await import('./observatory')

    await act(async () => {
      render(html`<${Observatory} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const activityButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('Activity Graph'))

    expect(activityButton).toBeTruthy()

    await act(async () => {
      activityButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })
    await flushUi()

    await waitFor(() => {
      expect(container.textContent).toContain('activity-panels-stub')
    })
    const router = await import('../../router')
    expect(router.route.value.params.view).toBe('activity')
    expect(container.textContent).not.toContain('event-track')

    await act(async () => {
      refreshObservatorySurface()
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
  }, 30000)

  it('honors view=live route param without rendering timeline panels', async () => {
    await setRoute({ section: 'observatory', view: 'live' })
    const { Observatory } = await import('./observatory')

    await act(async () => {
      render(html`<${Observatory} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    await waitFor(() => {
      expect(container.textContent).toContain('live-monitor-stub')
    })
    expect(container.textContent).not.toContain('activity-panels-stub')
    expect(container.textContent).toContain('Live stream')
    expect(fetchTelemetry).not.toHaveBeenCalled()
    expect(fetchToolQuality).not.toHaveBeenCalled()
  }, 30000)
})
