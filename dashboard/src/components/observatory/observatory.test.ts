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

vi.mock('../../api/dashboard', () => ({
  fetchTelemetry,
  fetchToolQuality,
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

describe('Observatory', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
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
      expect(container.textContent).toContain('activity-panels-stub')
    })
    expect(container.textContent).not.toContain('live-monitor-stub')
    expect(container.textContent).toContain('최근 1시간')
    expect(container.textContent).toContain('자동 갱신')
    expect(container.textContent).toContain('hover any track for cross-signal readout')
  }, 30000)

  it('switches to live tab without rendering timeline panels', async () => {
    const { Observatory, refreshObservatorySurface } = await import('./observatory')

    await act(async () => {
      render(html`<${Observatory} />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const liveButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('라이브'))

    expect(liveButton).toBeTruthy()

    await act(async () => {
      liveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      await Promise.resolve()
    })
    await flushUi()

    await waitFor(() => {
      expect(container.textContent).toContain('live-monitor-stub')
    })
    expect(container.textContent).not.toContain('activity-panels-stub')
    expect(container.textContent).toContain('실시간 스트림과 에이전트 상태를 한곳에서 봅니다.')

    await act(async () => {
      refreshObservatorySurface()
      await Promise.resolve()
    })
    await flushUi()

    expect(fetchTelemetry).toHaveBeenCalledTimes(1)
    expect(fetchToolQuality).toHaveBeenCalledTimes(1)
  }, 30000)
})
