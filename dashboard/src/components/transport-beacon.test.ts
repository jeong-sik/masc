import { describe, expect, it } from 'vitest'
import { computeBeaconView } from './transport-beacon'

const NOW = 1_000_000_000_000

function beaconInput(overrides: Partial<Parameters<typeof computeBeaconView>[0]> = {}) {
  return {
    wsOnly: true,
    connected: true,
    ready: true,
    lastEventAt: NOW - 1000,
    eventCount60s: 5,
    lastPongAt: 0,
    lastPongLatencyMs: null,
    now: NOW,
    ...overrides,
  }
}

describe('computeBeaconView', () => {
  it('returns gray (parallel mode) when wsOnly is false', () => {
    const view = computeBeaconView(beaconInput({
      wsOnly: false,
    }))
    expect(view.state).toBe('gray')
    expect(view.label).toBe('WS+SSE (legacy)')
  })

  it('returns red when wsOnly and the socket is not connected', () => {
    const view = computeBeaconView(beaconInput({
      connected: false,
      ready: false,
    }))
    expect(view.state).toBe('red')
    expect(view.label).toContain('disconnected')
  })

  it('returns red when wsOnly, socket connected but handshake not ready', () => {
    const view = computeBeaconView(beaconInput({
      ready: false,
    }))
    expect(view.state).toBe('red')
  })

  it('returns yellow when wsOnly, ready, but no event has ever arrived', () => {
    const view = computeBeaconView(beaconInput({
      lastEventAt: 0,
      eventCount60s: 0,
    }))
    expect(view.state).toBe('yellow')
    expect(view.label).toContain('silent')
  })

  it('returns yellow when wsOnly, ready, but the last event is older than the silent threshold', () => {
    const view = computeBeaconView(beaconInput({
      lastEventAt: NOW - 60_000,
      eventCount60s: 0,
    }))
    expect(view.state).toBe('yellow')
  })

  it('returns green when route events are quiet but heartbeat pong is fresh', () => {
    const view = computeBeaconView(beaconInput({
      lastEventAt: 0,
      eventCount60s: 0,
      lastPongAt: NOW - 2_000,
      lastPongLatencyMs: 41,
    }))
    expect(view.state).toBe('green')
    expect(view.label).toContain('heartbeat')
    expect(view.label).toContain('41ms')
  })

  it('returns green when wsOnly, ready, and an event arrived within the threshold', () => {
    const view = computeBeaconView(beaconInput({
      lastEventAt: NOW - 5_000,
      eventCount60s: 12,
    }))
    expect(view.state).toBe('green')
    expect(view.label).toContain('12 events / 60s')
  })

  it('uses computed silentMs in the title for diagnostic display', () => {
    const view = computeBeaconView(beaconInput({
      lastEventAt: NOW - 7_500,
      eventCount60s: 3,
    }))
    expect(view.title).toContain('7s ago')
  })
})
