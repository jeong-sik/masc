import type { DashboardShellAuthSummary } from '../types'

interface KeeperDirectChatAccess {
  blocked: boolean
  message: string | null
}

function compactWhitespace(value: string): string {
  return value.replace(/\s+/g, ' ').trim()
}

function cleanErrorMessage(value: string | null | undefined): string | null {
  if (!value) return null
  return value.replace(/^[^\w가-힣@]+/u, '').trim() || null
}

export function keeperDirectChatAccess(
  summary: DashboardShellAuthSummary | null | undefined,
): KeeperDirectChatAccess {
  if (!summary || summary.can_keeper_msg) {
    return { blocked: false, message: null }
  }

  const actor = summary.effective_agent ?? summary.requested_agent ?? 'dashboard'
  const role = summary.effective_role ?? summary.default_role ?? null
  const reason = cleanErrorMessage(summary.keeper_msg_error)
    ?? `@${actor}는 masc_keeper_msg 권한이 없습니다.`
  const roleHint = role ? ` 현재 역할은 ${role}입니다.` : ''
  const tokenHint =
    summary.require_token && !summary.token_present
      ? ' Bearer token이 없어 direct keeper chat이 차단됩니다.'
      : !summary.require_token && !summary.token_present && role === 'reader'
        ? ' 현재 public read fallback으로 동작 중입니다.'
        : ''

  return {
    blocked: true,
    message: compactWhitespace(
      `직접 통신 비활성화: ${reason}.${roleHint}${tokenHint} worker/admin 권한 토큰을 사용하거나 프로젝트 기본 권한을 올린 뒤 다시 시도하세요.`,
    ),
  }
}
