import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'
import {
  keeperActivityDisplay,
  keeperRuntimeBlockerLabel,
  keeperRuntimeBlockerHint,
} from '../lib/keeper-runtime-display'
import { TimeAgo } from './common/time-ago'
import { formatDuration } from './mission-utils'
import type { Keeper } from '../types'
import { StrongSecondary, RuntimeBadge } from './keeper-detail-primitives'
import { trustDispositionLabel as resolveTrustDispositionLabel } from './fsm-hub-types'
import { operatorDispositionReasonLabel } from './fsm-hub-types'
import { terminalReasonCodeLabel } from './fsm-hub-types'
import { keeperNeedsDiagnosticAttention, refreshAfterRuntimeAction } from './keeper-detail-helpers'
import { pauseKeeper, resumeKeeper, wakeKeeper } from '../api/keeper'
import { showToast } from './common/toast'

// Backend `attention_reason` is set across three emit sites (verified by
// `rg '"attention_reason".*\`String "' lib/`):
//   - lib/keeper/keeper_status_bridge.ml:727-742 — six common reasons.
//   - lib/keeper_fd_pressure.ml:190 — 'fd_pressure' when a keeper trips
//     the fd-accountant watermark.
//   - lib/dashboard/dashboard_goals.ml:44 —
//     'runtime_trust_snapshot_unavailable' when the trust snapshot has
//     not yet been computed.
// The label map must cover every emit site; missing entries fall back to
// the raw English token via `labels[reason] ?? reason`, leaving the
// operator with no Korean label.
function attentionReasonLabel(reason: string | null, paused: boolean): string | null {
  if (!reason) return null
  if ((reason === 'paused' || reason === 'paused_blocked') && paused) return null
  const labels: Record<string, string> = {
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
  return labels[reason] ?? reason
}

// Backend `next_human_action` is set alongside `attention_reason` at the
// same emit sites:
//   - lib/keeper/keeper_status_bridge.ml:727-742 — seven common actions.
//   - lib/keeper_fd_pressure.ml:191 — 'restore_fd_headroom' paired with
//     the 'fd_pressure' attention_reason.
//   - lib/dashboard/dashboard_goals.ml:45 — 'inspect_keeper_runtime_trust'
//     paired with the 'runtime_trust_snapshot_unavailable' reason.
// The label map below must cover every emit site so operators see a
// Korean instruction instead of the raw English token.
function nextHumanActionLabel(action: string | null): string | null {
  if (!action) return null
  const labels: Record<string, string> = {
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
  return labels[action] ?? action
}

export function KeeperRuntimeAlertStrip({ keeper }: { keeper: Keeper }) {
  const runtimeBlockerClass = keeper.runtime_blocker_class
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  const continueGate = keeper.runtime_blocker_continue_gate === true
  const socialFallbackActive = keeper.social_model_recognized === false
  const attentionReason = keeper.attention_reason?.trim() || null
  const nextHumanAction = keeper.next_human_action?.trim() || null
  const pausedRuntimeBlocker = keeper.paused === true && runtimeBlockerClass != null
  const attentionReasonText = attentionReasonLabel(attentionReason, keeper.paused === true)
  const nextHumanActionText = nextHumanActionLabel(nextHumanAction)
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
  const latestNextAction = keeper.trust?.latest_next_action?.trim() || null
  const operatorDispositionReason = keeper.trust?.operator_disposition_reason?.trim() || null
  const shouldShowOperatorDispositionReason =
    operatorDispositionReason !== null && operatorDispositionReason !== trustSummary
  const executionSummary = keeper.trust?.execution_summary ?? null
  const runtimeProofStatus =
    executionSummary?.runtime_proof_status?.trim()
    || executionSummary?.tool_contract_result?.trim()
    || null
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
    Boolean(runtimeProofStatus)
    || requiredTools.length > 0
    || usedTools.length > 0
    || unexpectedTools.length > 0
    || missingRequiredTools.length > 0
    || Boolean(trustSummary)
    || Boolean(stopCause)
    || Boolean(latestTerminalCode)
    || Boolean(latestNextAction)
    || shouldShowOperatorDispositionReason
    || Boolean(trustLatestEvent)
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
            >재개<//>`
          : html`<${ActionButton}
              variant="ghost"
              size="sm"
              class="!py-0.5 !bg-[var(--color-bg-hover)] !text-[var(--color-fg-secondary)] inline-flex items-center"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('pause')}
            >일시정지<//>
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
        ${nextHumanActionText
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">다음 액션</strong> · ${nextHumanActionText}</span>`
          : null}
        ${stopCause
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">정지 원인</strong> · ${stopCause.code}${stopCause.summary ? html` · ${stopCause.summary}` : null}</span>`
          : null}
        ${latestTerminalCode && latestTerminalCode !== stopCause?.code
          ? html`<span title=${latestTerminalCode}><strong class="text-[var(--color-fg-secondary)]">종료 코드</strong> · ${terminalReasonCodeLabel(latestTerminalCode)}${latestTerminalSummary ? html` · ${latestTerminalSummary}` : null}</span>`
          : null}
        ${latestNextAction
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">권장 조치</strong> · ${latestNextAction}</span>`
          : null}
        ${shouldShowOperatorDispositionReason
          ? html`<span title=${operatorDispositionReason ?? ''}><${StrongSecondary}>운영자 판단</${StrongSecondary}> · ${operatorDispositionReasonLabel(operatorDispositionReason)}</span>`
          : null}
        ${trustDisposition
          ? html`
              <span class="inline-flex items-center rounded-[var(--r-0)] px-2 py-0.5 text-2xs font-semibold ${trustToneClass}">
                검증 ${trustDispositionLabel}
              </span>
            `
          : null}
        ${trustSummary
          ? html`<span><${StrongSecondary}>검증</${StrongSecondary}> · ${trustSummary}</span>`
          : null}
        ${runtimeProofStatus
          ? html`<span><${StrongSecondary}>증명</${StrongSecondary}> · ${runtimeProofStatus}</span>`
          : null}
        ${requiredTools.length > 0
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">필요 도구</strong> · ${requiredTools.join(', ')}</span>`
          : null}
        ${usedTools.length > 0
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">사용 도구</strong> · ${usedTools.join(', ')}</span>`
          : null}
        ${unexpectedTools.length > 0
          ? html`<span class="text-[var(--color-status-err)]"><strong>외부 도구</strong> · ${unexpectedTools.join(', ')}</span>`
          : null}
        ${missingRequiredTools.length > 0
          ? html`<span class="text-[var(--color-status-err)]"><strong>누락</strong> · ${missingRequiredTools.join(', ')}</span>`
          : null}
        ${cascadeLabel
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">캐스케이드</strong> · ${cascadeLabel}</span>`
          : null}
        ${observedCascadeOutcome || typeof observedProviderAttempts === 'number'
          ? html`
              <span>
                <strong class="text-[var(--color-fg-secondary)]">런타임 레인</strong>
                · ${observedCascadeOutcome ?? 'observed'}
                ${typeof observedProviderAttempts === 'number' ? ` · ${observedProviderAttempts}회 시도` : ''}
                ${observedProviderFallback === true ? ' · 폴백' : ''}
              </span>
            `
          : null}
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
