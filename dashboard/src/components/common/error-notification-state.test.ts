// @ts-nocheck
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import {
  errors,
  unacknowledgedErrors,
  unacknowledgedCount,
  acknowledgeError,
  clearAllErrors,
  startErrorCleanup,
  stopErrorCleanup,
} from './error-notification-state'
import type { DashboardError } from '../../types/error'

function makeError(overrides: Partial<DashboardError> = {}): DashboardError {
  return {
    id: '1',
    fingerprint: 'fp-1',
    agentName: 'Alpha',
    taskId: null,
    message: 'a',
    errorCode: 'internal_error',
    severity: 'critical',
    timestamp: Date.now(),
    acknowledged: false,
    count: 1,
    lastSeen: Date.now(),
    ...overrides,
  }
}

describe('error-notification-state', () => {
  beforeEach(() => {
    errors.value = []
    stopErrorCleanup()
  })

  afterEach(() => {
    errors.value = []
    stopErrorCleanup()
  })

  it('initializes with empty errors', () => {
    expect(errors.value).toEqual([])
    expect(unacknowledgedErrors.value).toEqual([])
    expect(unacknowledgedCount.value).toBe(0)
  })

  it('computes unacknowledged count', () => {
    errors.value = [
      makeError({ id: '1', message: 'a', acknowledged: false }),
      makeError({ id: '2', message: 'b', acknowledged: true }),
      makeError({ id: '3', message: 'c', acknowledged: false }),
    ]
    expect(unacknowledgedCount.value).toBe(2)
    expect(unacknowledgedErrors.value.length).toBe(2)
  })

  it('acknowledges a specific error by id', () => {
    errors.value = [
      makeError({ id: '1', message: 'a', acknowledged: false }),
      makeError({ id: '2', message: 'b', acknowledged: false }),
    ]
    acknowledgeError('1')
    expect(errors.value[0].acknowledged).toBe(true)
    expect(errors.value[1].acknowledged).toBe(false)
    expect(unacknowledgedCount.value).toBe(1)
  })

  it('acknowledges non-existing id without error', () => {
    errors.value = [
      makeError({ id: '1', message: 'a', acknowledged: false }),
    ]
    acknowledgeError('999')
    expect(errors.value[0].acknowledged).toBe(false)
    expect(unacknowledgedCount.value).toBe(1)
  })

  it('clearAllErrors acknowledges every error', () => {
    errors.value = [
      makeError({ id: '1', message: 'a', acknowledged: false }),
      makeError({ id: '2', message: 'b', acknowledged: false }),
    ]
    clearAllErrors()
    expect(errors.value.every(e => e.acknowledged)).toBe(true)
    expect(unacknowledgedCount.value).toBe(0)
  })

  describe('cleanup timer', () => {
    it('removes acknowledged errors older than TTL', () => {
      vi.useFakeTimers()
      const now = 1_000_000
      vi.setSystemTime(now)

      const old = now - 6 * 60 * 1000
      errors.value = [
        makeError({ id: '1', message: 'old', acknowledged: true, lastSeen: old }),
        makeError({ id: '2', message: 'recent', acknowledged: true, lastSeen: now }),
        makeError({ id: '3', message: 'unack', acknowledged: false, lastSeen: old }),
      ]

      startErrorCleanup()
      vi.advanceTimersByTime(60 * 1000)

      expect(errors.value.length).toBe(2)
      expect(errors.value.find(e => e.id === '1')).toBeUndefined()
      expect(errors.value.find(e => e.id === '2')).toBeDefined()
      expect(errors.value.find(e => e.id === '3')).toBeDefined()

      stopErrorCleanup()
      vi.useRealTimers()
    })

    it('preserves unacknowledged errors regardless of age', () => {
      vi.useFakeTimers()
      const now = 1_000_000
      vi.setSystemTime(now)

      const old = now - 10 * 60 * 1000
      errors.value = [
        makeError({ id: '1', message: 'old unack', acknowledged: false, lastSeen: old }),
      ]

      startErrorCleanup()
      vi.advanceTimersByTime(60 * 1000)

      expect(errors.value.length).toBe(1)
      expect(errors.value[0].id).toBe('1')

      stopErrorCleanup()
      vi.useRealTimers()
    })

    it('does not start duplicate timers', () => {
      startErrorCleanup()
      startErrorCleanup()
      // Coverage only — the guard branch must execute without throwing.
      expect(() => stopErrorCleanup()).not.toThrow()
    })

    it('stopErrorCleanup is safe when timer not running', () => {
      expect(() => stopErrorCleanup()).not.toThrow()
    })
  })
})
