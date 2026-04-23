import type { DashboardShellAuthSummary } from '../types'

export type DashboardAuthRole = 'reader' | 'worker' | 'admin'

export interface DashboardAuthAccess {
  allowed: boolean
  required_role: DashboardAuthRole
  effective_role: DashboardAuthRole | null
  reason: string | null
}

const ROLE_ORDER: Record<DashboardAuthRole, number> = {
  reader: 0,
  worker: 1,
  admin: 2,
}

function compactWhitespace(value: string): string {
  return value.replace(/\s+/g, ' ').trim()
}

function cleanErrorMessage(value: string | null | undefined): string | null {
  if (!value) return null
  return value.replace(/^[^\w가-힣@]+/u, '').trim() || null
}

function asRole(value: string | null | undefined): DashboardAuthRole | null {
  if (value === 'reader' || value === 'worker' || value === 'admin') return value
  return null
}

function authErrorReason(summary: DashboardShellAuthSummary): string | null {
  const requestedActor = summary.requested_agent ?? 'dashboard'
  const tokenAgent = summary.token_agent ? `@${summary.token_agent}` : null
  const detail = cleanErrorMessage(summary.auth_error_detail ?? summary.keeper_msg_error)
  switch (summary.auth_error_code) {
    case 'missing_token':
      return detail ?? 'Bearer token이 필요합니다.'
    case 'invalid_token':
      return detail ?? 'Bearer token을 검증하지 못했습니다.'
    case 'token_expired':
      return detail ?? 'Bearer token이 만료되었습니다.'
    case 'actor_mismatch':
      return detail ?? `현재 actor @${requestedActor}와 토큰 소유자 ${tokenAgent ?? 'unknown'}가 일치하지 않습니다.`
    case 'same_origin_blocked':
      return detail ?? '동일 출처가 아닌 브라우저 요청은 Bearer token이 필요합니다.'
    case 'insufficient_role':
      return detail ?? '현재 세션 역할로는 이 작업을 수행할 수 없습니다.'
    case 'unknown':
      return detail ?? '인증 상태를 확인해야 합니다.'
    default:
      return detail
  }
}

export function dashboardAuthAccess(
  summary: DashboardShellAuthSummary | null | undefined,
  requiredRole: DashboardAuthRole = 'worker',
): DashboardAuthAccess {
  if (!summary) {
    return {
      allowed: false,
      required_role: requiredRole,
      effective_role: null,
      reason: '인증 상태 확인 중입니다.',
    }
  }

  const effectiveRole = asRole(summary.effective_role ?? summary.default_role)
  const roleInsufficient =
    effectiveRole == null
    || ROLE_ORDER[effectiveRole] < ROLE_ORDER[requiredRole]

  const explicitReason = authErrorReason(summary)
  const roleReason = roleInsufficient
    ? compactWhitespace(
        `현재 역할은 ${effectiveRole ?? 'unknown'}입니다. ${requiredRole} 권한이 필요합니다.`,
      )
    : null

  return {
    allowed: explicitReason == null && !roleInsufficient,
    required_role: requiredRole,
    effective_role: effectiveRole,
    reason: explicitReason ?? roleReason,
  }
}
