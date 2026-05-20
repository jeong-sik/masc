import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'
import {
  keeperActivityDisplay,
  keeperRuntimeBlockerLabel,
  keeperRuntimeBlockerHint,
} from '../lib/keeper-runtime-display'
import { isKeeperPaused } from '../lib/keeper-predicates'
import { TimeAgo } from './common/time-ago'
import { formatDuration } from './mission-utils'
import type { Keeper } from '../types'
import { StrongSecondary, RuntimeBadge } from './keeper-detail-primitives'
import {
  trustDispositionLabel as resolveTrustDispositionLabel,
  computeKeeperVerdict,
  isTurnTerminalFailureCode,
  type KeeperVerdict,
  type CascadeAttemptObservation,
} from './fsm-hub-types'
import { keeperNeedsDiagnosticAttention, refreshAfterRuntimeAction } from './keeper-detail-helpers'
import { pauseKeeper, resumeKeeper, wakeKeeper } from '../api/keeper'
import { showToast } from './common/toast'
import {
  SYNTHETIC_SCOPE_LABEL,
  SYNTHETIC_TOOLTIP,
  stripSyntheticMarker,
} from '../lib/synthetic-marker'

/**
 * Render a text field that *might* carry the backend `[SYNTHETIC]`
 * prefix. Synthesized values render with a side chip + tooltip so
 * operators don't mistake a backend fallback for ground-truth model
 * output. Phase 4 surface fix for the §1.6 asymmetry: memory search
 * already rejected synthetic rows, but the dashboard rendered them
 * verbatim until now.
 */
function SyntheticAwareText({ text }: { text: string }) {
  const { stripped, synthesized } = stripSyntheticMarker(text)
  if (!synthesized) return html`<span>${stripped}</span>`
  return html`
    <span class="inline-flex flex-wrap items-baseline gap-1.5">
      <span
        class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--warn-30)] bg-[var(--warn-10)] px-1.5 py-px text-[10px] font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-status-warn)]"
        title=${SYNTHETIC_TOOLTIP}
      >
        ${SYNTHETIC_SCOPE_LABEL}
      </span>
      <span>${stripped}</span>
    </span>
  `
}

// Backend emit sites for `attention_reason`:
//   - lib/keeper/keeper_status_bridge.ml:727-742 (six common reasons)
//   - lib/keeper_fd_pressure.ml:190 ('fd_pressure')
//   - lib/dashboard/dashboard_goals.ml:44 ('runtime_trust_snapshot_unavailable')
// Closed as const + Record<AttentionReason, string>. Adding a new label
// without extending the union, or removing a union arm, fails typecheck
// rather than silently producing a missing/extraneous Korean label. The
// dual classification rule the labels map encodes is exhaustive over
// the union; backend variants that drift past it surface via
// warnUnknownAttentionToken instead of slipping through as a raw token.
const ATTENTION_REASONS = [
  'approval_pending',
  'continue_gate_required',
  'paused',
  'paused_blocked',
  'runtime_blocked',
  'timeout_budget_exhausted',
  'social_model_fallback',
  'fd_pressure',
  'runtime_trust_snapshot_unavailable',
] as const
type AttentionReason = typeof ATTENTION_REASONS[number]

const ATTENTION_REASON_LABELS: Record<AttentionReason, string> = {
  approval_pending: '승인 대기',
  continue_gate_required: '계속 진행 승인 필요',
  paused: '일시정지',
  paused_blocked: '일시정지 원인 확인 필요',
  runtime_blocked: '런타임 근거 확인 필요',
  timeout_budget_exhausted: '타임아웃 예산 소진',
  social_model_fallback: '소셜 모델 폴백',
  fd_pressure: 'FD 임계치 초과',
  runtime_trust_snapshot_unavailable: '런타임 신뢰 스냅샷 없음',
}

function isAttentionReason(s: string): s is AttentionReason {
  return (ATTENTION_REASONS as readonly string[]).includes(s)
}

function attentionReasonLabel(reason: string | null, paused: boolean): string | null {
  if (!reason) return null
  if ((reason === 'paused' || reason === 'paused_blocked') && paused) return null
  if (isAttentionReason(reason)) return ATTENTION_REASON_LABELS[reason]
  warnUnknownAttentionToken('attention_reason', reason)
  return reason
}

// Backend emit sites for `next_human_action` (paired 1:1 with the
// corresponding `attention_reason`):
//   - lib/keeper/keeper_status_bridge.ml:727-742 (seven common actions)
//   - lib/keeper_fd_pressure.ml:191 ('restore_fd_headroom')
//   - lib/dashboard/dashboard_goals.ml:45 ('inspect_keeper_runtime_trust')
const NEXT_HUMAN_ACTIONS = [
  'approve_or_reject_continue',
  'inspect_blocker_before_resume',
  'inspect_runtime_blocker',
  'inspect_timeout_budget',
  'resolve_approval',
  'resume_or_review',
  'review_social_model',
  'restore_fd_headroom',
  'inspect_keeper_runtime_trust',
] as const
type NextHumanAction = typeof NEXT_HUMAN_ACTIONS[number]

const NEXT_HUMAN_ACTION_LABELS: Record<NextHumanAction, string> = {
  approve_or_reject_continue: '계속 진행 승인 또는 거절',
  inspect_blocker_before_resume: '원인 확인 후 재개',
  inspect_runtime_blocker: '런타임 근거 확인',
  inspect_timeout_budget: '타임아웃 예산 확인',
  resolve_approval: '승인 요청 처리',
  resume_or_review: '재개 또는 설정 검토',
  review_social_model: '소셜 모델 설정 검토',
  restore_fd_headroom: 'FD 여유 확보',
  inspect_keeper_runtime_trust: '런타임 신뢰 스냅샷 확인',
}

function isNextHumanAction(s: string): s is NextHumanAction {
  return (NEXT_HUMAN_ACTIONS as readonly string[]).includes(s)
}

function nextHumanActionLabel(action: string | null): string | null {
  if (!action) return null
  if (isNextHumanAction(action)) return NEXT_HUMAN_ACTION_LABELS[action]
  warnUnknownAttentionToken('next_human_action', action)
  return action
}

// (attention_reason, next_human_action) pairs that surface the same
// operator intent in two visually identical lines — e.g.
//   주의 사유 · 런타임 근거 확인 필요
//   다음 액션 · 런타임 근거 확인
// Backend emits them as separate fields (lib/keeper/keeper_status_bridge.ml:727-742
// and the fd_pressure / runtime_trust_snapshot peer sites), and we keep
// the pairing here in dashboard so other consumers that *do* want both
// (e.g. timeline reconstruction) are unaffected. Adding a new arm to
// either union without considering the pair is safe — the predicate
// just returns false and both lines render.
const ATTENTION_PAIR_DUPLICATES: ReadonlyArray<readonly [AttentionReason, NextHumanAction]> = [
  ['runtime_blocked', 'inspect_runtime_blocker'],
  ['paused_blocked', 'inspect_blocker_before_resume'],
  ['timeout_budget_exhausted', 'inspect_timeout_budget'],
  ['runtime_trust_snapshot_unavailable', 'inspect_keeper_runtime_trust'],
]
const ATTENTION_PAIR_DUPLICATE_KEYS = new Set<string>(
  ATTENTION_PAIR_DUPLICATES.map(([r, a]) => `${r}|${a}`),
)
function isAttentionPairDuplicate(reason: string | null, action: string | null): boolean {
  if (!reason || !action) return false
  return ATTENTION_PAIR_DUPLICATE_KEYS.has(`${reason}|${action}`)
}

// One-time warn per (kind, token) so dev consoles surface backend
// variants that have no Korean label, without spamming on every render.
const warnedAttentionTokens = new Set<string>()
function warnUnknownAttentionToken(kind: 'attention_reason' | 'next_human_action', token: string) {
  const key = `${kind}|${token}`
  if (warnedAttentionTokens.has(key)) return
  warnedAttentionTokens.add(key)
  if (typeof console !== 'undefined') {
    console.warn(`[keeper-detail-alert-strip] unknown ${kind}:`, token)
  }
}

function assertNever(value: never): never {
  throw new Error(`unreachable case: ${String(value)}`)
}

// Exhaustive render over `KeeperVerdict.kind`. Adding a new arm to
// `KeeperVerdict` will fail typecheck on the assertNever default
// rather than silently falling through to a default render. The tool
// contract result, when present, is always shown as scope-tagged
// evidence ("도구 계약") attached to the verdict rather than as a
// sibling claim — this is what closes 모순 #2.
function renderVerdict(verdict: KeeperVerdict) {
  const toolContractEvidence = verdict.toolContract
    ? html`<span><${StrongSecondary}>도구 계약</${StrongSecondary}> · ${verdict.toolContract.label}</span>`
    : null
  switch (verdict.kind) {
    case 'failed':
      return html`
        <span><${StrongSecondary}>검증</${StrongSecondary}> · ${verdict.reasonLabel}</span>
        ${toolContractEvidence}
      `
    case 'pending':
      return html`
        ${verdict.reasonLabel
          ? html`<span><${StrongSecondary}>검증</${StrongSecondary}> · ${verdict.reasonLabel}</span>`
          : null}
        ${toolContractEvidence}
      `
    case 'verified':
      return html`
        ${verdict.reasonLabel
          ? html`<span><${StrongSecondary}>검증</${StrongSecondary}> · ${verdict.reasonLabel}</span>`
          : null}
        ${toolContractEvidence}
      `
    case 'no_verdict':
      return toolContractEvidence
    default:
      return assertNever(verdict)
  }
}

// Render the cascade attempt observation with explicit scope label
// ("마지막 시도") so an operator does not read a per-attempt success
// as a per-turn success. The caller already gates rendering when the
// per-turn stop_cause is a terminal failure — this is what closes 모순 #3.
function renderCascadeAttemptObservation(observation: CascadeAttemptObservation) {
  const scopeLabel = observation.scope === 'attempt' ? '마지막 시도' : '턴 결과'
  return html`
    <span>
      <strong class="text-[var(--color-fg-secondary)]">${scopeLabel}</strong>
      · ${observation.outcome ?? 'observed'}
      ${observation.attempts !== null ? ` · ${observation.attempts}회 시도` : ''}
      ${observation.fallbackApplied ? ' · 폴백' : ''}
    </span>
  `
}

export function KeeperRuntimeAlertStrip({ keeper }: { keeper: Keeper }) {
  const runtimeBlockerClass = keeper.runtime_blocker_class
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  const continueGate = keeper.runtime_blocker_continue_gate === true
  const socialFallbackActive = keeper.social_model_recognized === false
  const attentionReason = keeper.attention_reason?.trim() || null
  const nextHumanAction = keeper.next_human_action?.trim() || null
  // RFC-0135 PR-13: canonical paused predicate. SSOT also covers
  // FSM phase=Paused / pipeline_stage=paused / status=paused, so the
  // "paused + live blocker" composite flag and the attention-reason
  // label now agree across the four paused axes (RFC §1.5 Cluster C3).
  const isPaused = isKeeperPaused(keeper)
  const pausedRuntimeBlocker = isPaused && runtimeBlockerClass != null
  const attentionReasonText = attentionReasonLabel(attentionReason, isPaused)
  const nextHumanActionText = nextHumanActionLabel(nextHumanAction)
  // Suppress action-lines that duplicate the visible "주의 사유" line
  // above. The dedupe is keyed on the (attention_reason, next_action)
  // pair so it applies to both `next_human_action` (the immediate
  // operator instruction) and `trust.latest_next_action` (the per-turn
  // "권장 조치" follow-up suggestion), since the backend draws both
  // from the same NextHumanAction wire vocabulary. If attentionReasonText
  // is null (paused suppresses the reason line) we keep both visible so
  // the operator still sees what to do.
  const duplicatesAttentionReason = (action: string | null): boolean =>
    attentionReasonText !== null
    && isAttentionPairDuplicate(attentionReason, action)
  const suppressDuplicateNextAction = duplicatesAttentionReason(nextHumanAction)
  const sandboxTarget = keeper.sandbox_target?.trim() || keeper.sandbox_profile?.trim() || null
  const persistedPolicyCount = keeper.approval_policy_effective?.persisted_rules
  const goalLinkedTasks = keeper.goal_progress?.linked_task_count
  const goalConvergence = keeper.goal_progress?.convergence
  const blocker = keeper.last_blocker?.trim()
  const pendingFirst = keeper.trust?.approval_state?.pending_first ?? null
  const pendingApprovalId = pendingFirst?.id?.trim() || null
  const pendingApprovalTool = pendingFirst?.tool_name?.trim() || null
  const pendingApprovalTaskId = pendingFirst?.task_id?.trim() || null
  const pendingApprovalBlockerClass = pendingFirst?.blocker_class?.trim() || null
  const isBlockedBeforeWorktree = pendingApprovalBlockerClass === 'blocked_before_worktree'
  const trustDisposition = keeper.trust?.disposition?.trim() || null
  const trustSummary =
    keeper.trust?.attention_reason?.trim()
    || keeper.trust?.disposition_reason?.trim()
    || keeper.trust?.execution_summary?.mutation_guard_summary?.trim()
    || null
  const stopCause = keeper.stop_cause ?? null
  const latestTerminalReason = keeper.trust?.latest_terminal_reason ?? null
  const latestTerminalCode = latestTerminalReason?.code?.trim() || null
  const latestTerminalSummary = latestTerminalReason?.summary?.trim() || null
  // Hide "종료 코드" when it references a past *success* turn while the
  // current stop_cause is a terminal failure -- that is the
  // "정지 원인 · turn_timeout / 종료 코드 · success" time-axis mix the
  // ckpt-2 follow-up addresses. Both-failure pairs (e.g. turn_timeout +
  // turn_wall_clock_timeout) stay visible since they describe the same
  // failure surface from different observability layers.
  const suppressStaleLatestTerminal =
    latestTerminalCode !== null
    && stopCause !== null
    && isTurnTerminalFailureCode(stopCause.code)
    && !isTurnTerminalFailureCode(latestTerminalCode)
  const latestNextAction = keeper.trust?.latest_next_action?.trim() || null
  const operatorDispositionReason = keeper.trust?.operator_disposition_reason?.trim() || null
  const shouldShowOperatorDispositionReason =
    operatorDispositionReason !== null && operatorDispositionReason !== trustSummary
  const executionSummary = keeper.trust?.execution_summary ?? null
  // Backend emits `runtime_proof_status` as a copy of
  // `tool_contract_result` (lib/keeper/keeper_runtime_trust_snapshot.ml:1063-1065).
  // Reading either yields the same closed-sum tool contract code, so
  // we collapse to a single canonical input for the verdict helper.
  const toolContractResult =
    executionSummary?.runtime_proof_status?.trim()
    || executionSummary?.tool_contract_result?.trim()
    || null
  // Single typed verdict replaces the prior sibling "검증" / "증명"
  // spans. Exhaustive switch on `verdict.kind` below; new arms force
  // a compile error rather than silently falling through.
  const verdict: KeeperVerdict = computeKeeperVerdict({
    trustDisposition,
    trustSummary,
    toolContractResult,
  })
  const requiredTools = executionSummary?.required_tools ?? []
  const missingRequiredTools = executionSummary?.missing_required_tools ?? []
  const usedTools = executionSummary?.tools_used ?? []
  const unexpectedTools = executionSummary?.unexpected_tools ?? []
  const providerAttempts = executionSummary?.provider_attempt_count
  const providerFallback = executionSummary?.provider_fallback_applied
  const cascadeOutcome = executionSummary?.cascade_outcome?.trim() || null
  const cascadeName = keeper.cascade_name?.trim() || null
  const cascadeCanonical =
    keeper.cascade_canonical?.trim()
    || keeper.selected_cascade_canonical?.trim()
    || null
  const cascadeLabel =
    cascadeName && cascadeCanonical && cascadeName !== cascadeCanonical
      ? `${cascadeName} -> ${cascadeCanonical}`
      : cascadeName ?? cascadeCanonical
  const latestCascadeMetric = (() => {
    const series = keeper.metrics_series ?? []
    for (let index = series.length - 1; index >= 0; index -= 1) {
      const point = series[index]
      if (!point) continue
      if (
        point.fallback_applied
        || point.cascade_outcome?.trim()
        || point.cascade_name?.trim()
        || typeof point.cascade_attempt_count === 'number'
      ) return point
    }
    return null
  })()
  const observedProviderAttempts =
    typeof providerAttempts === 'number'
      ? providerAttempts
      : latestCascadeMetric?.cascade_attempt_count ?? null
  const observedProviderFallback =
    typeof providerFallback === 'boolean'
      ? providerFallback
      : latestCascadeMetric?.fallback_applied ?? null
  const observedCascadeOutcome =
    cascadeOutcome || latestCascadeMetric?.cascade_outcome?.trim() || null
  const fallbackReason = latestCascadeMetric?.fallback_reason?.trim() || null
  const fallbackHops =
    typeof latestCascadeMetric?.fallback_hops === 'number'
      ? latestCascadeMetric.fallback_hops
      : 0
  const trustLatestEvent = keeper.trust?.latest_causal_event ?? null
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null && hbAgeMs > 300_000 // 5 minutes
  const needsAttention = keeperNeedsDiagnosticAttention(keeper)
  const activity = keeperActivityDisplay(keeper, keeper.agent?.last_seen)
  const hasActivitySignal = activity.timestamp != null || activity.ageSeconds != null
  const hasRuntimeIdentitySignal =
    Boolean(cascadeLabel)
    || Boolean(observedCascadeOutcome)
    || typeof observedProviderAttempts === 'number'
    || observedProviderFallback === true
    || (latestCascadeMetric?.fallback_applied === true && Boolean(fallbackReason || fallbackHops > 0))
  const hasExecutionEvidenceSignal =
    verdict.kind !== 'no_verdict'
    || verdict.toolContract !== null
    || requiredTools.length > 0
    || usedTools.length > 0
    || unexpectedTools.length > 0
    || missingRequiredTools.length > 0
    || Boolean(stopCause)
    || Boolean(latestTerminalCode)
    || Boolean(latestNextAction)
    || shouldShowOperatorDispositionReason
    || Boolean(trustLatestEvent)
  // Per-attempt cascade outcome is tagged with explicit scope so the
  // render block does not present it as a co-equal "런타임 레인"
  // badge when the per-turn stop_cause already declares a terminal
  // failure. Operators still see the attempt code as auxiliary
  // evidence ("마지막 시도") when the gate allows it.
  const cascadeAttempt: CascadeAttemptObservation = {
    scope: 'attempt',
    outcome: observedCascadeOutcome,
    attempts: typeof observedProviderAttempts === 'number' ? observedProviderAttempts : null,
    fallbackApplied: observedProviderFallback === true,
  }
  const turnTerminallyFailed = isTurnTerminalFailureCode(stopCause?.code ?? null)
    || isTurnTerminalFailureCode(latestTerminalCode)
  const renderCascadeAttempt =
    (cascadeAttempt.outcome !== null || cascadeAttempt.attempts !== null)
    && !turnTerminallyFailed
  const renderActivitySignal = () => activity.timestamp
    ? html`${activity.label} <${TimeAgo} timestamp=${activity.timestamp} />`
    : activity.ageSeconds != null
      ? html`${activity.label} ${formatDuration(activity.ageSeconds)} 전`
      : null
  if (!needsAttention && !hasActivitySignal && !hasRuntimeIdentitySignal && !hasExecutionEvidenceSignal) return null

  const directiveLoading = signal(false)
  const handleDirective = async (action: 'pause' | 'resume' | 'wakeup') => {
    directiveLoading.value = true
    try {
      const fn =
        action === 'pause' ? pauseKeeper
          : action === 'resume' ? resumeKeeper
          : wakeKeeper
      const res = await fn(keeper.name)
      if (res.ok) {
        const msg =
          action === 'pause' ? `${keeper.name} 일시정지됨`
            : action === 'resume' ? `${keeper.name} 재개됨`
            : `${keeper.name} 깨움 신호 전송됨`
        showToast(msg, 'success')
        await refreshAfterRuntimeAction()
      } else {
        showToast(res.error ?? '실패', 'error')
      }
    } catch {
      showToast('실패', 'error')
    } finally {
      directiveLoading.value = false
    }
  }

  const toneClass = keeper.paused || socialFallbackActive || runtimeBlocker || blocker || hbStale
    ? 'border-[var(--warn-24)] bg-[var(--warn-8)]'
    : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'
  const runtimeBlockerLabelText = keeperRuntimeBlockerLabel(runtimeBlockerClass)
  const trustToneClass =
    trustDisposition === 'Alert'
      ? 'bg-[var(--bad-soft)] text-[var(--color-status-err)]'
      : trustDisposition === 'Blocked' || trustDisposition === 'Pause' || keeper.trust?.needs_attention
        ? 'bg-[var(--warn-14)] text-[var(--color-status-warn)]'
        : trustDisposition === 'Pass'
          ? 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
          : 'bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]'
  // Inline 4-entry copy moved to `./fsm-hub-types` so the same map
  // doesn't drift between this surface and `goals/goal-tree.ts:194`.
  const trustDispositionLabel = resolveTrustDispositionLabel(trustDisposition)

  return html`
    <div class="px-6 pt-4">
      <div class="rounded-[var(--r-1)] border ${toneClass} px-4 py-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-xs text-[var(--color-fg-primary)]">
        ${keeper.paused
          ? html`<${RuntimeBadge} tone="warn">일시정지</${RuntimeBadge}>
            ${hasActivitySignal ? html`<span class="text-[var(--color-fg-muted)]">${renderActivitySignal()}</span>` : null}
            <${ActionButton}
              variant="ghost"
              size="sm"
              class="!py-0.5 !bg-[var(--color-bg-hover)] !text-[var(--color-fg-secondary)] inline-flex items-center"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('resume')}
              title="재개: 일시정지된 keeper 를 다시 실행합니다 (paused → running)"
            >재개하기<//>`
          : html`<${ActionButton}
              variant="ghost"
              size="sm"
              class="!py-0.5 !bg-[var(--color-bg-hover)] !text-[var(--color-fg-secondary)] inline-flex items-center"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('pause')}
              title="일시정지: 실행 중인 keeper 를 일시 멈춥니다 (running → paused, 현재 turn 은 정상 종료)"
            >일시정지하기<//>
            ${(hbStale || runtimeBlockerClass === 'oas_timeout_budget' || runtimeBlockerClass === 'cascade_exhausted' || runtimeBlockerClass === 'turn_timeout')
              ? html`<${ActionButton}
                  variant="warn"
                  size="sm"
                  class="!py-0.5 inline-flex items-center"
                  disabled=${directiveLoading.value}
                  onClick=${() => handleDirective('wakeup')}
                  title="자고 있는 keeper의 sleep을 깨워 다음 turn을 시도합니다. fiber가 살아 있을 때만 효과가 있습니다."
                >깨우기<//>`
              : null}`}
        ${keeper.paused && keeper.keepalive_running && continueGate
          ? html`<span>하트비트는 유지되지만 승인 전까지 자동 재개하지 않습니다.</span>`
          : keeper.paused && keeper.keepalive_running
            ? html`<span>하트비트는 유지되지만 자율 행동은 멈춰 있습니다.</span>`
          : null}
        ${hbStale
          ? html`<${RuntimeBadge} tone="bad">하트비트 끊김</${RuntimeBadge}>
            <span>마지막 하트비트: <${TimeAgo} timestamp=${keeper.last_heartbeat} /></span>`
          : null}
        ${continueGate
          ? html`
              <${RuntimeBadge} tone="warn">
                계속 진행 승인 대기
              </${RuntimeBadge}>
              ${hasActivitySignal ? html`<span class="text-[var(--color-fg-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : socialFallbackActive
          ? html`
              <${RuntimeBadge} tone="warn">
                소셜 폴백
              </${RuntimeBadge}>
              ${hasActivitySignal ? html`<span class="text-[var(--color-fg-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : runtimeBlockerClass
          ? html`
              <${RuntimeBadge} tone=${pausedRuntimeBlocker ? 'warn' : 'bad'}>
                ${pausedRuntimeBlocker
                  ? `일시정지 원인 · ${runtimeBlockerLabelText ?? '런타임 근거'}`
                  : runtimeBlockerLabelText ?? '런타임 차단'}
              </${RuntimeBadge}>
              ${hasActivitySignal ? html`<span class="text-[var(--color-fg-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : null}
        ${runtimeBlocker
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">${pausedRuntimeBlocker ? '일시정지 원인' : '런타임 차단'}</strong> · ${runtimeBlocker}</span>`
          : null}
        ${blocker
          ? html`<span><${StrongSecondary}>차단 요인</${StrongSecondary}> · ${blocker}</span>`
          : null}
        ${keeper.last_need
          ? html`<span><${StrongSecondary}>최근 필요</${StrongSecondary}> · ${keeper.last_need}</span>`
          : null}
        ${attentionReason === 'approval_pending' && isBlockedBeforeWorktree
          ? html`<${RuntimeBadge} tone="warn">워크트리 전 차단</${RuntimeBadge}>`
          : attentionReasonText
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">주의 사유</strong> · ${attentionReasonText}</span>`
          : null}
        ${attentionReason === 'approval_pending' && pendingApprovalId
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">승인 ID</strong> · <code class="font-mono">${pendingApprovalId}</code></span>`
          : null}
        ${attentionReason === 'approval_pending' && pendingApprovalTool
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">차단 도구</strong> · ${pendingApprovalTool}</span>`
          : null}
        ${attentionReason === 'approval_pending' && pendingApprovalTaskId
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">작업</strong> · ${pendingApprovalTaskId}</span>`
          : null}
        ${nextHumanActionText && !suppressDuplicateNextAction
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">다음 액션</strong> · ${nextHumanActionText}</span>`
          : null}
        ${stopCause && isTurnTerminalFailureCode(stopCause.code)
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">정지 원인</strong> · ${stopCause.code}${stopCause.summary ? html` · <${SyntheticAwareText} text=${stopCause.summary} />` : null}</span>`
          : null}
        ${latestTerminalCode && latestTerminalCode !== stopCause?.code && !suppressStaleLatestTerminal
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">종료 코드</strong> · ${latestTerminalCode}${latestTerminalSummary ? html` · <${SyntheticAwareText} text=${latestTerminalSummary} />` : null}</span>`
          : null}
        ${latestNextAction && !duplicatesAttentionReason(latestNextAction)
          ? html`<span title=${latestNextAction}><strong class="text-[var(--color-fg-secondary)]">권장 조치</strong> · ${nextHumanActionLabel(latestNextAction)}</span>`
          : null}
        ${shouldShowOperatorDispositionReason && operatorDispositionReason
          ? html`<span><${StrongSecondary}>운영자 판단</${StrongSecondary}> · <${SyntheticAwareText} text=${operatorDispositionReason} /></span>`
          : null}
        ${trustDisposition
          ? html`
              <span class="inline-flex items-center rounded-[var(--r-0)] px-2 py-0.5 text-2xs font-semibold ${trustToneClass}">
                검증 ${trustDispositionLabel}
              </span>
            `
          : null}
        ${renderVerdict(verdict)}
        ${requiredTools.length > 0
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">필요 도구</strong> · ${requiredTools.join(', ')}</span>`
          : null}
        ${usedTools.length > 0
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">사용 도구</strong> · ${usedTools.join(', ')}</span>`
          : null}
        ${unexpectedTools.length > 0
          ? html`<span class="text-[var(--color-status-err)]" title="키퍼 persona의 허용 도구 목록 외부에서 호출된 도구 — 계약 위반"><strong>허용 외 도구</strong> · ${unexpectedTools.join(', ')}</span>`
          : null}
        ${missingRequiredTools.length > 0
          ? html`<span class="text-[var(--color-status-err)]"><strong>누락</strong> · ${missingRequiredTools.join(', ')}</span>`
          : null}
        ${cascadeLabel
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">캐스케이드</strong> · ${cascadeLabel}</span>`
          : null}
        ${renderCascadeAttempt ? renderCascadeAttemptObservation(cascadeAttempt) : null}
        ${latestCascadeMetric?.fallback_applied === true && (fallbackReason || fallbackHops > 0)
          ? html`
              <span class="text-[var(--color-status-warn)]">
                <strong>폴백</strong>
                ${fallbackReason ? ` · ${fallbackReason}` : ''}
                ${fallbackHops > 0 ? ` · ${fallbackHops} hops` : ''}
              </span>
            `
          : null}
        ${trustLatestEvent
          ? html`
              <span>
                <${StrongSecondary}>최근 검증 이벤트</${StrongSecondary}>
                · ${trustLatestEvent.title}
                · <${TimeAgo} timestamp=${trustLatestEvent.ts} />
              </span>
            `
          : null}
        ${sandboxTarget
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">샌드박스</strong> · ${sandboxTarget}</span>`
          : null}
        ${typeof persistedPolicyCount === 'number'
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">상시 규칙</strong> · ${persistedPolicyCount}건</span>`
          : null}
        ${typeof goalLinkedTasks === 'number'
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">목표 작업</strong> · ${goalLinkedTasks}</span>`
          : null}
        ${typeof goalConvergence === 'number'
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">목표 진행률</strong> · ${Math.round(goalConvergence * 100)}%</span>`
          : null}
        ${hasActivitySignal
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">최근 신호</strong> · ${renderActivitySignal()}</span>`
          : null}
      </div>
    </div>
  `
}
