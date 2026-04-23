import { describe, expect, it } from 'vitest'
import type { DashboardShellAuthSummary } from '../types'
import { dashboardAuthAccess } from './dashboard-auth-access'

function makeSummary(
  overrides: Partial<DashboardShellAuthSummary> = {},
): DashboardShellAuthSummary {
  return {
    enabled: true,
    require_token: true,
    default_role: 'worker',
    token_present: true,
    token_valid: true,
    token_agent: 'codex',
    requested_agent: 'codex',
    effective_agent: 'codex',
    effective_role: 'worker',
    auth_error_code: null,
    auth_error_detail: null,
    can_keeper_msg: true,
    keeper_msg_error: null,
    ...overrides,
  }
}

describe('dashboardAuthAccess', () => {
  it('blocks while auth truth is unknown', () => {
    expect(dashboardAuthAccess(null, 'worker')).toEqual({
      allowed: false,
      required_role: 'worker',
      effective_role: null,
      reason: '인증 상태 확인 중입니다.',
    })
  })

  it('allows worker mutations for validated worker sessions', () => {
    expect(dashboardAuthAccess(makeSummary(), 'worker')).toEqual({
      allowed: true,
      required_role: 'worker',
      effective_role: 'worker',
      reason: null,
    })
  })

  it('surfaces actor mismatch details', () => {
    const result = dashboardAuthAccess(
      makeSummary({
        token_valid: true,
        requested_agent: 'dashboard',
        effective_agent: 'dashboard',
        auth_error_code: 'actor_mismatch',
        auth_error_detail: 'Unauthorized: No credential found for dashboard (bearer token belongs to codex)',
        can_keeper_msg: false,
      }),
      'worker',
    )

    expect(result.allowed).toBe(false)
    expect(result.reason).toContain('No credential found for dashboard')
  })

  it('blocks reader sessions from worker mutations with a role hint', () => {
    const result = dashboardAuthAccess(
      makeSummary({
        require_token: false,
        token_present: false,
        token_valid: false,
        effective_role: 'reader',
      }),
      'worker',
    )

    expect(result.allowed).toBe(false)
    expect(result.reason).toContain('reader')
    expect(result.reason).toContain('worker')
  })
})
