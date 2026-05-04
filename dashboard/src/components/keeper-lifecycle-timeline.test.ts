// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import {
  isLivenessRecovery,
  toneForEvent,
  type EventTone,
} from './keeper-lifecycle-timeline'
import {
  parseKeeperLifecycleResponse,
} from '../api/keeper'
import type { KeeperLifecycleEvent } from '../api/keeper'

function makeEvent(overrides: Partial<KeeperLifecycleEvent> = {}): KeeperLifecycleEvent {
  return {
    ts: 1700000000,
    event: 'started',
    phase: 'running',
    detail: '',
    ...overrides,
  }
}

describe('toneForEvent', () => {
  it('returns ok for started', () => {
    expect(toneForEvent('started')).toBe<EventTone>('ok')
  })
  it('returns ok for reconciled', () => {
    expect(toneForEvent('reconciled')).toBe<EventTone>('ok')
  })
  it('returns ok for auto_resumed', () => {
    expect(toneForEvent('auto_resumed')).toBe<EventTone>('ok')
  })
  it('returns info for restarted', () => {
    expect(toneForEvent('restarted')).toBe<EventTone>('info')
  })
  it('returns err for dead', () => {
    expect(toneForEvent('dead')).toBe<EventTone>('err')
  })
  it('returns err for crashed', () => {
    expect(toneForEvent('crashed')).toBe<EventTone>('err')
  })
  it('returns warn for dead_cleaned', () => {
    expect(toneForEvent('dead_cleaned')).toBe<EventTone>('warn')
  })
  it('returns warn for self_preservation', () => {
    expect(toneForEvent('self_preservation')).toBe<EventTone>('warn')
  })
  it('returns neutral for stopped', () => {
    expect(toneForEvent('stopped')).toBe<EventTone>('neutral')
  })
  it('returns neutral for unknown events', () => {
    expect(toneForEvent('some_future_event')).toBe<EventTone>('neutral')
  })
})

describe('isLivenessRecovery', () => {
  it('returns false for regular restarted event', () => {
    const ev = makeEvent({ event: 'restarted', detail: 'supervised' })
    expect(isLivenessRecovery(ev)).toBe(false)
  })
  it('returns true for restarted event with liveness recovery detail', () => {
    const ev = makeEvent({ event: 'restarted', detail: 'liveness recovery attempt 1' })
    expect(isLivenessRecovery(ev)).toBe(true)
  })
  it('returns false for non-restarted event even with matching detail', () => {
    const ev = makeEvent({ event: 'started', detail: 'liveness recovery attempt 1' })
    expect(isLivenessRecovery(ev)).toBe(false)
  })
  it('returns false for started event', () => {
    const ev = makeEvent({ event: 'started', detail: 'supervised' })
    expect(isLivenessRecovery(ev)).toBe(false)
  })
})

describe('parseKeeperLifecycleResponse', () => {
  it('parses a valid response', () => {
    const raw = {
      keeper: 'test-keeper',
      count: 2,
      events: [
        { ts: 1700000001, event: 'started', phase: 'running', detail: 'supervised' },
        { ts: 1700000000, event: 'restarted', phase: 'running', detail: 'liveness recovery attempt 1' },
      ],
    }
    const result = parseKeeperLifecycleResponse(raw)
    expect(result.keeper).toBe('test-keeper')
    expect(result.count).toBe(2)
    expect(result.events).toHaveLength(2)
    const ev0 = result.events[0]!
    const ev1 = result.events[1]!
    expect(ev0.event).toBe('started')
    expect(ev1.event).toBe('restarted')
    expect(ev1.detail).toBe('liveness recovery attempt 1')
  })

  it('handles empty events array', () => {
    const raw = { keeper: 'k', count: 0, events: [] }
    const result = parseKeeperLifecycleResponse(raw)
    expect(result.events).toHaveLength(0)
    expect(result.count).toBe(0)
  })

  it('tolerates null phase', () => {
    const raw = {
      keeper: 'k',
      count: 1,
      events: [{ ts: 1700000001, event: 'dead_cleaned', phase: null, detail: 'ttl_expired' }],
    }
    const result = parseKeeperLifecycleResponse(raw)
    expect(result.events[0]!.phase).toBeNull()
  })

  it('tolerates missing optional fields with defaults', () => {
    const raw = {
      keeper: '',
      events: [{}],
    }
    const result = parseKeeperLifecycleResponse(raw)
    const ev = result.events[0]!
    expect(result.keeper).toBe('')
    expect(ev.ts).toBe(0)
    expect(ev.event).toBe('')
    expect(ev.phase).toBeNull()
    expect(ev.detail).toBe('')
  })

  it('throws for non-record input', () => {
    expect(() => parseKeeperLifecycleResponse(null)).toThrow()
    expect(() => parseKeeperLifecycleResponse('string')).toThrow()
  })
})
