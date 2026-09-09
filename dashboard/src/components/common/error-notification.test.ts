import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  handleAgentFailed,
  acknowledgeError,
  clearAllErrors,
  _testResetErrors,
  unacknowledgedCount,
  unacknowledgedErrors,
  errors,
} from './error-notification'

// Mock toast to avoid side effects
vi.mock('./toast', () => ({
  showToast: vi.fn(),
}))

type FailArgs = Parameters<typeof handleAgentFailed>[0]

// The wire always carries error_code, error_domain and error_retryable, so the
// handler requires all three. Tests name only the field under test.
function fail(
  overrides: Partial<FailArgs> & Pick<FailArgs, 'agentName' | 'error'>,
): void {
  handleAgentFailed({
    errorCode: 'exception',
    errorDomain: 'agent',
    errorRetryable: false,
    ...overrides,
  })
}

describe('error-notification', () => {
  beforeEach(() => {
    _testResetErrors()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('creates a new error on first agent_failed event', () => {
    fail({
      agentName: 'keeper-1',
      error: 'Connection timeout',
    })

    expect(errors.value).toHaveLength(1)
    expect(errors.value[0]!.agentName).toBe('keeper-1')
    expect(errors.value[0]!.message).toBe('Connection timeout')
    expect(errors.value[0]!.count).toBe(1)
    expect(errors.value[0]!.acknowledged).toBe(false)
    expect(errors.value[0]!.errorCode).toBe('exception')
    expect(errors.value[0]!.domain).toBe('agent')
    expect(errors.value[0]!.severity).toBe('critical')
    expect(unacknowledgedCount.value).toBe(1)
  })

  it('increments count for duplicate error within dedup window', () => {
    fail({ agentName: 'keeper-1', error: 'Connection timeout' })
    fail({ agentName: 'keeper-1', error: 'Connection timeout' })

    expect(errors.value).toHaveLength(1)
    expect(errors.value[0]!.count).toBe(2)
    expect(unacknowledgedCount.value).toBe(1)
  })

  it('creates separate error for different agent', () => {
    fail({ agentName: 'keeper-1', error: 'Connection timeout' })
    fail({ agentName: 'keeper-2', error: 'Connection timeout' })

    expect(errors.value).toHaveLength(2)
    expect(unacknowledgedCount.value).toBe(2)
  })

  it('creates separate error for different message', () => {
    fail({ agentName: 'keeper-1', error: 'Connection timeout' })
    fail({ agentName: 'keeper-1', error: 'Auth failed' })

    expect(errors.value).toHaveLength(2)
  })

  it('stores taskId when provided', () => {
    fail({ agentName: 'keeper-1', error: 'err', taskId: 'task-001' })

    expect(errors.value[0]!.taskId).toBe('task-001')
  })

  it('sets taskId to null when not provided', () => {
    fail({ agentName: 'keeper-1', error: 'err' })

    expect(errors.value[0]!.taskId).toBeNull()
  })

  describe('acknowledgeError', () => {
    it('marks an error as acknowledged', () => {
      fail({ agentName: 'keeper-1', error: 'err' })
      const id = errors.value[0]!.id

      acknowledgeError(id)

      expect(errors.value[0]!.acknowledged).toBe(true)
      expect(unacknowledgedCount.value).toBe(0)
    })

    it('does not affect other errors', () => {
      fail({ agentName: 'keeper-1', error: 'err1' })
      fail({ agentName: 'keeper-2', error: 'err2' })

      acknowledgeError(errors.value[0]!.id)

      expect(unacknowledgedCount.value).toBe(1)
      expect(unacknowledgedErrors.value[0]!.agentName).toBe('keeper-2')
    })
  })

  describe('clearAllErrors', () => {
    it('acknowledges all errors', () => {
      fail({ agentName: 'keeper-1', error: 'err1' })
      fail({ agentName: 'keeper-2', error: 'err2' })

      clearAllErrors()

      expect(unacknowledgedCount.value).toBe(0)
      expect(errors.value.every(e => e.acknowledged)).toBe(true)
    })
  })

  describe('dedup', () => {
    it('treats same error after dedup window as new occurrence', () => {
      fail({ agentName: 'keeper-1', error: 'err' })

      // Manually age the error past the dedup window
      const now = Date.now()
      errors.value = errors.value.map(e => ({
        ...e,
        lastSeen: now - 6 * 60 * 1000, // 6 minutes ago
      }))

      fail({ agentName: 'keeper-1', error: 'err' })

      // Should have been updated (not a new entry) but with fresh lastSeen
      expect(errors.value).toHaveLength(1)
      expect(errors.value[0]!.lastSeen).toBeGreaterThan(now - 1000)
    })
  })

  describe('fingerprint', () => {
    it('truncates long messages to 100 chars for fingerprint', () => {
      const longMessage = 'A'.repeat(200)
      fail({ agentName: 'agent', error: longMessage })
      fail({ agentName: 'agent', error: 'A'.repeat(200) })

      // Same fingerprint → dedup
      expect(errors.value).toHaveLength(1)
      expect(errors.value[0]!.count).toBe(2)
    })

    it('differentiates messages that differ after 100 chars', () => {
      const base = 'A'.repeat(99)
      fail({ agentName: 'agent', error: base + 'X' })
      fail({ agentName: 'agent', error: base + 'Y' })

      expect(errors.value).toHaveLength(2)
    })
  })

  describe('wire fields', () => {
    it('keeps the raw error_code verbatim', () => {
      fail({ agentName: 'k', error: 'boom', errorCode: 'stale_termination_storm' })
      expect(errors.value[0]!.errorCode).toBe('stale_termination_storm')
    })

    it('keeps a provider code that no closed vocabulary contains', () => {
      fail({ agentName: 'k', error: 'boom', errorCode: 'anthropic:overloaded_error' })
      expect(errors.value[0]!.errorCode).toBe('anthropic:overloaded_error')
    })

    it('parses a modelled domain', () => {
      fail({ agentName: 'k', error: 'boom', errorDomain: 'provider' })
      expect(errors.value[0]!.domain).toBe('provider')
    })

    it('leaves an unmodelled domain null and calls it critical', () => {
      fail({ agentName: 'k', error: 'boom', errorDomain: 'quantum', errorRetryable: true })
      expect(errors.value[0]!.domain).toBeNull()
      expect(errors.value[0]!.severity).toBe('critical')
    })

    it('takes severity from the retryable flag, not the message text', () => {
      fail({ agentName: 'k', error: 'Unauthorized: invalid token', errorRetryable: true })
      expect(errors.value[0]!.severity).toBe('warning')

      _testResetErrors()
      fail({ agentName: 'k', error: 'Unauthorized: invalid token', errorRetryable: false })
      expect(errors.value[0]!.severity).toBe('critical')
    })
  })
})
