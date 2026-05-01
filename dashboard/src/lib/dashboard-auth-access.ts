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
      return detail ?? 'Bearer token is required.'
    case 'invalid_token':
      return detail ?? 'Bearer token could not be verified.'
    case 'token_expired':
      return detail ?? 'Bearer token has expired.'
    case 'actor_mismatch':
      return detail ?? `Current actor @${requestedActor} does not match token owner ${tokenAgent ?? 'unknown'}.`
    case 'same_origin_blocked':
      return detail ?? 'Cross-origin browser requests require a Bearer token.'
    case 'insufficient_role':
      return detail ?? 'Current session role cannot perform this action.'
    case 'unknown':
      return detail ?? 'Auth status must be checked.'
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
      reason: 'Checking auth status.',
    }
  }

  const effectiveRole = asRole(summary.effective_role ?? summary.default_role)
  const roleInsufficient =
    effectiveRole == null
    || ROLE_ORDER[effectiveRole] < ROLE_ORDER[requiredRole]

  const explicitReason = authErrorReason(summary)
  const roleReason = roleInsufficient
    ? compactWhitespace(
        `Current role is ${effectiveRole ?? 'unknown'}; ${requiredRole} role is required.`,
      )
    : null

  return {
    allowed: explicitReason == null && !roleInsufficient,
    required_role: requiredRole,
    effective_role: effectiveRole,
    reason: explicitReason ?? roleReason,
  }
}
