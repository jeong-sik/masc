import { describe, it, expect, beforeEach } from 'vitest'
import {
  recordHeartbeat,
  getHeartbeatHistory,
  resetHeartbeatHistory,
  rollingUptimeSeries,
  HEARTBEAT_MAX_SAMPLES,
  type HeartbeatState,
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

describe('rollingUptimeSeries (pure)', () => {
  it('empty history → empty series', () => {
    expect(rollingUptimeSeries([], 5)).toEqual([])
  })

  it('shorter than window → empty series (no partial trailing points)', () => {
    const h: HeartbeatState[] = ['up', 'up', 'up']
    expect(rollingUptimeSeries(h, 5)).toEqual([])
  })

  it('exact window of all up → single 100% point', () => {
    const h: HeartbeatState[] = ['up', 'up', 'up', 'up', 'up']
    expect(rollingUptimeSeries(h, 5)).toEqual([100])
  })

  it('sliding window shifts by one sample at a time', () => {
    // history: U U U U D U U U U U — length 10, window 5 → 6 points
    // i=0 [U U U U D] 4/5 = 80, i=1 [U U U D U] 80, i=2 [U U D U U] 80,
    // i=3 [U D U U U] 80, i=4 [D U U U U] 80, i=5 [U U U U U] 100.
    const h: HeartbeatState[] = ['up','up','up','up','down','up','up','up','up','up']
    const s = rollingUptimeSeries(h, 5)
    expect(s.length).toBe(6)
    expect(s[0]).toBe(80)
    expect(s[4]).toBe(80)
    // Down sample slides off the window → recovery to 100.
    expect(s[5]).toBe(100)
  })

  it('unknown-only window inherits previous value (line stays continuous)', () => {
    // U U U U U  ?  ?  ?  ?  ?  (window 5 → 6 points)
    // First window all-up → 100, then windows slide into more unknowns.
    // Last window [?,?,?,?,?] → observed=0 → inherit last seen = 100.
    const h: HeartbeatState[] = [
      'up','up','up','up','up',
      'unknown','unknown','unknown','unknown','unknown',
    ]
    const s = rollingUptimeSeries(h, 5)
    expect(s[s.length - 1]).toBe(100)
  })

  it('zero/negative window size → empty (no divide-by-zero)', () => {
    const h: HeartbeatState[] = ['up', 'down', 'up']
    expect(rollingUptimeSeries(h, 0)).toEqual([])
    expect(rollingUptimeSeries(h, -3)).toEqual([])
  })
})
