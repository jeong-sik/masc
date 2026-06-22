// Shared humanization for the keeper `attention_reason` / `next_human_action`
// wire vocabularies. Extracted so every surface that shows these codes —
// the keeper detail alert strip and the overview attention queue — maps them
// through one closed-sum SSOT instead of rendering raw backend tokens.
//
// Closed as const + Record<…, string>. Adding a new label without extending
// the union, or removing a union arm, fails typecheck rather than silently
// producing a missing/extraneous Korean label. Backend variants that drift
// past the union surface via warnUnknownAttentionToken (dev console) and fall
// back to the raw token rather than slipping through unnoticed.

// One-time warn per (kind, token) so dev consoles surface backend variants
// that have no Korean label, without spamming on every render.
const warnedAttentionTokens = new Set<string>()
function warnUnknownAttentionToken(kind: 'attention_reason' | 'next_human_action', token: string) {
  const key = `${kind}|${token}`
  if (warnedAttentionTokens.has(key)) return
  warnedAttentionTokens.add(key)
  if (typeof console !== 'undefined') {
    console.warn(`[keeper-attention-labels] unknown ${kind}:`, token)
  }
}

// Backend emit sites for `attention_reason`:
//   - lib/keeper/keeper_status_bridge.ml:727-742 (six common reasons)
//   - lib/keeper_fd_pressure.ml:190 ('fd_pressure')
//   - lib/dashboard/dashboard_goals.ml:44 ('runtime_trust_snapshot_unavailable')
export const ATTENTION_REASONS = [
  'approval_pending',
  'continue_gate_required',
  'paused',
  'paused_blocked',
  'runtime_blocked',
  'provider_runtime_error',
  'social_model_fallback',
  'fd_pressure',
  'runtime_trust_snapshot_unavailable',
] as const
export type AttentionReason = typeof ATTENTION_REASONS[number]

const ATTENTION_REASON_LABELS: Record<AttentionReason, string> = {
  approval_pending: '승인 대기',
  continue_gate_required: '계속 진행 승인 필요',
  paused: '일시정지',
  paused_blocked: '일시정지 원인 확인 필요',
  runtime_blocked: '런타임 근거 확인 필요',
  provider_runtime_error: '런타임 호출 오류',
  social_model_fallback: '소셜 모델 폴백',
  fd_pressure: 'FD 임계치 초과',
  runtime_trust_snapshot_unavailable: '런타임 신뢰 스냅샷 없음',
}

export function canonicalAttentionReason(reason: string | null): string | null {
  if (reason === 'runtime_attempts_exhausted') return 'runtime_blocked'
  if (reason === 'provider_tool_capability_missing') return 'runtime_blocked'
  if (reason === 'completion_contract_violation') return 'runtime_blocked'
  if (reason === 'watchdog_stale_turn') return 'runtime_blocked'
  if (reason === 'fiber_unresolved') return 'runtime_blocked'
  return reason
}

export function isAttentionReason(s: string): s is AttentionReason {
  return (ATTENTION_REASONS as readonly string[]).includes(s)
}

export function attentionReasonLabel(reason: string | null, paused: boolean): string | null {
  const canonicalReason = canonicalAttentionReason(reason)
  if (!canonicalReason) return null
  if ((canonicalReason === 'paused' || canonicalReason === 'paused_blocked') && paused) return null
  if (isAttentionReason(canonicalReason)) return ATTENTION_REASON_LABELS[canonicalReason]
  warnUnknownAttentionToken('attention_reason', canonicalReason)
  return canonicalReason
}

// Backend emit sites for `next_human_action` (paired 1:1 with the
// corresponding `attention_reason`):
//   - lib/keeper/keeper_status_bridge.ml:727-742 (seven common actions)
//   - lib/keeper/keeper_turn_disposition.ml:63-70 (runtime-trust latest action)
//   - lib/keeper_fd_pressure.ml:191 ('restore_fd_headroom')
//   - lib/dashboard/dashboard_goals.ml:45 ('inspect_keeper_runtime_trust')
export const NEXT_HUMAN_ACTIONS = [
  'approve_or_reject_continue',
  'inspect_blocker_before_resume',
  'inspect_runtime_blocker',
  'inspect_latest_error',
  'inspect_provider_runtime_cause',
  'resolve_approval',
  'resume_or_review',
  'review_social_model',
  'restore_fd_headroom',
  'inspect_keeper_runtime_trust',
] as const
export type NextHumanAction = typeof NEXT_HUMAN_ACTIONS[number]

const NEXT_HUMAN_ACTION_LABELS: Record<NextHumanAction, string> = {
  approve_or_reject_continue: '계속 진행 승인 또는 거절',
  inspect_blocker_before_resume: '원인 확인 후 재개',
  inspect_runtime_blocker: '런타임 근거 확인',
  inspect_latest_error: '최근 오류 확인',
  inspect_provider_runtime_cause: 'Provider 런타임 원인 확인',
  resolve_approval: '승인 요청 처리',
  resume_or_review: '재개 또는 설정 검토',
  review_social_model: '소셜 모델 설정 검토',
  restore_fd_headroom: 'FD 여유 확보',
  inspect_keeper_runtime_trust: '런타임 신뢰 스냅샷 확인',
}

export function isNextHumanAction(s: string): s is NextHumanAction {
  return (NEXT_HUMAN_ACTIONS as readonly string[]).includes(s)
}

export function canonicalNextHumanAction(action: string | null): string | null {
  if (action === 'inspect_turn_timeout') return 'inspect_runtime_blocker'
  if (action === 'inspect_runtime_attempts') return 'inspect_runtime_blocker'
  if (action === 'inspect_provider_tool_lane') return 'inspect_runtime_blocker'
  if (action === 'inspect_completion_contract') return 'inspect_runtime_blocker'
  if (action === 'inspect_watchdog_root_cause') return 'inspect_runtime_blocker'
  if (action === 'inspect_turn_finalization') return 'inspect_runtime_blocker'
  return action
}

export function nextHumanActionLabel(action: string | null): string | null {
  const canonicalAction = canonicalNextHumanAction(action)
  if (!canonicalAction) return null
  if (isNextHumanAction(canonicalAction)) return NEXT_HUMAN_ACTION_LABELS[canonicalAction]
  warnUnknownAttentionToken('next_human_action', canonicalAction)
  return canonicalAction
}
