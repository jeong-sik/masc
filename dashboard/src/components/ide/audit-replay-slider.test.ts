import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AuditReplaySlider,
  auditReplayBounds,
  filterReplayEvents,
  formatReplayTime,
  type AuditReplayEvent,
} from './audit-replay-slider'

const events: AuditReplayEvent[] = [
  { id: 'older', timestamp_ms: Date.UTC(2026, 4, 5, 10, 0, 0) },
  { id: 'middle', timestamp_ms: Date.UTC(2026, 4, 5, 10, 1, 0) },
  { id: 'newer', timestamp_ms: Date.UTC(2026, 4, 5, 10, 2, 0) },
]

describe('audit replay slider', () => {
  it('derives finite timeline bounds', () => {
    expect(auditReplayBounds([...events, { id: 'bad', timestamp_ms: Number.NaN }])).toEqual({
      min: events[0]!.timestamp_ms,
      max: events[2]!.timestamp_ms,
      count: 3,
    })
  })

  it('filters events at the replay cursor', () => {
    expect(filterReplayEvents(events, events[1]!.timestamp_ms).map(event => event.id))
      .toEqual(['older', 'middle'])
    expect(filterReplayEvents(events, null).map(event => event.id))
      .toEqual(['older', 'middle', 'newer'])
  })

  it('formats the replay cursor as UTC time', () => {
    expect(formatReplayTime(events[1]!.timestamp_ms)).toBe('10:01:00')
    expect(formatReplayTime(null)).toBe('--:--:--')
  })

  it('renders an accessible scrubber and emits cursor updates', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(AuditReplaySlider, { events, value: events[1]!.timestamp_ms, onChange }), container)

    const slider = container.querySelector('[role="slider"]') as HTMLElement
    expect(slider).not.toBeNull()
    expect(slider.getAttribute('aria-label')).toBe('Audit replay timestamp')
    expect(container.textContent).toContain('2/3')

    slider.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))
    expect(onChange).toHaveBeenCalledWith(events[1]!.timestamp_ms + 1)
  })
})
