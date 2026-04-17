import { describe, it, expect, beforeEach } from 'vitest'
import {
  recordHeartbeat,
  getHeartbeatHistory,
  resetHeartbeatHistory,
  HEARTBEAT_MAX_SAMPLES,
} from './heartbeat-history'

describe('heartbeat-history store', () => {
  beforeEach(() => { resetHeartbeatHistory() })

  it('returns [] for an unknown connector id', () => {
    expect(getHeartbeatHistory('never-seen')).toEqual([])
  })

  it('records a single sample', () => {
    recordHeartbeat('discord', 'up')
    expect(getHeartbeatHistory('discord')).toEqual(['up'])
  })

  it('appends samples in order (oldest first, newest last)', () => {
    recordHeartbeat('discord', 'up')
    recordHeartbeat('discord', 'down')
    recordHeartbeat('discord', 'up')
    expect(getHeartbeatHistory('discord')).toEqual(['up', 'down', 'up'])
  })

  it('keeps separate histories per connector id', () => {
    recordHeartbeat('discord', 'up')
    recordHeartbeat('slack', 'down')
    expect(getHeartbeatHistory('discord')).toEqual(['up'])
    expect(getHeartbeatHistory('slack')).toEqual(['down'])
  })

  it('ring-buffers at HEARTBEAT_MAX_SAMPLES (oldest evicted)', () => {
    // Fill beyond the cap.
    for (let i = 0; i < HEARTBEAT_MAX_SAMPLES + 3; i++) {
      recordHeartbeat('discord', i % 2 === 0 ? 'up' : 'down')
    }
    const h = getHeartbeatHistory('discord')
    expect(h.length).toBe(HEARTBEAT_MAX_SAMPLES)
    // The 3 oldest were evicted — the most recent sample (index N+2)
    // is still the tail.
    const expectedLastState = (HEARTBEAT_MAX_SAMPLES + 2) % 2 === 0 ? 'up' : 'down'
    expect(h[h.length - 1]).toBe(expectedLastState)
  })

  it('resetHeartbeatHistory clears everything', () => {
    recordHeartbeat('discord', 'up')
    recordHeartbeat('slack', 'down')
    resetHeartbeatHistory()
    expect(getHeartbeatHistory('discord')).toEqual([])
    expect(getHeartbeatHistory('slack')).toEqual([])
  })
})
