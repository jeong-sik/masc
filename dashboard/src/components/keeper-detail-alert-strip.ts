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
import { keeperNeedsDiagnosticAttention, refreshAfterRuntimeAction } from './keeper-detail-helpers'
import { pauseKeeper, resumeKeeper, wakeKeeper } from '../api/keeper'
import { showToast } from './common/toast'

export function KeeperRuntimeAlertStrip({ keeper }: { keeper: Keeper }) {
  const runtimeBlockerClass = keeper.runtime_blocker_class
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  const continueGate = keeper.runtime_blocker_continue_gate === true
  const socialFallbackActive = keeper.social_model_recognized === false
  const attentionReason = keeper.attention_reason?.trim() || null
  const nextHumanAction = keeper.next_human_action?.trim() || null
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
  const renderActivitySignal = () => activity.timestamp
    ? html`${activity.label} <${TimeAgo} timestamp=${activity.timestamp} />`
    : activity.ageSeconds != null
      ? html`${activity.label} ${formatDuration(activity.ageSeconds)} 전`
      : null
  if (!needsAttention && !hasActivitySignal && !hasRuntimeIdentitySignal) return null

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
      : trustDisposition === 'Pause' || keeper.trust?.needs_attention
        ? 'bg-[var(--warn-14)] text-[var(--color-status-warn)]'
        : trustDisposition === 'Pass'
          ? 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
          : 'bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]'
  const trustDispositionLabel = trustDisposition
    ? ({ Alert: '경보', Pause: '정지', Pass: '통과' } as Record<string, string>)[
        trustDisposition
      ] ?? trustDisposition
    : null

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
              <${RuntimeBadge} tone="bad">
                ${runtimeBlockerLabelText ?? '런타임 차단'}
              </${RuntimeBadge}>
              ${hasActivitySignal ? html`<span class="text-[var(--color-fg-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : null}
        ${runtimeBlocker
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">런타임 차단</strong> · ${runtimeBlocker}</span>`
          : null}
        ${blocker
          ? html`<span><${StrongSecondary}>차단 요인</${StrongSecondary}> · ${blocker}</span>`
          : null}
        ${keeper.last_need
          ? html`<span><${StrongSecondary}>최근 필요</${StrongSecondary}> · ${keeper.last_need}</span>`
          : null}
        ${attentionReason === 'approval_pending' && isBlockedBeforeWorktree
          ? html`<${RuntimeBadge} tone="warn">워크트리 전 차단</${RuntimeBadge}>`
          : attentionReason
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">주의 사유</strong> · ${attentionReason}</span>`
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
        ${nextHumanAction
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">다음 액션</strong> · ${nextHumanAction}</span>`
          : null}
        ${latestTerminalCode
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">종료 코드</strong> · ${latestTerminalCode}${latestTerminalSummary ? html` · ${latestTerminalSummary}` : null}</span>`
          : null}
        ${latestNextAction
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">권장 조치</strong> · ${latestNextAction}</span>`
          : null}
        ${shouldShowOperatorDispositionReason
          ? html`<span><${StrongSecondary}>운영자 판단</${StrongSecondary}> · ${operatorDispositionReason}</span>`
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
