// Shared humanization for the keeper `attention_reason` / `next_human_action`
// wire vocabularies. Extracted so every surface that shows these codes —
// the keeper detail alert strip and the overview attention queue — maps them
// through one closed-sum SSOT instead of rendering raw backend tokens.
//
// Closed as const + Record<…, string>. Adding a label without extending the
// union, or removing a union arm, fails typecheck rather than silently
// producing a missing/extraneous Korean label. Backend tokens that drift past
// the union surface via warnUnknownAttentionToken (dev console) and fall back
// to the raw token rather than slipping through unnoticed.
//
// The union mirrors the keeper_status_bridge needs_attention vocabulary plus
// keeper_turn_disposition arm-for-arm: every
// distinct reason/action those closed, non-composite emit sites produce has its
// own Korean label, with no lossy fold — a keeper blocked on
// `runtime_attempts_exhausted` and one blocked on `fiber_unresolved` get
// different operator copy, because the backend already paid to distinguish
// them. keeper-attention-labels.drift.test.ts reads those backend OCaml emit
// sites and fails the build if any produced token has no label here, so this
// list cannot silently drift behind the backend the way it did before
// (`stale_turn_timeout` was emitted for a release with no label).
//
// One-time warn per (kind, token) so dev consoles surface backend tokens that
// have no Korean label, without spamming on every render.
const warnedAttentionTokens = new Set<string>()
function warnUnknownAttentionToken(kind: 'attention_reason' | 'next_human_action', token: string) {
  const key = `${kind}|${token}`
  if (warnedAttentionTokens.has(key)) return
  warnedAttentionTokens.add(key)
  if (typeof console !== 'undefined') {
    console.warn(`[keeper-attention-labels] unknown ${kind}:`, token)
  }
}

// Backend emit sites for `attention_reason` (the drift guard reads these):
//   - lib/keeper/keeper_status_bridge.ml needs_attention block
//     (approval_pending, paused,
//      runtime_attempts_exhausted, provider_runtime_error, stale_turn_timeout,
//      fiber_unresolved, runtime_blocked)
//   - lib/keeper/keeper_execution_receipt.ml operator disposition reasons that
//     can become trust attention_reason via keeper_runtime_trust_snapshot.ml
export const ATTENTION_REASONS = [
  'approval_pending',
  'paused',
  'runtime_attempts_exhausted',
  'provider_runtime_error',
  'stale_turn_timeout',
  'fiber_unresolved',
  'runtime_blocked',
  'runtime_trust_snapshot_unavailable',
  'runtime_exhausted',
  'preflight_config_error',
  'degraded_retry',
  'transient_runtime_retry',
  'internal_error',
  'cancelled',
  'unmapped_runtime_state',
] as const
export type AttentionReason = typeof ATTENTION_REASONS[number]

const ATTENTION_REASON_LABELS: Record<AttentionReason, string> = {
  approval_pending: '승인 대기',
  paused: '일시정지',
  runtime_attempts_exhausted: '런타임 재시도 소진',
  provider_runtime_error: '런타임 호출 오류',
  stale_turn_timeout: '응답 지연(stale) 타임아웃',
  fiber_unresolved: '미완료 작업(fiber) 정리 필요',
  runtime_blocked: '런타임 근거 확인 필요',
  runtime_trust_snapshot_unavailable: '런타임 신뢰 스냅샷 없음',
  runtime_exhausted: '런타임 후보 소진',
  preflight_config_error: '실행 전 설정 오류',
  degraded_retry: '저하 상태 재시도',
  transient_runtime_retry: '일시적 런타임 재시도',
  internal_error: '내부 오류',
  cancelled: '취소됨',
  unmapped_runtime_state: '매핑되지 않은 runtime 상태',
}

// keeper_runtime_trust_snapshot.ml emits a SEPARATE, larger attention_reason
// vocabulary on the trust path (fsm_invariant, sandbox_violation, …) than the keeper_status_bridge
// needs_attention set this union started from. The known non-receipt trust
// runtime-failure tokens fold to the coarse `runtime_blocked` bucket so the
// detail strip shows a label instead of a raw token. This fold is deliberately
// scoped to that enumerated trust set — the first-class status_bridge reasons
// and receipt-derived reasons above keep their own labels.
const TRUST_RUNTIME_FAILURE_ALIASES: ReadonlySet<string> = new Set([
  'fsm_invariant',
  'sandbox_violation',
  'critical_block',
])

export function canonicalAttentionReason(reason: string | null): string | null {
  if (reason !== null && TRUST_RUNTIME_FAILURE_ALIASES.has(reason)) return 'runtime_blocked'
  return reason
}

export function isAttentionReason(s: string): s is AttentionReason {
  return (ATTENTION_REASONS as readonly string[]).includes(s)
}

export function attentionReasonLabel(reason: string | null, paused: boolean): string | null {
  const canonicalReason = canonicalAttentionReason(reason)
  if (!canonicalReason) return null
  if (canonicalReason === 'paused' && paused) return null
  if (isAttentionReason(canonicalReason)) return ATTENTION_REASON_LABELS[canonicalReason]
  warnUnknownAttentionToken('attention_reason', canonicalReason)
  return canonicalReason
}

// Backend emit sites for `next_human_action` (the drift guard reads these):
//   - lib/keeper/keeper_status_bridge.ml needs_attention block (paired 1:1 with
//     the corresponding attention_reason)
//   - lib/keeper/keeper_turn_disposition.ml next_action
//     (provide_input_or_decline, rerun_if_still_relevant, inspect_turn_timeout,
//      inspect_runtime_attempts, inspect_latest_error)
//   - lib/keeper/keeper_status_bridge.ml runtime_trust fallback
//     ('inspect_keeper_runtime_trust')
export const NEXT_HUMAN_ACTIONS = [
  'resolve_approval',
  'inspect_blocker_before_resume',
  'inspect_runtime_attempts',
  'inspect_provider_runtime_cause',
  'inspect_stale_turn_root_cause',
  'inspect_turn_finalization',
  'inspect_runtime_blocker',
  'resume_or_review',
  'provide_input_or_decline',
  'rerun_if_still_relevant',
  'inspect_turn_timeout',
  'inspect_latest_error',
  'inspect_keeper_runtime_trust',
] as const
export type NextHumanAction = typeof NEXT_HUMAN_ACTIONS[number]

const NEXT_HUMAN_ACTION_LABELS: Record<NextHumanAction, string> = {
  resolve_approval: '승인 요청 처리',
  inspect_blocker_before_resume: '원인 확인 후 재개',
  inspect_runtime_attempts: '재시도별 원인 확인',
  inspect_provider_runtime_cause: 'Provider 런타임 원인 확인',
  inspect_stale_turn_root_cause: '응답 지연(stale) 원인 확인',
  inspect_turn_finalization: '턴 정리 상태 확인',
  inspect_runtime_blocker: '런타임 근거 확인',
  resume_or_review: '재개 또는 설정 검토',
  provide_input_or_decline: '입력 제공 또는 거절',
  rerun_if_still_relevant: '필요 시 재실행',
  inspect_turn_timeout: '턴 타임아웃 원인 확인',
  inspect_latest_error: '최근 오류 확인',
  inspect_keeper_runtime_trust: '런타임 신뢰 스냅샷 확인',
}

export function isNextHumanAction(s: string): s is NextHumanAction {
  return (NEXT_HUMAN_ACTIONS as readonly string[]).includes(s)
}

// Reserved seam for genuine legacy aliases (see canonicalAttentionReason).
// Empty today: every action the backend emits has its own arm above, so no
// distinct action is folded.
export function canonicalNextHumanAction(action: string | null): string | null {
  return action
}

export function nextHumanActionLabel(action: string | null): string | null {
  const canonicalAction = canonicalNextHumanAction(action)
  if (!canonicalAction) return null
  if (isNextHumanAction(canonicalAction)) return NEXT_HUMAN_ACTION_LABELS[canonicalAction]
  warnUnknownAttentionToken('next_human_action', canonicalAction)
  return canonicalAction
}
