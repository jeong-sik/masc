import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'
import {
  keeperActivityDisplay,
  normalizeKeeperBlockerText,
  keeperRuntimeBlockerLabel,
  keeperRuntimeBlockerHint,
} from '../lib/keeper-runtime-display'
import { isKeeperPaused, keeperActionVisibility } from '../lib/keeper-predicates'
import { TimeAgo } from './common/time-ago'
import { formatDuration } from '../lib/format-time'
import type { Keeper } from '../types'
import { StrongSecondary, RuntimeBadge } from './keeper-detail-primitives'
import {
  trustDispositionLabel,
  isTurnTerminalFailureCode,
  type RuntimeAttemptObservation,
} from './fsm-hub-types'
import { keeperNeedsDiagnosticAttention, refreshAfterRuntimeAction } from './keeper-detail-helpers'
import { pauseKeeper, resumeKeeper, wakeKeeper } from '../api/keeper'
import { showToast } from './common/toast'
import {
  attentionReasonLabel,
  canonicalAttentionReason,
  canonicalNextHumanAction,
  nextHumanActionLabel,
  type AttentionReason,
  type NextHumanAction,
} from '../lib/keeper-attention-labels'

// attention_reason / next_human_action humanization (closed-sum unions,
// Korean label records, canonical folds) lives in
// ../lib/keeper-attention-labels so this surface and the overview attention
// queue map the same wire vocabulary through one SSOT. The pair-dedupe below
// stays local to this surface because only it renders both lines.

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
  ['paused', 'inspect_blocker_before_resume'],
  ['runtime_trust_snapshot_unavailable', 'inspect_keeper_runtime_trust'],
]
const ATTENTION_PAIR_DUPLICATE_KEYS = new Set<string>(
  ATTENTION_PAIR_DUPLICATES.map(([r, a]) => `${r}|${a}`),
)
function isAttentionPairDuplicate(reason: string | null, action: string | null): boolean {
  const canonicalReason = canonicalAttentionReason(reason)
  const canonicalAction = canonicalNextHumanAction(action)
  if (!canonicalReason || !canonicalAction) return false
  return ATTENTION_PAIR_DUPLICATE_KEYS.has(`${canonicalReason}|${canonicalAction}`)
}

function canonicalTerminalCode(code: string | null): string | null {
  return code
}

function canonicalTerminalSummary(_code: string | null, summary: string | null | undefined): string | null {
  return summary?.trim() || null
}

// Render the runtime attempt observation with explicit scope label
// ("마지막 시도") so an operator does not read a per-attempt success
// as a per-turn success. The caller already gates rendering when the
// per-turn stop_cause is a terminal failure — this is what closes 모순 #3.
function renderRuntimeAttemptObservation(observation: RuntimeAttemptObservation) {
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
  const attentionReason = canonicalAttentionReason(keeper.attention_reason?.trim() || null)
  const nextHumanAction = canonicalNextHumanAction(keeper.next_human_action?.trim() || null)
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
  const goalLinkedTasks = keeper.goal_progress?.linked_task_count
  const goalConvergence = keeper.goal_progress?.convergence
  const blocker = normalizeKeeperBlockerText(keeper.last_blocker)
  const pendingFirst = keeper.trust?.approval_state?.pending_first ?? null
  const pendingApprovalId = pendingFirst?.id?.trim() || null
  const pendingApprovalTool = pendingFirst?.tool_name?.trim() || null
  const pendingApprovalTaskId = pendingFirst?.task_id?.trim() || null
  const pendingApprovalBlockerClass = pendingFirst?.blocker_class?.trim() || null
  const isBlockedBeforeWorktree = pendingApprovalBlockerClass === 'blocked_before_worktree'
  const trustDisposition = keeper.trust?.disposition?.trim() || null
  const trustSummary =
    canonicalAttentionReason(keeper.trust?.attention_reason?.trim() || null)
    || keeper.trust?.disposition_reason?.trim()
    || null
  const stopCause = keeper.stop_cause ?? null
  const stopCauseCodeRaw = stopCause?.code?.trim() || null
  const stopCauseCode = canonicalTerminalCode(stopCauseCodeRaw)
  const stopCauseSummary = canonicalTerminalSummary(stopCauseCodeRaw, stopCause?.summary)
  const latestTerminalReason = keeper.trust?.latest_terminal_reason ?? null
  const latestTerminalCodeRaw = latestTerminalReason?.code?.trim() || null
  const latestTerminalCode = canonicalTerminalCode(latestTerminalCodeRaw)
  const latestTerminalSummary = canonicalTerminalSummary(
    latestTerminalCodeRaw,
    latestTerminalReason?.summary,
  )
  // Hide "종료 코드" when it references a past *success* turn while the
  // current stop_cause is a terminal failure -- that is the
  // "정지 원인 · turn_timeout / 종료 코드 · success" time-axis mix the
  // ckpt-2 follow-up addresses. Both-failure pairs (e.g. turn_timeout +
  // turn_wall_clock_timeout) stay visible since they describe the same
  // failure surface from different observability layers.
  const suppressStaleLatestTerminal =
    latestTerminalCode !== null
    && stopCauseCode !== null
    && isTurnTerminalFailureCode(stopCauseCode)
    && !isTurnTerminalFailureCode(latestTerminalCode)
  const latestNextAction = canonicalNextHumanAction(keeper.trust?.latest_next_action?.trim() || null)
  const operatorDispositionReason = keeper.trust?.operator_disposition_reason?.trim() || null
  const shouldShowOperatorDispositionReason =
    operatorDispositionReason !== null && operatorDispositionReason !== trustSummary
  const executionSummary = keeper.trust?.execution_summary ?? null
  const providerAttempts = executionSummary?.provider_attempt_count
  const providerFallback = executionSummary?.provider_fallback_applied
  const runtimeOutcome = executionSummary?.runtime_outcome?.trim() || null
  const runtimeName = keeper.runtime_id?.trim() || null
  const runtimeCanonical =
    keeper.runtime_canonical?.trim()
    || keeper.selected_runtime_canonical?.trim()
    || null
  const runtimeLabel =
    runtimeName && runtimeCanonical && runtimeName !== runtimeCanonical
      ? `${runtimeName} -> ${runtimeCanonical}`
      : runtimeName ?? runtimeCanonical
  const latestRuntimeMetric = (() => {
    const series = keeper.metrics_series ?? []
    for (let index = series.length - 1; index >= 0; index -= 1) {
      const point = series[index]
      if (!point) continue
      if (
        point.fallback_applied
        || point.runtime_outcome?.trim()
        || point.runtime_id?.trim()
        || typeof point.runtime_attempt_count === 'number'
      ) return point
    }
    return null
  })()
  const observedProviderAttempts =
    typeof providerAttempts === 'number'
      ? providerAttempts
      : latestRuntimeMetric?.runtime_attempt_count ?? null
  const observedProviderFallback =
    typeof providerFallback === 'boolean'
      ? providerFallback
      : latestRuntimeMetric?.fallback_applied ?? null
  const observedRuntimeOutcome =
    runtimeOutcome || latestRuntimeMetric?.runtime_outcome?.trim() || null
  const fallbackReason = latestRuntimeMetric?.fallback_reason?.trim() || null
  const fallbackHops =
    typeof latestRuntimeMetric?.fallback_hops === 'number'
      ? latestRuntimeMetric.fallback_hops
      : 0
  const trustLatestEvent = keeper.trust?.latest_causal_event ?? null
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null && hbAgeMs > 300_000 // 5 minutes
  const needsAttention = keeperNeedsDiagnosticAttention(keeper)
  const activity = keeperActivityDisplay(keeper, keeper.agent?.last_seen)
  const hasActivitySignal = activity.timestamp != null || activity.ageSeconds != null
  const hasRuntimeIdentitySignal =
    Boolean(runtimeLabel)
    || Boolean(observedRuntimeOutcome)
    || typeof observedProviderAttempts === 'number'
    || observedProviderFallback === true
    || (latestRuntimeMetric?.fallback_applied === true && Boolean(fallbackReason || fallbackHops > 0))
  const hasExecutionEvidenceSignal =
    Boolean(stopCause)
    || Boolean(latestTerminalCode)
    || Boolean(latestNextAction)
    || shouldShowOperatorDispositionReason
    || Boolean(trustLatestEvent)
  // Per-attempt runtime outcome is tagged with explicit scope so the
  // render block does not present it as a co-equal "런타임 레인"
  // badge when the per-turn stop_cause already declares a terminal
  // failure. Operators still see the attempt code as auxiliary
  // evidence ("마지막 시도") when the gate allows it.
  const runtimeAttempt: RuntimeAttemptObservation = {
    scope: 'attempt',
    outcome: observedRuntimeOutcome,
    attempts: typeof observedProviderAttempts === 'number' ? observedProviderAttempts : null,
    fallbackApplied: observedProviderFallback === true,
  }
  const turnTerminallyFailed = isTurnTerminalFailureCode(stopCauseCode)
    || isTurnTerminalFailureCode(latestTerminalCode)
  const renderRuntimeAttempt =
    (runtimeAttempt.outcome !== null || runtimeAttempt.attempts !== null)
    && !turnTerminallyFailed
  const renderActivitySignal = () => activity.timestamp
    ? html`${activity.label} <${TimeAgo} timestamp=${activity.timestamp} />`
    : activity.ageSeconds != null
      ? html`${activity.label} ${formatDuration(activity.ageSeconds)} 전`
      : null
  if (!needsAttention && !hasActivitySignal && !hasRuntimeIdentitySignal && !hasExecutionEvidenceSignal) return null

  const actionVisibility = keeperActionVisibility(keeper)
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

  const toneClass = isPaused || runtimeBlocker || blocker || hbStale
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
  // Local result var keeps a different name from the imported function so
  // there's no need for an `as resolveTrustDispositionLabel` alias.
  const trustDispositionDisplay = trustDispositionLabel(trustDisposition)

  return html`
    <div class="px-6 pt-4 v2-monitoring-surface">
      <div class="rounded-[var(--r-1)] border ${toneClass} px-4 py-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-xs text-[var(--color-fg-primary)] v2-monitoring-panel">
        ${actionVisibility.canResume
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
          : html`${actionVisibility.canPause
            ? html`<${ActionButton}
              variant="ghost"
              size="sm"
              class="!py-0.5 !bg-[var(--color-bg-hover)] !text-[var(--color-fg-secondary)] inline-flex items-center"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('pause')}
              title="일시정지: 실행 중인 keeper 를 일시 멈춥니다 (running → paused, 현재 turn 은 정상 종료)"
            >일시정지하기<//>
            ` : null}
            ${actionVisibility.canWake
              ? html`<${ActionButton}
                  variant="warn"
                  size="sm"
                  class="!py-0.5 inline-flex items-center"
                  disabled=${directiveLoading.value}
                  onClick=${() => handleDirective('wakeup')}
                  title="깨우기: idle 또는 stuck 상태에서 다음 turn 을 즉시 시도합니다. 실행 중이어도 노출되는 이유는 runtime/oas/turn timeout 같은 stuck signal 이 backend 보다 먼저 frontend 에 보이는 케이스를 다루기 위함입니다."
                >깨우기<//>`
              : null}`}
        ${isPaused && keeper.keepalive_running
          ? html`<span>하트비트는 유지되지만 자율 행동은 멈춰 있습니다.</span>`
          : null}
        ${hbStale
          ? html`<${RuntimeBadge} tone="bad">하트비트 끊김</${RuntimeBadge}>
            <span>마지막 하트비트: <${TimeAgo} timestamp=${keeper.last_heartbeat} /></span>`
          : null}
        ${runtimeBlockerClass
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
        ${stopCause && stopCauseCode && isTurnTerminalFailureCode(stopCauseCode)
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">정지 원인</strong> · ${stopCauseCode}${stopCauseSummary ? ` · ${stopCauseSummary}` : ''}</span>`
          : null}
        ${latestTerminalCode && latestTerminalCode !== stopCauseCode && !suppressStaleLatestTerminal
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">종료 코드</strong> · ${latestTerminalCode}${latestTerminalSummary ? ` · ${latestTerminalSummary}` : ''}</span>`
          : null}
        ${latestNextAction && !duplicatesAttentionReason(latestNextAction)
          ? html`<span title=${latestNextAction}><strong class="text-[var(--color-fg-secondary)]">권장 조치</strong> · ${nextHumanActionLabel(latestNextAction)}</span>`
          : null}
        ${shouldShowOperatorDispositionReason && operatorDispositionReason
          ? html`<span><${StrongSecondary}>운영자 판단</${StrongSecondary}> · ${operatorDispositionReason}</span>`
          : null}
        ${trustDisposition
          ? html`
              <span class="inline-flex items-center rounded-[var(--r-0)] px-2 py-0.5 text-2xs font-semibold ${trustToneClass}">
                검증 ${trustDispositionDisplay}
              </span>
            `
          : null}
        ${runtimeLabel
          ? html`<span><strong class="text-[var(--color-fg-secondary)]">런타임</strong> · ${runtimeLabel}</span>`
          : null}
        ${renderRuntimeAttempt ? renderRuntimeAttemptObservation(runtimeAttempt) : null}
        ${latestRuntimeMetric?.fallback_applied === true && (fallbackReason || fallbackHops > 0)
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
