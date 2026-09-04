import { describe, it, expect } from 'vitest'
import {
  keeperPriority,
  isOfflineStatus,
  parseHarnessVerdict,
  verdictSummaryText,
  verdictToneClass,
  railStatusMessage,
} from './keeper-classifiers'
import type { KeeperPriority } from './keeper-classifiers'

describe('keeperPriority', () => {
  it.each(['active', 'running', 'busy', 'listening', 'claimed', 'in_progress'] as const)
  ('returns 1 for active status: %s', (status) => {
    expect(keeperPriority(status)).toBe<KeeperPriority>(1)
  })

  it.each(['offline', 'inactive', 'stopped'] as const)
  ('returns 3 for terminal status: %s', (status) => {
    expect(keeperPriority(status)).toBe<KeeperPriority>(3)
  })

  it('returns 2 for unknown/intermediate status (including crashed)', () => {
    expect(keeperPriority('idle')).toBe<KeeperPriority>(2)
    expect(keeperPriority('paused')).toBe<KeeperPriority>(2)
    expect(keeperPriority('crashed')).toBe<KeeperPriority>(2)
    expect(keeperPriority('')).toBe<KeeperPriority>(2)
    expect(keeperPriority('something_new')).toBe<KeeperPriority>(2)
    // Trajectory content types are NOT keeper statuses — they map to
    // intermediate priority (2), not active (1).
    expect(keeperPriority('thinking')).toBe<KeeperPriority>(2)
    expect(keeperPriority('tool_use')).toBe<KeeperPriority>(2)
  })
})

describe('isOfflineStatus', () => {
  it.each(['offline', 'inactive', 'crashed', 'unbooted', 'stopped'])
  ('returns true for %s', (status) => {
    expect(isOfflineStatus(status)).toBe(true)
  })

  it.each(['active', 'running', 'idle', 'paused', ''])
  ('returns false for %s', (status) => {
    expect(isOfflineStatus(status)).toBe(false)
  })
})

describe('parseHarnessVerdict', () => {
  // 생산자는 lib/eval_calibration.ml:42 의 verdict_to_string 하나뿐이고,
  // Approve | Reject of string 을 내보낸다.
  it('생산자가 내보내는 모양을 그대로 읽는다', () => {
    expect(parseHarnessVerdict('approve')).toEqual({ kind: 'approve', reason: null })
    expect(parseHarnessVerdict('approve:good code')).toEqual({ kind: 'approve', reason: 'good code' })
    expect(parseHarnessVerdict('reject')).toEqual({ kind: 'reject', reason: null })
    expect(parseHarnessVerdict('reject:bad code')).toEqual({ kind: 'reject', reason: 'bad code' })
  })

  it('사유에 콜론이 들어가도 잘리지 않는다', () => {
    expect(parseHarnessVerdict('approve:a:b')).toEqual({ kind: 'approve', reason: 'a:b' })
    expect(parseHarnessVerdict('reject:a:b')).toEqual({ kind: 'reject', reason: 'a:b' })
  })

  it('빈 사유는 없는 사유다', () => {
    expect(parseHarnessVerdict('approve:')).toEqual({ kind: 'approve', reason: null })
    expect(parseHarnessVerdict('approve:   ')).toEqual({ kind: 'approve', reason: null })
    expect(parseHarnessVerdict('reject:')).toEqual({ kind: 'reject', reason: null })
    expect(parseHarnessVerdict('reject:   ')).toEqual({ kind: 'reject', reason: null })
  })

  // 접두사 매칭이던 시절에는 이 둘이 approve 로 읽혔다. 생산자는 만들 수 없는
  // 문자열이므로, 승인으로 오독하는 대신 모르는 값이라고 말한다.
  it('생산자가 만들 수 없는 문자열은 승인이 아니다', () => {
    expect(parseHarnessVerdict('approvex')).toEqual({ kind: 'unknown', raw: 'approvex' })
    expect(parseHarnessVerdict('approve_with_comments'))
      .toEqual({ kind: 'unknown', raw: 'approve_with_comments' })
    expect(parseHarnessVerdict('pending')).toEqual({ kind: 'unknown', raw: 'pending' })
  })
})

describe('verdictSummaryText', () => {
  it('승인 사유가 있으면 사유를, 없으면 approve를 보여준다', () => {
    expect(verdictSummaryText('approve:good code')).toBe('good code')
    expect(verdictSummaryText('approve')).toBe('approve')
  })

  it('거절 사유를 보여준다', () => {
    expect(verdictSummaryText('reject:bad code')).toBe('bad code')
  })

  // 예전에는 콜론 없는 reject 가 startsWith('reject:') 를 통과하지 못해
  // 사유 자리에 "reject" 라는 단어가 그대로 찍혔다.
  it('사유 없는 거절을 사유처럼 보여주지 않는다', () => {
    expect(verdictSummaryText('reject')).toBe('(no reject reason)')
    expect(verdictSummaryText('reject:')).toBe('(no reject reason)')
    expect(verdictSummaryText('reject:  ')).toBe('(no reject reason)')
  })

  it('승인은 그대로 승인이라고 쓴다', () => {
    expect(verdictSummaryText('approve')).toBe('approve')
  })

  it('모르는 값은 원문을 보여준다', () => {
    expect(verdictSummaryText('pending')).toBe('pending')
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
