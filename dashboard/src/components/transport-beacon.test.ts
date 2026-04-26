import { describe, expect, it } from 'vitest'
import { computeBeaconView } from './transport-beacon'

const NOW = 1_000_000_000_000

describe('computeBeaconView', () => {
  it('returns gray (parallel mode) when wsOnly is false', () => {
    const view = computeBeaconView({
      wsOnly: false,
      connected: true,
      ready: true,
      lastEventAt: NOW - 1000,
      eventCount60s: 5,
      now: NOW,
    })
    expect(view.state).toBe('gray')
    expect(view.label).toBe('WS+SSE (legacy)')
  })

  it('returns red when wsOnly and the socket is not connected', () => {
    const view = computeBeaconView({
      wsOnly: true,
      connected: false,
      ready: false,
      lastEventAt: NOW - 1000,
      eventCount60s: 5,
      now: NOW,
    })
    expect(view.state).toBe('red')
    expect(view.label).toContain('disconnected')
  })

  it('returns red when wsOnly, socket connected but handshake not ready', () => {
    const view = computeBeaconView({
      wsOnly: true,
      connected: true,
      ready: false,
      lastEventAt: NOW - 1000,
      eventCount60s: 5,
      now: NOW,
    })
    expect(view.state).toBe('red')
  })

  it('returns yellow when wsOnly, ready, but no event has ever arrived', () => {
    const view = computeBeaconView({
      wsOnly: true,
      connected: true,
      ready: true,
      lastEventAt: 0,
      eventCount60s: 0,
      now: NOW,
    })
    expect(view.state).toBe('yellow')
    expect(view.label).toContain('silent')
  })

  it('returns yellow when wsOnly, ready, but the last event is older than the silent threshold', () => {
    const view = computeBeaconView({
      wsOnly: true,
      connected: true,
      ready: true,
      lastEventAt: NOW - 60_000,
      eventCount60s: 0,
      now: NOW,
    })
    expect(view.state).toBe('yellow')
  })

  it('returns green when wsOnly, ready, and an event arrived within the threshold', () => {
    const view = computeBeaconView({
      wsOnly: true,
      connected: true,
      ready: true,
      lastEventAt: NOW - 5_000,
      eventCount60s: 12,
      now: NOW,
    })
    expect(view.state).toBe('green')
    expect(view.label).toContain('12 events / 60s')
  })

  it('uses computed silentMs in the title for diagnostic display', () => {
    const view = computeBeaconView({
      wsOnly: true,
      connected: true,
      ready: true,
      lastEventAt: NOW - 7_500,
      eventCount60s: 3,
      now: NOW,
    })
    expect(view.title).toContain('7s ago')
  })
})
