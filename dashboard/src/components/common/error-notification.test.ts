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

describe('error-notification', () => {
  beforeEach(() => {
    _testResetErrors()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('creates a new error on first agent_failed event', () => {
    handleAgentFailed({
      agentName: 'keeper-1',
      error: 'Connection timeout',
    })

    expect(errors.value).toHaveLength(1)
    expect(errors.value[0]!.agentName).toBe('keeper-1')
    expect(errors.value[0]!.message).toBe('Connection timeout')
    expect(errors.value[0]!.count).toBe(1)
    expect(errors.value[0]!.acknowledged).toBe(false)
    expect(errors.value[0]!.errorCode).toBe('timeout')
    expect(errors.value[0]!.severity).toBe('warning')
    expect(unacknowledgedCount.value).toBe(1)
  })

  it('increments count for duplicate error within dedup window', () => {
    handleAgentFailed({ agentName: 'keeper-1', error: 'Connection timeout' })
    handleAgentFailed({ agentName: 'keeper-1', error: 'Connection timeout' })

    expect(errors.value).toHaveLength(1)
    expect(errors.value[0]!.count).toBe(2)
    expect(unacknowledgedCount.value).toBe(1)
  })

  it('creates separate error for different agent', () => {
    handleAgentFailed({ agentName: 'keeper-1', error: 'Connection timeout' })
    handleAgentFailed({ agentName: 'keeper-2', error: 'Connection timeout' })

    expect(errors.value).toHaveLength(2)
    expect(unacknowledgedCount.value).toBe(2)
  })

  it('creates separate error for different message', () => {
    handleAgentFailed({ agentName: 'keeper-1', error: 'Connection timeout' })
    handleAgentFailed({ agentName: 'keeper-1', error: 'Auth failed' })

    expect(errors.value).toHaveLength(2)
  })

  it('stores taskId when provided', () => {
    handleAgentFailed({ agentName: 'keeper-1', error: 'err', taskId: 'task-001' })

    expect(errors.value[0]!.taskId).toBe('task-001')
  })

  it('sets taskId to null when not provided', () => {
    handleAgentFailed({ agentName: 'keeper-1', error: 'err' })

    expect(errors.value[0]!.taskId).toBeNull()
  })

  describe('acknowledgeError', () => {
    it('marks an error as acknowledged', () => {
      handleAgentFailed({ agentName: 'keeper-1', error: 'err' })
      const id = errors.value[0]!.id

      acknowledgeError(id)

      expect(errors.value[0]!.acknowledged).toBe(true)
      expect(unacknowledgedCount.value).toBe(0)
    })

    it('does not affect other errors', () => {
      handleAgentFailed({ agentName: 'keeper-1', error: 'err1' })
      handleAgentFailed({ agentName: 'keeper-2', error: 'err2' })

      acknowledgeError(errors.value[0]!.id)

      expect(unacknowledgedCount.value).toBe(1)
      expect(unacknowledgedErrors.value[0]!.agentName).toBe('keeper-2')
    })
  })

  describe('clearAllErrors', () => {
    it('acknowledges all errors', () => {
      handleAgentFailed({ agentName: 'keeper-1', error: 'err1' })
      handleAgentFailed({ agentName: 'keeper-2', error: 'err2' })

      clearAllErrors()

      expect(unacknowledgedCount.value).toBe(0)
      expect(errors.value.every(e => e.acknowledged)).toBe(true)
    })
  })

  describe('dedup', () => {
    it('treats same error after dedup window as new occurrence', () => {
      handleAgentFailed({ agentName: 'keeper-1', error: 'err' })

      // Manually age the error past the dedup window
      const now = Date.now()
      errors.value = errors.value.map(e => ({
        ...e,
        lastSeen: now - 6 * 60 * 1000, // 6 minutes ago
      }))

      handleAgentFailed({ agentName: 'keeper-1', error: 'err' })

      // Should have been updated (not a new entry) but with fresh lastSeen
      expect(errors.value).toHaveLength(1)
      expect(errors.value[0]!.lastSeen).toBeGreaterThan(now - 1000)
    })
  })

  describe('fingerprint', () => {
    it('truncates long messages to 100 chars for fingerprint', () => {
      const longMessage = 'A'.repeat(200)
      handleAgentFailed({ agentName: 'agent', error: longMessage })
      handleAgentFailed({ agentName: 'agent', error: 'A'.repeat(200) })

      // Same fingerprint → dedup
      expect(errors.value).toHaveLength(1)
      expect(errors.value[0]!.count).toBe(2)
    })

    it('differentiates messages that differ after 100 chars', () => {
      const base = 'A'.repeat(99)
      handleAgentFailed({ agentName: 'agent', error: base + 'X' })
      handleAgentFailed({ agentName: 'agent', error: base + 'Y' })

      expect(errors.value).toHaveLength(2)
    })
  })

  describe('error classification', () => {
    it('classifies timeout errors', () => {
      handleAgentFailed({ agentName: 'k', error: 'Connection timed out after 30s' })
      expect(errors.value[0]!.errorCode).toBe('timeout')
      expect(errors.value[0]!.severity).toBe('warning')
    })

    it('classifies not_found errors as info', () => {
      handleAgentFailed({ agentName: 'k', error: 'Task not found: task-001' })
      expect(errors.value[0]!.errorCode).toBe('not_found')
      expect(errors.value[0]!.severity).toBe('info')
    })

    it('classifies auth errors as critical', () => {
      handleAgentFailed({ agentName: 'k', error: 'Unauthorized: invalid token' })
      expect(errors.value[0]!.errorCode).toBe('auth_required')
      expect(errors.value[0]!.severity).toBe('critical')
    })

    it('classifies internal errors as critical', () => {
      handleAgentFailed({ agentName: 'k', error: 'Unexpected internal failure' })
      expect(errors.value[0]!.errorCode).toBe('internal_error')
      expect(errors.value[0]!.severity).toBe('critical')
    })

    it('classifies unknown messages', () => {
      handleAgentFailed({ agentName: 'k', error: 'Something weird happened' })
      expect(errors.value[0]!.errorCode).toBe('unknown')
      expect(errors.value[0]!.severity).toBe('warning')
    })

    it('uses explicit errorCode when provided', () => {
      handleAgentFailed({ agentName: 'k', error: 'Something happened', errorCode: 'rate_limited' })
      expect(errors.value[0]!.errorCode).toBe('rate_limited')
      expect(errors.value[0]!.severity).toBe('warning')
    })

    it('explicit errorCode overrides message classification', () => {
      handleAgentFailed({ agentName: 'k', error: 'Connection timeout', errorCode: 'auth_required' })
      expect(errors.value[0]!.errorCode).toBe('auth_required')
      expect(errors.value[0]!.severity).toBe('critical')
    })
  })
})
