import { describe, it, expect } from 'vitest'
import {
  keeperPriority,
  isOfflineStatus,
  isAttentionCodeSatisfied,
  classifyCrashReasonLib,
  isApproveVerdict,
  verdictWithoutRejectPrefix,
  verdictToneClass,
  railStatusMessage,
} from './keeper-classifiers'
import type { KeeperPriority, LibCrashCategory } from './keeper-classifiers'

describe('keeperPriority', () => {
  it.each(['active', 'running', 'thinking', 'tool_use', 'claimed', 'in_progress'] as const)
  ('returns 1 for active status: %s', (status) => {
    expect(keeperPriority(status)).toBe<KeeperPriority>(1)
  })

  it.each(['offline', 'inactive', 'stopped', 'dead'] as const)
  ('returns 3 for terminal status: %s', (status) => {
    expect(keeperPriority(status)).toBe<KeeperPriority>(3)
  })

  it('returns 2 for unknown/intermediate status (including crashed)', () => {
    expect(keeperPriority('idle')).toBe<KeeperPriority>(2)
    expect(keeperPriority('paused')).toBe<KeeperPriority>(2)
    expect(keeperPriority('crashed')).toBe<KeeperPriority>(2)
    expect(keeperPriority('')).toBe<KeeperPriority>(2)
    expect(keeperPriority('something_new')).toBe<KeeperPriority>(2)
  })
})

describe('isOfflineStatus', () => {
  it.each(['offline', 'inactive', 'dead', 'crashed'])
  ('returns true for %s', (status) => {
    expect(isOfflineStatus(status)).toBe(true)
  })

  it.each(['active', 'running', 'idle', 'paused', ''])
  ('returns false for %s', (status) => {
    expect(isOfflineStatus(status)).toBe(false)
  })
})

describe('isAttentionCodeSatisfied', () => {
  it('returns true for "satisfied" prefix', () => {
    expect(isAttentionCodeSatisfied('satisfied')).toBe(true)
    expect(isAttentionCodeSatisfied('satisfied_with_caveats')).toBe(true)
  })

  it('returns false for non-satisfied codes', () => {
    expect(isAttentionCodeSatisfied('violated')).toBe(false)
    expect(isAttentionCodeSatisfied('unknown')).toBe(false)
    expect(isAttentionCodeSatisfied('')).toBe(false)
  })
})

describe('classifyCrashReasonLib', () => {
  it.each([
    ['heartbeat', 'heartbeat'],
    ['heartbeat_timeout', 'heartbeat'],
    ['HEARTBEAT_TIMEOUT', 'heartbeat'],
    ['turn', 'turn'],
    ['turn_timeout', 'turn'],
    ['fiber', 'fiber'],
    ['fiber_cancel', 'fiber'],
    ['exception', 'exception'],
    ['exception_io', 'exception'],
  ] as const)
  ('classifies "%s" as %s', (input, expected) => {
    expect(classifyCrashReasonLib(input)).toBe<LibCrashCategory>(expected)
  })

  it('returns unknown for unrecognized reason', () => {
    expect(classifyCrashReasonLib('random_error')).toBe<LibCrashCategory>('unknown')
    expect(classifyCrashReasonLib('')).toBe<LibCrashCategory>('unknown')
  })
})

describe('isApproveVerdict', () => {
  it('returns true for approve variants', () => {
    expect(isApproveVerdict('approve')).toBe(true)
    expect(isApproveVerdict('approve_with_comments')).toBe(true)
  })

  it('returns false for non-approve verdicts', () => {
    expect(isApproveVerdict('reject:reason')).toBe(false)
    expect(isApproveVerdict('pending')).toBe(false)
  })
})

describe('verdictWithoutRejectPrefix', () => {
  it('strips reject: prefix', () => {
    expect(verdictWithoutRejectPrefix('reject:bad code')).toBe('bad code')
  })

  it('returns raw verdict if no prefix', () => {
    expect(verdictWithoutRejectPrefix('approve')).toBe('approve')
  })

  it('handles empty reject reason', () => {
    expect(verdictWithoutRejectPrefix('reject:')).toBe('(no reject reason)')
    expect(verdictWithoutRejectPrefix('reject:  ')).toBe('(no reject reason)')
  })
})

describe('verdictToneClass', () => {
  it('returns ok class for approve', () => {
    expect(verdictToneClass('approve')).toContain('ok')
  })

  it('returns err class for non-approve', () => {
    expect(verdictToneClass('reject:x')).toContain('err')
  })
})

describe('railStatusMessage', () => {
  it('returns warning message', () => {
    expect(railStatusMessage(['warning'])).toBe('감시 채널에 주의가 필요합니다.')
  })

  it('returns stale message', () => {
    expect(railStatusMessage(['stale'])).toBe('신호는 있지만 최신성이 떨어집니다.')
  })

  it('prioritizes warning over stale', () => {
    expect(railStatusMessage(['stale', 'warning'])).toBe('감시 채널에 주의가 필요합니다.')
  })

  it('returns null for no actionable status', () => {
    expect(railStatusMessage(['idle', 'ok'])).toBeNull()
    expect(railStatusMessage([])).toBeNull()
  })
})
