import { describe, it, expect } from 'vitest'
import { classifyErrorCode, severityForCode } from './error'
import type { ErrorCode, ErrorSeverity } from './error'

describe('classifyErrorCode', () => {
  it.each([
    ['Task not found: task-001', 'not_found'],
    ['Resource does not exist', 'not_found'],
    ['Connection timed out after 30s', 'timeout'],
    ['Deadline exceeded', 'timeout'],
    ['Unauthorized: invalid token', 'auth_required'],
    ['Authentication failed', 'auth_required'],
    ['Credential expired', 'auth_required'],
    ['Permission denied for resource', 'permission_denied'],
    ['Forbidden: access denied', 'permission_denied'],
    ['Task already claimed', 'conflict'],
    ['Already exists', 'conflict'],
    ['Rate limited: too many requests', 'rate_limited'],
    ['Missing parameter: task_id', 'validation_error'],
    ['Invalid input format', 'validation_error'],
    ['Not implemented yet', 'not_implemented'],
    ['Room not joined', 'precondition_failed'],
    ['Internal server error', 'internal_error'],
    ['Unexpected failure', 'internal_error'],
  ] satisfies Array<[string, ErrorCode]>)(
    'classifies "%s" as %s',
    (message, expected) => {
      expect(classifyErrorCode(message)).toBe(expected)
    },
  )

  it('returns unknown for unrecognized messages', () => {
    expect(classifyErrorCode('Something happened')).toBe('unknown')
    expect(classifyErrorCode('')).toBe('unknown')
  })
})

describe('severityForCode', () => {
  it.each([
    ['auth_required', 'critical'],
    ['permission_denied', 'critical'],
    ['internal_error', 'critical'],
    ['timeout', 'warning'],
    ['rate_limited', 'warning'],
    ['conflict', 'warning'],
    ['validation_error', 'warning'],
    ['unknown', 'warning'],
    ['not_found', 'info'],
    ['not_implemented', 'info'],
    ['precondition_failed', 'info'],
  ] satisfies Array<[ErrorCode, ErrorSeverity]>)(
    'severity of %s is %s',
    (code, expected) => {
      expect(severityForCode(code)).toBe(expected)
    },
  )
})
