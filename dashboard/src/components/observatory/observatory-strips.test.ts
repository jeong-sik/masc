// @vitest-environment happy-dom
// Design-vocabulary pins for the observatory strips after the keeper-v2
// monitor-more re-skin: .ob-cursor / .ob-readout / .ob-detail(-body).
import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../../api/dashboard'
import { CursorLine } from './cursor-line'
import { cursorPosition, clearCursor } from './cursor-store'
import { CrossSignalReadout } from './cross-signal-readout'
import { DetailPane } from './detail-pane'
import { detailSelection, selectEntity, clearSelection } from './detail-selection-store'

const START = Date.parse('2026-08-23T10:00:00Z')

function entry(overrides: Record<string, unknown>): TelemetryEntry {
  return { source: 'agent_event', ts: (START + 60_000) / 1000, ...overrides } as TelemetryEntry
}

describe('CursorLine (design vocabulary)', () => {
  afterEach(() => {
    cleanup()
    clearCursor()
  })

  it('renders nothing without a cursor, .ob-cursor when one is active', () => {
    const { container, rerender } = render(html`<${CursorLine} />`)
    expect(container.querySelector('.ob-cursor')).toBeNull()

    cursorPosition.value = { ts: START + 30_000, pct: 0.5 }
    rerender(html`<${CursorLine} />`)
    const line = container.querySelector('.ob-cursor') as HTMLElement
    expect(line).toBeTruthy()
    expect(line.style.left).toBe('50.000%')
  })
})

describe('CrossSignalReadout (design vocabulary)', () => {
  afterEach(() => {
    cleanup()
    clearCursor()
  })

  it('always renders .ob-readout with a dim hint when no cursor is active', () => {
    const { container } = render(html`
      <${CrossSignalReadout} events=${[]} hourlyTrend=${[]} eventWindowMs=${60_000} />
    `)
    expect(container.querySelector('.ob-readout')).toBeTruthy()
    expect(container.querySelector('.ob-readout .ia-k')?.textContent).toBe('Cross-signal readout')
    expect(container.querySelector('.ob-readout .dim')).toBeTruthy()
  })

  it('reads events, tool calls and success rate at the cursor time', () => {
    cursorPosition.value = { ts: START + 60_000, pct: 0.5 }
    const { container } = render(html`
      <${CrossSignalReadout}
        events=${[
          entry({ event_type: 'wake' }),
          entry({ source: 'tool_call_io', tool_name: 'tool_read_file', success: false }),
        ]}
        hourlyTrend=${[{ hour: '2026-08-23T10', calls: 10, success: 9, success_rate: 90 }]}
        eventWindowMs=${120_000}
      />
    `)
    const line = container.querySelector('.ob-readout .mono')
    expect(line?.textContent).toContain('이벤트 2')
    expect(line?.textContent).toContain('도구 호출 1 / 1 실패')
    expect(line?.textContent).toContain('성공률 90.0%')
  })
})

describe('DetailPane (design vocabulary)', () => {
  afterEach(() => {
    cleanup()
    clearSelection()
  })

  it('always renders .ob-detail with a dim hint when nothing is selected', () => {
    const { container } = render(html`<${DetailPane} />`)
    expect(container.querySelector('.ob-detail')).toBeTruthy()
    expect(container.querySelector('.ob-detail .ia-k')?.textContent).toBe('Detail pane')
    expect(container.querySelector('.ob-detail-body')).toBeNull()
  })

  it('renders .ob-detail-body with a toned ai-b badge for a selection', () => {
    selectEntity({
      kind: 'tool_call',
      entry: entry({ source: 'tool_call_io', tool_name: 'tool_execute', success: false, keeper: 'sangsu' }),
      ts: START + 60_000,
      bucketCount: 1,
    })
    const { container } = render(html`<${DetailPane} />`)
    expect(container.querySelector('.ob-detail-body')).toBeTruthy()
    expect(container.querySelector('.ob-detail-body .ai-b.bad')?.textContent).toBe('failure')
    expect(container.textContent).toContain('tool_execute')
    expect(container.textContent).toContain('sangsu')
  })
})

describe('detail-selection-store round trip', () => {
  afterEach(() => clearSelection())

  it('clearSelection empties the selection', () => {
    selectEntity({ kind: 'event', entry: entry({}), ts: START, bucketCount: 1 })
    expect(detailSelection.value).not.toBeNull()
    clearSelection()
    expect(detailSelection.value).toBeNull()
  })
})
