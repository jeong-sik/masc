// @vitest-environment happy-dom
// Design-vocabulary pins for the observatory tracks after the keeper-v2
// monitor-more re-skin: .ob-track/.ob-track-k/.ob-lane/.ob-ev/.ob-call/.ob-svg.
import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { TelemetryEntry } from '../../api/dashboard'
import { EventTrack } from './event-track'
import { ToolCallTrack } from './tool-call-track'
import { MetricTrack } from './metric-track'

const START = Date.parse('2026-08-23T10:00:00Z')
const END = Date.parse('2026-08-23T11:00:00Z')

function entry(overrides: Record<string, unknown>): TelemetryEntry {
  return { source: 'agent_event', ts: (START + 60_000) / 1000, ...overrides } as TelemetryEntry
}

describe('EventTrack (design vocabulary)', () => {
  afterEach(() => cleanup())

  it('renders ob-track/ob-lane with toned ob-ev markers', () => {
    const { container } = render(html`
      <${EventTrack}
        events=${[
          entry({ event_type: 'keeper_failed', ts: (START + 60_000) / 1000 }),
          entry({ event_type: 'wake', ts: (START + 20 * 60_000) / 1000 }),
          entry({ event_type: 'gate_requested', ts: (START + 40 * 60_000) / 1000 }),
        ]}
        windowStart=${START}
        windowEnd=${END}
      />
    `)

    expect(container.querySelector('.ob-track')).toBeTruthy()
    expect(container.querySelector('.ob-track-k')?.textContent).toBe('events')
    expect(container.querySelector('.ob-lane')).toBeTruthy()
    expect(container.querySelector('.ob-ev.t-bad')).toBeTruthy()
    expect(container.querySelector('.ob-ev.t-ok')).toBeTruthy()
    expect(container.querySelector('.ob-ev.t-info')).toBeTruthy()
  })

  it('renders an empty treatment when no events are in range', () => {
    const { container } = render(html`
      <${EventTrack} events=${[]} windowStart=${START} windowEnd=${END} />
    `)
    expect(container.textContent).toContain('이 시간 범위에 이벤트 없음')
    expect(container.querySelector('.ob-ev')).toBeNull()
  })
})

describe('ToolCallTrack (design vocabulary)', () => {
  afterEach(() => cleanup())

  it('renders ob-call bars, failed calls marked bad, height from real duration', () => {
    const { container } = render(html`
      <${ToolCallTrack}
        events=${[
          entry({ source: 'tool_call_io', tool_name: 'tool_read_file', success: true, duration_ms: 4200, ts: (START + 10 * 60_000) / 1000 }),
          entry({ source: 'tool_call_io', tool_name: 'tool_execute', success: false, duration_ms: 100, ts: (START + 50 * 60_000) / 1000 }),
        ]}
        windowStart=${START}
        windowEnd=${END}
      />
    `)

    expect(container.querySelector('.ob-track-k')?.textContent).toBe('tool calls')
    const calls = container.querySelectorAll('.ob-call')
    expect(calls.length).toBe(2)
    expect(container.querySelector('.ob-call.bad')).toBeTruthy()
    // full-scale duration clamps to 100% height; short duration stays near base
    const heights = [...calls].map(c => (c as HTMLElement).style.height)
    expect(heights).toContain('100%')
    expect(container.querySelector('.ob-call.bad')?.getAttribute('title')).toContain('failed')
  })
})

describe('MetricTrack (design vocabulary)', () => {
  afterEach(() => cleanup())

  it('renders the success-rate polyline inside ob-svg', () => {
    const { container } = render(html`
      <${MetricTrack}
        points=${[
          { hour: '2026-08-23T10', calls: 10, success: 9, success_rate: 90 },
          { hour: '2026-08-23T11', calls: 12, success: 12, success_rate: 100 },
        ]}
        windowStart=${START}
        windowEnd=${END}
      />
    `)

    expect(container.querySelector('.ob-track-k')?.textContent).toBe('success %')
    const svg = container.querySelector('svg.ob-svg')
    expect(svg).toBeTruthy()
    expect(svg?.querySelector('polyline')).toBeTruthy()
  })
})
