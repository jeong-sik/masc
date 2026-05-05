// Keeper detail surface — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline.
// Uses route-driven full-screen detail inside monitoring/agents.

import { html } from 'htm/preact'
import { isOfflineStatus } from '../lib/status-utils'
import {
  keeperActivityDisplay,
  keeperDisplayModel,
  keeperDisplayStatus,
  keeperRuntimeBlockerHint,
} from '../lib/keeper-runtime-display'
import { signal } from '@preact/signals'
import { useEffect, useRef, useState } from 'preact/hooks'
import { ActionButton } from './common/button'
import { requestConfirm } from './common/confirm-dialog'
import { isRecord } from './common/normalize'
import { currentDashboardActor, runOperatorAction } from '../api'
import {
  bootKeeper,
  clearKeeper,
  fetchKeeperTransitions,
  pauseKeeper,
  resumeKeeper,
  shutdownKeeper,
  wakeKeeper,
} from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import { Checkbox } from './common/checkbox'
import { TextArea } from './common/input'
import { SectionHeader } from './common/section-header'
import type { Keeper } from '../types'
import { invalidateDashboardCache, refreshDashboard, keepers } from '../store'
import { hydrateKeeperStatus, selectKeeper } from '../keeper-runtime'
import { activeKeeperName, keeperStatusDetails } from '../keeper-state'
import { registerKeeperTurnRefresh } from '../sse-store'
import { findKeeper } from '../lib/keeper-utils'
import { resolveKeeperForDetail } from '../lib/keeper-detail-resolution'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { formatDuration } from './mission-utils'
import { showToast } from './common/toast'
import { purgeAgent } from '../api/actions'
import {
  ContextChart,
  CtxCompositionPanel,
  EquipmentList,
  InferenceTelemetryPanel,
  KpiGrid,
  MetricsCharts,
  PromptTelemetryPanel,
  RawDataDebug,
  RelationshipList,
  TokenTrendChart,
  TraitsList,
} from './keeper-detail-panels'
import {
  KeeperNeighborhood,
  RuntimeSignals,
  TurnBudgetSection,
} from './keeper-detail-runtime'
import {
  KeeperConfigPanel,
  loadKeeperConfig,
  resetKeeperConfig,
} from './keeper-config-panel'
import { PipelineStageBar } from './keeper-pipeline-stage'
import { KeeperConditionsDivergent } from './keeper-conditions-divergent'
import { KeeperStateDiagramPanel } from './keeper-state-diagram'
import { KeeperMemoryTierPanel } from './keeper-memory-tier-panel'
import { AgentJournalStream } from './agent-detail-journal'
import { DialogOverlay } from './common/dialog'
import { SessionTraceView } from './session-trace/session-trace-view'
import { KeeperToolTelemetry } from './keeper-tool-telemetry'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import { SupervisorDiagnosticsPanel } from './keeper-supervisor-diagnostics'
import { KeeperEvalQualityPanel } from './keeper-eval-quality'
import { KeeperBDIPanel } from './keeper-bdi-panel'
import { PanelCard } from './common/panel-card'
import { CollapsibleSection } from './common/collapsible'
import {
  KeeperDetailHeaderInfo,
  KeeperDetailMissingState,
  KeeperDetailOverviewSidebar,
  KeeperDetailSection,
} from './keeper-detail-shell'
import {
  GenerationLineagePanel,
  KeeperCheckpointPanel,
  MonoBadge,
} from './keeper-detail-history'
import { navigate, route } from '../router'
import { StatusDot } from './common/status-dot'

function StrongSecondary({ children }: { children: unknown }) {
  return html`<strong class="text-[var(--color-fg-secondary)]">${children}</strong>`
}

export {
  filterCheckpointHistory,
  lineageTransitionLabel,
  lineageVerdictMeta,
} from './keeper-detail-history'

// ── Route state / fallback selection ──────────────────────

export const selectedKeeper = signal<Keeper | null>(null)

registerKeeperTurnRefresh((keeperName: string) => {
  if (keeperName !== activeKeeperName.value) return
  void hydrateKeeperStatus(keeperName, true)
  void import('./keeper-trajectory-timeline')
    .then(({ loadTrajectory }) => {
      void loadTrajectory(keeperName)
    })
    .catch(err => {
      console.debug('[keeper] trajectory refresh unavailable', err instanceof Error ? err.message : '')
    })
})

function selectedKeeperMatches(keeperName: string): boolean {
  const selected = selectedKeeper.value
  if (!selected) return false
  const trimmed = keeperName.trim()
  return selected.name === trimmed || selected.agent_name === trimmed
}

function baseAgentDirectoryRouteParams(): Record<string, string> {
  if (route.value.tab === 'monitoring' && route.value.params.section === 'agents') {
    const next: Record<string, string> = { ...route.value.params, section: 'agents' }
    delete next.agent
    delete next.keeper
    return next
  }
  return { section: 'agents' }
}

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  selectKeeper(k.name)
  void loadKeeperConfig(k.name)
  navigate('monitoring', { ...baseAgentDirectoryRouteParams(), keeper: k.name })
}

export function clearKeeperDetailSelection(keeperName?: string) {
  if (keeperName && !selectedKeeperMatches(keeperName)) return
  selectedKeeper.value = null
  selectKeeper('')
  resetKeeperConfig()
}

export function closeKeeperDetail() {
  clearKeeperDetailSelection()
  navigate('monitoring', baseAgentDirectoryRouteParams())
}

// ── Helpers ───────────────────────────────────────────────


async function runSocialSweep(): Promise<void> {
  try {
    await runOperatorAction({
      actor: currentDashboardActor(),
      action_type: 'social_sweep',
      target_type: 'root',
      payload: {},
    })
    invalidateDashboardCache()
    await refreshDashboard({ force: true })
    showToast('소셜 스위프 완료', 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : '소셜 스위프 실행 실패'
    showToast(message, 'error')
  }
}

async function refreshAfterRuntimeAction(): Promise<void> {
  invalidateDashboardCache()
  await refreshDashboard({ force: true })
}

function keeperNeedsDiagnosticAttention(keeper: Keeper): boolean {
  if (typeof keeper.needs_attention === 'boolean') return keeper.needs_attention
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  const blocker = keeper.last_blocker?.trim()
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null && hbAgeMs > 300_000
  return keeper.paused
    || keeper.social_model_recognized === false
    || Boolean(runtimeBlocker)
    || Boolean(blocker)
    || hbStale
}

function RuntimeBadge({ tone, children }: { tone: 'warn' | 'bad'; children: unknown }) {
  const toneCls = tone === 'warn'
    ? 'bg-[var(--warn-14)] text-[var(--color-status-warn)]'
    : 'bg-[var(--bad-soft)] text-[var(--color-status-err)]'
  return html`<span class="inline-flex items-center rounded-[var(--r-0)] px-2 py-0.5 text-2xs font-semibold ${toneCls}">${children}</span>`
}

function KeeperRuntimeAlertStrip({ keeper }: { keeper: Keeper }) {
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
  const providerSelectedModel = executionSummary?.provider_selected_model?.trim() || null
  const cascadeOutcome = executionSummary?.cascade_outcome?.trim() || null
  const runtimeModel = keeperDisplayModel(keeper)
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
        || point.cascade_selected_model?.trim()
        || point.cascade_outcome?.trim()
        || point.cascade_name?.trim()
        || typeof point.cascade_attempt_count === 'number'
      ) return point
    }
    return null
  })()
  const observedProviderModel =
    providerSelectedModel
    || latestCascadeMetric?.cascade_selected_model?.trim()
    || latestCascadeMetric?.model_used?.trim()
    || null
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
  const fallbackFrom = latestCascadeMetric?.fallback_from?.trim() || null
  const fallbackTo =
    latestCascadeMetric?.fallback_to?.trim()
    || latestCascadeMetric?.model_used?.trim()
    || null
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
    Boolean(runtimeModel)
    || Boolean(cascadeLabel)
    || Boolean(observedProviderModel)
    || Boolean(observedCascadeOutcome)
    || typeof observedProviderAttempts === 'number'
    || observedProviderFallback === true
    || (latestCascadeMetric?.fallback_applied === true && Boolean(fallbackFrom || fallbackTo))
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
  const runtimeBlockerLabel = runtimeBlockerClass
    ? {
        ambiguous_post_commit_timeout: '커밋 후 응답 없음',
        ambiguous_post_commit_failure: '커밋 후 실패',
        autonomous_slot_wait_timeout: '자율 슬롯 대기 만료',
        admission_queue_wait_timeout: '대기열 진입 만료',
        turn_timeout_after_queue_wait: '대기 후 턴 만료',
        oas_timeout_budget: 'OAS 응답 만료',
        turn_timeout: '턴 응답 만료',
        completion_contract_violation: '완료 계약 위반',
        cascade_exhausted: '캐스케이드 소진',
      }[runtimeBlockerClass]
    : null
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
                ${runtimeBlockerLabel ?? '런타임 차단'}
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
        ${/* Show receipt-level operator cause when it adds detail beyond trustSummary. */
          shouldShowOperatorDispositionReason
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
        ${runtimeModel
          ? html`<span><${StrongSecondary}>${runtimeModel.label}</${StrongSecondary}> · ${runtimeModel.value}</span>`
          : null}
        ${observedProviderModel || observedCascadeOutcome || typeof observedProviderAttempts === 'number'
          ? html`
              <span>
                <strong class="text-[var(--color-fg-secondary)]">프로바이더</strong>
                · ${observedProviderModel ?? observedCascadeOutcome ?? 'observed'}
                ${typeof observedProviderAttempts === 'number' ? ` · ${observedProviderAttempts}회 시도` : ''}
                ${observedProviderFallback === true ? ' · 폴백' : ''}
              </span>
            `
          : null}
        ${latestCascadeMetric?.fallback_applied === true && (fallbackFrom || fallbackTo)
          ? html`
              <span class="text-[var(--color-status-warn)]">
                <strong>폴백 경로</strong>
                · ${fallbackFrom && fallbackTo ? `${fallbackFrom} -> ${fallbackTo}` : (fallbackTo ?? fallbackFrom)}
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

// ── Lifecycle Buttons (boot / shutdown) ─────────────────

function KeeperLifecycleButtons({ keeper, effectiveStatus }: { keeper: Keeper; effectiveStatus: string }) {
  const isOffline = ['offline', 'inactive', 'dead', 'crashed', 'unbooted', 'stopped'].includes(effectiveStatus)
  const isRunning = ['active', 'running', 'idle', 'busy', 'listening', 'working'].includes(effectiveStatus)

  if (isOffline) return html`
    <button type="button"
      class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)] hover:bg-[var(--ok-soft)] transition-colors"
      onClick=${() => {
        void (async () => {
          try {
            const res = await bootKeeper(keeper.name)
            if (res.ok) {
              showToast(keeper.name + ' 기동됨', 'success')
              await refreshAfterRuntimeAction()
            } else {
              showToast(res.error ?? '기동 실패', 'error')
            }
          } catch {
            showToast('기동 실패', 'error')
          }
        })()
      }}
    >기동</button>`

  if (isRunning) return html`
    <button type="button"
      class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors"
      onClick=${() => {
        void (async () => {
          const confirmed = await requestConfirm({
            title: '키퍼 종료',
            message: keeper.name + ' 키퍼를 종료합니까?',
            tone: 'danger'
          })
          if (confirmed) {
            try {
              const res = await shutdownKeeper(keeper.name)
              if (res.ok) {
                showToast(keeper.name + ' 종료됨', 'success')
                await refreshAfterRuntimeAction()
              } else {
                showToast(res.error ?? '종료 실패', 'error')
              }
            } catch {
              showToast('종료 실패', 'error')
            }
          }
        })()
      }}
    >종료</button>`

  return null
}

function KeeperClearContextDialog({
  keeperName,
  open,
  pending,
  reason,
  preserveSystemPrompt,
  onClose,
  onReasonInput,
  onPreserveToggle,
  onSubmit,
}: {
  keeperName: string
  open: boolean
  pending: boolean
  reason: string
  preserveSystemPrompt: boolean
  onClose: () => void
  onReasonInput: (next: string) => void
  onPreserveToggle: (next: boolean) => void
  onSubmit: () => void
}) {
  const reasonRef = useRef<HTMLTextAreaElement>(null)
  const titleId = `keeper-clear-title-${keeperName}`
  const descId = `keeper-clear-desc-${keeperName}`
  if (!open) return null

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      describedBy=${descId}
      onClose=${pending ? () => {} : onClose}
      initialFocusRef=${reasonRef}
      overlayClass="fixed inset-0 z-[80] bg-[var(--dialog-overlay-bg)]/70 backdrop-blur-sm isolate flex items-center justify-center p-4"
      panelClass="w-full max-w-130 rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--dialog-panel-bg)] shadow-[var(--shadow-raised)]"
    >
      <div class="p-5 flex flex-col gap-4">
        <div class="flex flex-col gap-1">
          <h3 id=${titleId} class="m-0 text-lg font-semibold text-[var(--color-fg-secondary)]">키퍼 컨텍스트 비우기</h3>
          <p id=${descId} class="m-0 text-sm leading-relaxed text-[var(--color-fg-muted)]">
            ${keeperName}의 checkpoint 대화와 continuity summary를 비웁니다. 사유는 감사 로그에 남습니다.
          </p>
        </div>

        <label class="flex flex-col gap-2">
          <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">사유</span>
          <${TextArea}
            inputRef=${reasonRef}
            class="!bg-[var(--color-bg-surface)] !min-h-[112px] !text-sm leading-paragraph"
            placeholder="예: stale continuity replay 제거"
            ariaLabel="비우기 사유"
            disabled=${pending}
            value=${reason}
            onInput=${(event: Event) => onReasonInput((event.currentTarget as HTMLTextAreaElement).value)}
          />
        </label>

        <label class="flex items-start gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3 text-xs text-[var(--color-fg-primary)]">
          <${Checkbox}
            class="mt-0.5"
            checked=${preserveSystemPrompt}
            disabled=${pending}
            ariaLabel="system prompt 보존"
            onChange=${(checked: boolean) => onPreserveToggle(checked)}
          />
          <span>
            system prompt는 보존하고 나머지 메시지만 비웁니다.
            <span class="block mt-1 text-[var(--color-fg-muted)]">끄면 system prompt까지 같이 제거합니다.</span>
          </span>
        </label>

        <div class="rounded-[var(--r-1)] border border-[var(--warn-24)] bg-[var(--warn-8)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
          마지막 수단용 액션입니다. 잘못된 continuity가 재주입될 때만 쓰고, 실행 후 즉시 상태를 다시 확인하세요.
        </div>

        <div class="flex items-center justify-end gap-2">
          <${ActionButton}
            variant="ghost"
            size="lg"
            disabled=${pending}
            onClick=${onClose}
          >취소<//>
          <button
            type="button"
            class="px-4 py-2 rounded-[var(--r-1)] text-sm font-medium border border-transparent bg-[var(--color-status-err)] text-white hover:bg-[var(--bad-50)] transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${pending || reason.trim() === ''}
            onClick=${onSubmit}
          >${pending ? '비우는 중...' : '비우기'}</button>
        </div>
      </div>
    <//>
  `
}

// ── Comms Panel ──────────────────────────────────────────

function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  const isOffline = isOfflineStatus(keeper.status)

  return html`
    <div class="border-t border-[var(--color-border-divider)] pt-5">
      <h3 class="m-0 mb-3 text-sm font-semibold text-[var(--color-fg-secondary)] uppercase tracking-[var(--track-sub)]">직접 통신</h3>

      ${isOffline ? html`
        <div class="px-4 py-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-sm text-[var(--color-fg-muted)]">
          이 키퍼는 현재 비활동 상태입니다. 기동 후 메시지를 보낼 수 있습니다.
        </div>
      ` : html`
        <div class="w-full">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder=${'이 키퍼에게 직접 프롬프트 전송'}
          />
        </div>
      `}
    </div>
  `
}


// ── Playground Repos Panel ──────────────────────────────

interface PlaygroundRepo {
  name: string
  branch: string
  latest_commit: string
  shallow: boolean
  last_action: string
  updated_at: string
}

function isPlaygroundRepo(r: unknown): r is PlaygroundRepo {
  if (!isRecord(r)) return false
  return typeof r.name === 'string'
    && typeof r.branch === 'string'
    && typeof r.latest_commit === 'string'
    && typeof r.shallow === 'boolean'
    && typeof r.last_action === 'string'
}

interface PlaygroundPR {
  pr_url: string
  branch: string
  title: string
  draft: boolean
}

function isPlaygroundPR(r: unknown): r is PlaygroundPR {
  if (!isRecord(r)) return false
  return typeof r.pr_url === 'string'
    && typeof r.branch === 'string'
    && typeof r.title === 'string'
    && typeof r.draft === 'boolean'
}

interface PlaygroundWorktree {
  name: string
  path: string
}

function isPlaygroundWorktree(r: unknown): r is PlaygroundWorktree {
  if (!isRecord(r)) return false
  return typeof r.name === 'string' && typeof r.path === 'string'
}

function PlaygroundReposPanel({ keeperName }: { keeperName: string }) {
  const detail = keeperStatusDetails.value[keeperName]
  if (!detail?.rawStatus) return null
  const raw = detail.rawStatus
  if (!isRecord(raw)) return null
  const execCtx = raw.execution_context
  if (!isRecord(execCtx)) return null

  const repos = (Array.isArray(execCtx.playground_repos) ? execCtx.playground_repos : []).filter(isPlaygroundRepo)
  const prs = (Array.isArray(execCtx.pr_history) ? execCtx.pr_history : []).filter(isPlaygroundPR)
  const worktrees = (Array.isArray(execCtx.active_worktrees) ? execCtx.active_worktrees : []).filter(isPlaygroundWorktree)

  if (repos.length === 0 && prs.length === 0 && worktrees.length === 0) return null

  return html`
    <${PanelCard} title="플레이그라운드">
      <div class="flex flex-col gap-3">
        ${repos.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">저장소 (${repos.length})</${SectionHeader}>
            <div class="flex flex-col gap-1.5">
              ${repos.map(r => html`
                <div class="flex items-center gap-3 px-3 py-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium text-[var(--color-fg-secondary)] truncate">${r.name}</span>
                      <${MonoBadge}>${r.branch}</${MonoBadge}>
                      ${r.shallow ? html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--warn-10)] text-[var(--color-status-warn)] border border-[var(--warn-20)]">shallow</span>` : null}
                    </div>
                    <div class="text-3xs text-[var(--color-fg-muted)] font-mono mt-0.5 truncate">${r.latest_commit}</div>
                  </div>
                  <span class="text-3xs text-[var(--color-fg-disabled)] flex-shrink-0">${r.last_action}</span>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${prs.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">PRs (${prs.length})</${SectionHeader}>
            <div class="flex flex-col gap-1.5">
              ${prs.map(pr => html`
                <div class="flex items-center gap-2 px-3 py-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                  <span class="text-xs text-[var(--color-fg-secondary)] truncate flex-1">${pr.title}</span>
                  <${MonoBadge}>${pr.branch}</${MonoBadge}>
                  ${pr.draft ? html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--warn-10)] text-[var(--color-status-warn)] border border-[var(--warn-20)]">draft</span>` : null}
                  <a href=${pr.pr_url} target="_blank" rel="noopener" class="text-3xs text-[var(--color-accent-fg)] hover:underline flex-shrink-0">PR</a>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${worktrees.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">워크트리 (${worktrees.length})</${SectionHeader}>
            <div class="flex flex-wrap gap-1.5">
              ${worktrees.map(w => html`
                <span class="text-3xs font-mono px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]" title=${w.path}>${w.name}</span>
              `)}
            </div>
          </div>
        ` : null}
      </div>
    <//>
  `
}

// ── Main Detail Page ─────────────────────────────────────

export function KeeperDetailPage() {
  const keeperName =
    route.value.tab === 'monitoring' && route.value.params.section === 'agents'
      ? route.value.params.keeper?.trim()
      : ''
  if (!keeperName) return null

  // Resolve the active keeper. See [resolveKeeperForDetail] for semantics.
  const keeper = resolveKeeperForDetail(
    keeperName,
    findKeeper(keeperName),
    selectedKeeper.peek(),
    keepers.value.length,
  )
  if (!keeper) {
    return html`<${KeeperDetailMissingState} keeperName=${keeperName} onClose=${closeKeeperDetail} />`
  }

  const titleId = `keeper-detail-title-${keeper.name}`
  const effectiveStatus = keeperDisplayStatus(keeper)
  const shouldOpenDiagnostics = keeperNeedsDiagnosticAttention(keeper)
  const [diagOpen, setDiagOpen] = useState(shouldOpenDiagnostics)
  const [clearDialogOpen, setClearDialogOpen] = useState(false)
  const [clearReason, setClearReason] = useState('')
  const [preserveSystemPrompt, setPreserveSystemPrompt] = useState(true)
  const [clearPending, setClearPending] = useState(false)
  const [purgePending, setPurgePending] = useState(false)
  const [checkpointRefreshToken, setCheckpointRefreshToken] = useState(0)
  // Latest transition's wall_clock_at_decision, in unix seconds.  Used by
  // the header KeeperPhaseAndStage to render "현재 phase에 머문 시간" without
  // requiring a new backend field — derivation is plan-approved trade-off.
  const [phaseEnteredAtSec, setPhaseEnteredAtSec] = useState<number | null>(null)
  const prevKeeperRef = useRef(keeper.name)
  if (prevKeeperRef.current !== keeper.name) {
    prevKeeperRef.current = keeper.name
    setDiagOpen(shouldOpenDiagnostics)
    setPhaseEnteredAtSec(null)
  }
  useEffect(() => {
    selectedKeeper.value = keeper
    selectKeeper(keeper.name)
    void loadKeeperConfig(keeper.name)
    return () => {
      clearKeeperDetailSelection(keeper.name)
    }
  }, [keeper.name])
  useEffect(() => {
    const controller = new AbortController()
    fetchKeeperTransitions(keeper.name, 1, { signal: controller.signal })
      .then(res => {
        if (controller.signal.aborted) return
        const head = res.transitions?.[0]
        setPhaseEnteredAtSec(
          typeof head?.wall_clock_at_decision === 'number' ? head.wall_clock_at_decision : null,
        )
      })
      .catch(() => {
        // transient fetch failure — leave dwell hidden rather than showing stale
        if (controller.signal.aborted) return
        setPhaseEnteredAtSec(null)
      })
    return () => controller.abort()
  }, [keeper.name, keeper.phase])
  useEffect(() => {
    setClearDialogOpen(false)
    setClearReason('')
    setPreserveSystemPrompt(true)
    setClearPending(false)
  }, [keeper.name])

  const contextRatioPct =
    typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)
      ? `${Math.round(keeper.context_ratio * 100)}%`
      : '정보 없음'
  const effectiveModelMeta = keeperDisplayModel(keeper)
  const effectiveModelLabel = effectiveModelMeta?.label ?? '모델'
  const effectiveModel = effectiveModelMeta?.value ?? '정보 없음'
  const activityDisplay = keeperActivityDisplay(keeper, keeper.agent?.last_seen)

  const submitClearContext = () => {
    void (async () => {
      const trimmedReason = clearReason.trim()
      if (!trimmedReason) {
        showToast('사유를 먼저 적으세요', 'warning')
        return
      }
      setClearPending(true)
      try {
        const res = await clearKeeper(keeper.name, {
          reason: trimmedReason,
          preserve_system_prompt: preserveSystemPrompt,
        })
        if (res.ok) {
          setClearDialogOpen(false)
          setClearReason('')
          setPreserveSystemPrompt(true)
          setCheckpointRefreshToken(token => token + 1)
          showToast(`${keeper.name} 컨텍스트를 비웠습니다`, 'success')
          await refreshAfterRuntimeAction()
        } else {
          showToast(res.error ?? '컨텍스트 비우기 실패', 'error')
        }
      } catch (err) {
        showToast(err instanceof Error ? err.message : '컨텍스트 비우기 실패', 'error')
      } finally {
        setClearPending(false)
      }
    })()
  }

  const submitPurgeKeeper = () => {
    void (async () => {
      const confirmed = await requestConfirm({
        title: '키퍼 완전 삭제',
        message: `${keeper.name}를 완전 삭제합니다.\n런타임 상태, 세션 trace, 인증, metrics와 config/keepers/${keeper.name}.toml까지 함께 제거됩니다.`,
        tone: 'danger',
        confirmText: '완전 삭제',
      })
      if (!confirmed) return
      setPurgePending(true)
      try {
        await purgeAgent(keeper.name)
        closeKeeperDetail()
        showToast(`${keeper.name} 완전 삭제됨`, 'success')
        await refreshAfterRuntimeAction()
      } catch (err) {
        showToast(err instanceof Error ? err.message : '키퍼 삭제 실패', 'error')
      } finally {
        setPurgePending(false)
      }
    })()
  }

  return html`
    <div class="mx-auto flex w-full max-w-[1600px] flex-col gap-5 pb-8">
      <div class="sticky top-0 z-20 overflow-hidden rounded-[var(--r-6)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)] backdrop-blur-xl">
        <div class="flex items-center justify-between gap-4 border-b border-[var(--color-border-default)] px-5 py-4 sm:px-6">
          <${KeeperDetailHeaderInfo}
            keeper=${keeper}
            titleId=${titleId}
            phaseEnteredAtSec=${phaseEnteredAtSec}
            onClose=${closeKeeperDetail}
          />
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors"
              onClick=${() => setClearDialogOpen(true)}
            >비우기</button>
            <button
              type="button"
              disabled=${purgePending}
              class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              onClick=${submitPurgeKeeper}
            >${purgePending ? '삭제 중...' : '완전 삭제'}</button>
            <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${effectiveStatus} />
            <button
              type="button"
              onClick=${() => closeKeeperDetail()}
              class="flex items-center justify-center size-8 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] transition-colors cursor-pointer text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--color-bg-page)]"
              aria-label="키퍼 상세 종료"
            >
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="2" y1="2" x2="12" y2="12"/><line x1="12" y1="2" x2="2" y2="12"/></svg>
            </button>
          </div>
        </div>
      </div>

      <div class="grid gap-5 xl:grid-cols-[280px_minmax(0,1fr)]">
        <${KeeperDetailOverviewSidebar}
          effectiveStatus=${effectiveStatus}
          contextRatioPct=${contextRatioPct}
          effectiveModelLabel=${effectiveModelLabel}
          effectiveModel=${effectiveModel}
          activity=${activityDisplay}
        />

        <div class="order-1 xl:order-2 flex flex-col gap-5">
          <${KeeperRuntimeAlertStrip} keeper=${keeper} />

          <${KeeperDetailSection}
            id="keeper-summary"
            eyebrow="상태 개요"
            title="운영 상태 개요"
            description="상태 기계, 메모리 티어, KPI, 추론/컨텍스트 계측을 먼저 훑어 keeper의 현재 건강도를 빠르게 판단합니다."
          >
        <${PipelineStageBar} stage=${keeper.pipeline_stage} />
        <${CollapsibleSection} title="Phase State Machine">
          <${KeeperStateDiagramPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
        <//>

        <${CollapsibleSection} title="Memory Tier & Compaction">
          <${KeeperMemoryTierPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
        <//>

        ${'' /* ── Divergent conditions (amber banner; renders only when phase lags observed signals) ── */}
        <${KeeperConditionsDivergent} keeper=${keeper} />

        ${'' /* ── KPIs ── */}
        <${KpiGrid} keeper=${keeper} />

        ${'' /* ── Context chart (sparkline only — single-point is covered by KpiGrid) ── */}
        ${(keeper.metrics_series ?? []).length >= 2 ? html`<${ContextChart} keeper=${keeper} />` : null}

        ${'' /* ── Latency / Cost / Model charts ── */}
        <${MetricsCharts} keeper=${keeper} />

        ${'' /* ── Runtime activity summary (promoted from profile) ── */}
        ${keeper.last_heartbeat || keeper.last_speech_act || keeper.recent_output_preview || keeper.memory_recent_note || (keeper.k2k_count ?? 0) > 0
          ? html`
            <div class="flex flex-wrap items-start gap-3 px-1">
              ${keeper.last_heartbeat
                ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                    하트비트 <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                  </span>`
                : null}
              ${keeper.last_speech_act
                ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                    최근 <span class="font-mono text-[var(--color-fg-primary)]">${keeper.last_speech_act}</span>
                  </span>`
                : null}
              ${keeper.social_model_recognized === false
                ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-status-warn)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--warn-24)] bg-[var(--warn-8)]">
                    대화 모델
                    ${keeper.configured_social_model
                      ? html`<span class="font-mono text-[var(--color-fg-primary)]">${keeper.configured_social_model}</span>`
                      : null}
                    ${keeper.configured_social_model && keeper.social_model_fallback
                      ? html`<span>→</span>`
                      : null}
                    ${keeper.social_model_fallback
                      ? html`<span class="font-mono text-[var(--color-fg-primary)]">${keeper.social_model_fallback}</span>`
                      : null}
                  </span>`
                : null}
              ${(keeper.k2k_count ?? 0) > 0
                ? html`<span class="inline-flex items-center gap-1 text-2xs px-2.5 py-1 rounded-[var(--r-1)] bg-[var(--info-soft)] border border-[var(--info-border)] text-[var(--color-fg-muted)]">
                    K2K <span class="font-mono font-medium text-[var(--info-fg)]">${keeper.k2k_count}</span>
                  </span>`
                : null}
              ${keeper.memory_recent_note
                ? html`<span class="text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] truncate max-w-90" title=${keeper.memory_recent_note}>${keeper.memory_recent_note}</span>`
                : null}
            </div>
            ${keeper.recent_output_preview
              ? html`<div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--accent-6)] border border-[var(--accent-12)] text-xs text-[var(--color-fg-primary)] leading-relaxed">
                  <div class="line-clamp-2">${keeper.recent_output_preview}</div>
                </div>`
              : null}
          `
          : null}

        ${'' /* ── Per-turn token trend (input vs output) ── */}
        <${TokenTrendChart} keeper=${keeper} />

        ${'' /* ── CTX composition by category ── */}
        <${CtxCompositionPanel} keeper=${keeper} />

        ${'' /* ── Prompt fingerprint / segment telemetry ── */}
        <${PromptTelemetryPanel} keeper=${keeper} />

        ${'' /* ── Inference Telemetry (tok/s, cache, reasoning) ── */}
        <${InferenceTelemetryPanel} keeper=${keeper} />
          <//>

          <${KeeperDetailSection}
            id="keeper-comms"
            eyebrow="대화 & 세션"
            title="대화 / 활동 흐름"
            description="운영자가 keeper와 바로 대화하고, 같은 화면에서 세션 이벤트를 대조할 수 있도록 묶었습니다."
          >
            <${KeeperCommsPanel} keeper=${keeper} />
            <${PanelCard} title="세션 활동 로그">
              <div class="text-2xs text-[var(--color-fg-muted)] mb-3">현재 세션의 도구 호출, 태스크 완료, 메시지 등 이벤트 기록</div>
              <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} keeperStatus=${keeper.status} keeperGeneration=${keeper.generation} />
            <//>
          <//>

          <${KeeperDetailSection}
            id="keeper-runtime"
            eyebrow="런타임 진단"
            title="진단 / 운영"
            description="eval, supervisor, 복구 액션, tool audit, 품질 시그널을 한 군데로 모아 원인 파악과 개입을 빠르게 합니다."
          >
            <${KeeperToolTelemetry} keeperName=${keeper.name} />
            <${KeeperEvalQualityPanel} keeperName=${keeper.name} />
            <${CollapsibleSection}
              title="런타임 진단"
              open=${diagOpen}
              onToggle=${(open: boolean) => setDiagOpen(open)}
            >
              <div class="flex flex-col gap-3">
                <${SupervisorDiagnosticsPanel} keeper=${keeper} />
                <${KeeperDiagnosticSummary} keeper=${keeper} />
                <${KeeperRuntimeActions}
                  actor=${currentDashboardActor()}
                  keeper=${keeper}
                  onSocialSweep=${() => { void runSocialSweep() }}
                />
                <div class="pt-3 border-t border-[var(--color-border-divider)]">
                  <${SectionHeader} size="xs" class="mb-3">호출 검사기</${SectionHeader}>
                  ${diagOpen ? html`<${KeeperToolCallInspector} keeperName=${keeper.name} />` : null}
                </div>
              </div>
            <//>
            <${CollapsibleSection} title="품질 시그널 (고급 지표)">
              <div class="mt-3 text-2xs text-[var(--color-fg-muted)] mb-3">폴백 비율, 정렬 품질, 자율 행동 비율 등 metrics_window 기반 런타임 품질 지표</div>
              <${RuntimeSignals} keeper=${keeper} />
            <//>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-identity"
            eyebrow="신원 & 계보"
            title="정체성 / 세대"
            description="프로필, 관계, 장비, generation lineage, checkpoints를 하나의 맥락으로 보고 continuity를 해석합니다."
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <${PanelCard} title="프로필">
            <${TraitsList} traits=${keeper.traits ?? []} label="특성" />
            <${TraitsList} traits=${keeper.interests ?? []} label="관심사" />
            ${keeper.primaryValue
              ? html`<div class="flex items-center gap-2 mt-3 text-xs text-[var(--color-fg-muted)]">
                  <span class="text-[var(--color-fg-muted)]">핵심 가치:</span>
                  <span class="font-medium text-[var(--color-status-ok)]">${keeper.primaryValue}</span>
                </div>`
              : null}
            ${keeper.skill_primary
              ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--color-fg-muted)]">
                  <span>스킬 경로:</span>
                  <span class="font-medium text-[var(--cyan)]">${keeper.skill_primary}</span>
                </div>`
              : null}
            ${keeper.skill_reason
              ? html`<div class="text-2xs text-[var(--color-fg-muted)] mt-1 leading-relaxed">${keeper.skill_reason}</div>`
              : null}

            <${KeeperBDIPanel}
              will=${keeper.will}
              needs=${keeper.needs}
              desires=${keeper.desires}
              short_goal=${keeper.short_goal}
              mid_goal=${keeper.mid_goal}
              long_goal=${keeper.long_goal}
              goal_horizons=${keeper.goal_horizons}
            />
              <//>

          ${keeper.inventory && keeper.inventory.length > 0
            ? html`
              <${PanelCard} title="장비 (${keeper.inventory.length})">
                <${EquipmentList} items=${keeper.inventory} />
              <//>
            `
            : null}

          ${keeper.relationships && Object.keys(keeper.relationships).length > 0
            ? html`
              <${PanelCard} title="관계 (${Object.keys(keeper.relationships).length})">
                <${RelationshipList} rels=${keeper.relationships} />
              <//>
            `
            : null}

          <${GenerationLineagePanel} keeperName=${keeper.name} />
            </div>

          <${CollapsibleSection} title="Checkpoint & Snapshots">
            <div class="mt-4">
              <${KeeperCheckpointPanel}
                keeperName=${keeper.name}
                refreshToken=${checkpointRefreshToken}
              />
            </div>
          <//>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-config"
            eyebrow="설정"
            title="설정 / 작업 방식"
            description="분산되어 있던 허용 도구 목록, 작업 budget, playground repo, keeper config를 한 섹션으로 모았습니다."
          >
            <${TurnBudgetSection} keeper=${keeper} />
            <${CollapsibleSection} title="허용 도구">
              <div class="mt-3">
                <${KeeperNeighborhood} keeper=${keeper} />
              </div>
            <//>
            <${PlaygroundReposPanel} keeperName=${keeper.name} />
            <${CollapsibleSection} title="Keeper 설정">
              <div class="mt-4">
                <${KeeperConfigPanel} keeperName=${keeper.name} />
              </div>
            <//>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-debug"
            eyebrow="디버그"
            title="디버그"
            description="운영 중에는 덜 자주 보지만, 문제를 깊게 파고들 때 필요한 raw surface를 마지막에 모았습니다."
          >
            <details class="mt-0">
          <summary class="cursor-pointer py-3 px-4 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] list-none select-none rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:bg-[var(--color-bg-hover)] transition-colors flex items-center gap-2">
            <${StatusDot} size="xs" class="bg-[var(--color-fg-disabled)]" />
            디버그
          </summary>
          <div class="mt-2 flex flex-col gap-4">
            <div class="p-5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] backdrop-blur-sm">
              <${SectionHeader} size="xs" class="mb-3">저널</${SectionHeader}>
              <${AgentJournalStream} agentName=${keeper.name} />
            </div>
            <div class="p-5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] backdrop-blur-sm">
              <${SectionHeader} size="xs" class="mb-3">원시 데이터</${SectionHeader}>
              <${RawDataDebug} keeper=${keeper} />
            </div>
          </div>
        </details>
          <//>

        <${KeeperClearContextDialog}
          keeperName=${keeper.name}
          open=${clearDialogOpen}
          pending=${clearPending}
          reason=${clearReason}
          preserveSystemPrompt=${preserveSystemPrompt}
          onClose=${() => {
            if (clearPending) return
            setClearDialogOpen(false)
          }}
          onReasonInput=${setClearReason}
          onPreserveToggle=${setPreserveSystemPrompt}
          onSubmit=${submitClearContext}
        />
        </div>
      </div>
    </div>
  `
}
