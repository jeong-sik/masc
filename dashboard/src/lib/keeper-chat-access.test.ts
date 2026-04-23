import { describe, expect, it } from 'vitest'
import type { DashboardShellAuthSummary } from '../types'
import { keeperDirectChatAccess } from './keeper-chat-access'

function makeSummary(
  overrides: Partial<DashboardShellAuthSummary> = {},
): DashboardShellAuthSummary {
  return {
    enabled: true,
    require_token: false,
    default_role: 'reader',
    token_present: false,
    token_valid: false,
    token_agent: null,
    requested_agent: null,
    effective_agent: 'dashboard',
    effective_role: 'reader',
    auth_error_code: null,
    auth_error_detail: null,
    can_keeper_msg: false,
    keeper_msg_error: null,
    ...overrides,
  }
}

describe('keeperDirectChatAccess', () => {
  it('allows access when summary is null', () => {
    expect(keeperDirectChatAccess(null)).toEqual({ blocked: false, message: null })
  })

  it('allows access when keeper messaging is authorized', () => {
    const result = keeperDirectChatAccess(
      makeSummary({ can_keeper_msg: true }),
    )

    expect(result).toEqual({ blocked: false, message: null })
  })

  it('builds a default denial message with role context', () => {
    const result = keeperDirectChatAccess(
      makeSummary({
        effective_agent: 'alice',
        effective_role: 'worker',
        token_present: true,
      }),
    )

    expect(result.blocked).toBe(true)
    expect(result.message).toContain('@alice는 masc_keeper_msg 권한이 없습니다.')
    expect(result.message).toContain('현재 역할은 worker입니다.')
    expect(result.message).toContain('프로젝트 기본 권한을 올린 뒤 다시 시도하세요.')
    expect(result.message).not.toContain('Bearer token이 없어')
    expect(result.message).not.toContain('public read fallback')
  })

  it('includes the require-token hint when the bearer token is missing', () => {
    const result = keeperDirectChatAccess(
      makeSummary({
        effective_agent: 'bob',
        effective_role: 'worker',
        default_role: 'worker',
        require_token: true,
        token_present: false,
      }),
    )

    expect(result.blocked).toBe(true)
    expect(result.message).toContain('Bearer token이 없어 direct keeper chat이 차단됩니다.')
  })

  it('includes the public-read fallback hint for reader sessions without a token', () => {
    const result = keeperDirectChatAccess(
      makeSummary({
        effective_agent: 'carol',
        effective_role: 'reader',
        require_token: false,
        token_present: false,
      }),
    )

    expect(result.blocked).toBe(true)
    expect(result.message).toContain('현재 public read fallback으로 동작 중입니다.')
  })

  it('sanitizes noisy keeper_msg_error values', () => {
    const result = keeperDirectChatAccess(
      makeSummary({
        keeper_msg_error: '   !!!   에러 메시지 상세 설명 ',
        token_present: true,
      }),
    )

    expect(result.blocked).toBe(true)
    expect(result.message).toContain('에러 메시지 상세 설명')
    expect(result.message).not.toContain('!!!')
  })
})
