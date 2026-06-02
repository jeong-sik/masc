import { describe, expect, test } from 'vitest'
import { signal } from '@preact/signals'
import { startNavTelemetry, type NavEvent } from './nav-telemetry'
import { REDIRECTED_FROM_PARAM } from '../router'
import type { RouteState } from '../types'

function harness() {
  const events: NavEvent[] = []
  let clock = 1_000
  const r = signal<RouteState>({ tab: 'overview', params: {}, postId: null })
  const dispose = startNavTelemetry({
    routeSignal: r,
    send: (e) => events.push(e),
    now: () => clock,
    collapseWindowMs: 500,
  })
  return {
    events,
    advance(ms: number) { clock += ms },
    setRoute(next: RouteState) { r.value = next },
    dispose,
  }
}

describe('nav-telemetry', () => {
  test('emits initial route on subscribe', () => {
    const h = harness()
    expect(h.events).toEqual([
      { surface: 'overview', section: null, redirected_from: null },
    ])
    h.dispose()
  })

  test('emits on surface change', () => {
    const h = harness()
    h.advance(1000)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    expect(h.events).toEqual([
      { surface: 'overview', section: null, redirected_from: null },
      { surface: 'monitoring', section: 'journey', redirected_from: null },
    ])
    h.dispose()
  })

  test('emits on section change within same surface', () => {
    const h = harness()
    h.advance(1000)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    h.advance(1000)
    h.setRoute({ tab: 'monitoring', params: { section: 'agents' }, postId: null })
    expect(h.events.map(e => e.section)).toEqual([null, 'journey', 'agents'])
    h.dispose()
  })

  test('collapses identical (surface, section) within window', () => {
    const h = harness()
    h.advance(100)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    h.advance(100)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    h.advance(100)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    expect(h.events).toHaveLength(2)
    h.dispose()
  })

  test('re-emits identical pair after collapse window expires', () => {
    const h = harness()
    h.advance(100)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    h.advance(800)
    // Force a re-emission by mutating then restoring.
    h.setRoute({ tab: 'monitoring', params: { section: 'agents' }, postId: null })
    h.advance(800)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    expect(h.events.map(e => e.section)).toEqual([null, 'journey', 'agents', 'journey'])
    h.dispose()
  })

  test('carries redirected_from when route arrived via redirect', () => {
    const h = harness()
    h.advance(1000)
    h.setRoute({
      tab: 'workspace',
      params: {
        section: 'repositories',
        view: 'graph',
        [REDIRECTED_FROM_PARAM]: 'monitoring:git-graph',
      },
      postId: null,
    })
    expect(h.events.at(-1)).toEqual({
      surface: 'workspace',
      section: 'repositories',
      redirected_from: 'monitoring:git-graph',
    })
    h.dispose()
  })

  test('emits redirected_from null for direct navigation', () => {
    const h = harness()
    h.advance(1000)
    h.setRoute({ tab: 'lab', params: { section: 'tools' }, postId: null })
    expect(h.events.at(-1)?.redirected_from).toBeNull()
    h.dispose()
  })

  test('disposer stops further emissions', () => {
    const h = harness()
    h.dispose()
    h.advance(1000)
    h.setRoute({ tab: 'monitoring', params: { section: 'journey' }, postId: null })
    expect(h.events).toHaveLength(1)
  })
})
