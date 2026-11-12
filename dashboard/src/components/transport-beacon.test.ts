import { describe, expect, it } from 'vitest'
import { computeBeaconView } from './transport-beacon'

const NOW = 1_000_000
const input = { connected: true, ready: true, lastEventAt: 0, eventCount60s: 0,
  lastActivityAt: NOW - 2_000, idleTimeoutMs: 90_000, now: NOW }

describe('SSE transport beacon', () => {
  it('shows a quiet stream as live when server heartbeat bytes arrive', () => {
    expect(computeBeaconView(input).state).toBe('green')
  })
  it('uses the advertised idle deadline instead of inventing heartbeat traffic', () => {
    expect(computeBeaconView({ ...input, idleTimeoutMs: 1_000 }).state).toBe('yellow')
  })
  it('requires an admitted connection', () => {
    expect(computeBeaconView({ ...input, connected: false, ready: false }).state).toBe('red')
    expect(computeBeaconView({ ...input, ready: false }).state).toBe('yellow')
  })
})
