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
} from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { hydrateKeeperStatus, selectKeeper } from '../keeper-runtime'
import { activeKeeperName, keeperStatusDetails } from '../keeper-state'
import { registerKeeperTurnRefresh } from '../sse-store'
import { findKeeper } from '../lib/keeper-utils'
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
import { KeeperDetailSectionCard as SectionCard } from './keeper-detail-layout'
import {
  KeeperDetailHeaderInfo,
  KeeperDetailMissingState,
  KeeperDetailOverviewSidebar,
  KeeperDetailSection,
} from './keeper-detail-shell'
import {
  GenerationLineagePanel,
  KeeperCheckpointPanel,
} from './keeper-detail-history'
import { navigate, route } from '../router'
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
  const trustDisposition = keeper.trust?.disposition?.trim() || null
  const trustSummary =
    keeper.trust?.attention_reason?.trim()
    || keeper.trust?.disposition_reason?.trim()
    || keeper.trust?.execution_summary?.mutation_guard_summary?.trim()
    || null
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
  const trustLatestEvent = keeper.trust?.latest_causal_event ?? null
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null && hbAgeMs > 300_000 // 5 minutes
  const needsAttention = keeperNeedsDiagnosticAttention(keeper)
  const activity = keeperActivityDisplay(keeper, keeper.agent?.last_seen)
  const hasActivitySignal = activity.timestamp != null || activity.ageSeconds != null
  const renderActivitySignal = () => activity.timestamp
    ? html`${activity.label} <${TimeAgo} timestamp=${activity.timestamp} />`
    : activity.ageSeconds != null
      ? html`${activity.label} ${formatDuration(activity.ageSeconds)} 전`
      : null
  if (!needsAttention && !hasActivitySignal) return null

  const directiveLoading = signal(false)
  const handleDirective = async (action: 'pause' | 'resume') => {
    directiveLoading.value = true
    try {
      const fn = action === 'pause' ? pauseKeeper : resumeKeeper
      const res = await fn(keeper.name)
      if (res.ok) {
        showToast(action === 'pause' ? `${keeper.name} 일시정지됨` : `${keeper.name} 재개됨`, 'success')
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
    : 'border-[var(--card-border)] bg-[var(--white-3)]'
  const runtimeBlockerLabel = runtimeBlockerClass
    ? {
        ambiguous_post_commit_timeout: 'Post-commit timeout',
        ambiguous_post_commit_failure: 'Post-commit failure',
        autonomous_slot_wait_timeout: 'Autonomous slot wait timeout',
        admission_queue_wait_timeout: 'Admission queue wait timeout',
        turn_timeout_after_queue_wait: 'Turn timeout after queue wait',
        oas_timeout_budget: 'OAS timeout budget',
        turn_timeout: 'Turn timeout',
        completion_contract_violation: 'Completion contract violation',
        cascade_exhausted: 'Cascade exhausted',
      }[runtimeBlockerClass]
    : null
  const trustToneClass =
    trustDisposition === 'Alert'
      ? 'bg-[var(--bad-soft)] text-[var(--bad)]'
      : trustDisposition === 'Pause' || keeper.trust?.needs_attention
        ? 'bg-[var(--warn-14)] text-[var(--warn)]'
        : trustDisposition === 'Pass'
          ? 'bg-[var(--ok-10)] text-[var(--ok)]'
          : 'bg-[var(--white-6)] text-[var(--text-strong)]'

  return html`
    <div class="px-6 pt-4">
      <div class="rounded border ${toneClass} px-4 py-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-xs text-[var(--text-body)]" role="status" aria-label="키퍼 상태 경고">
        ${keeper.paused
          ? html`<span class="inline-flex items-center rounded-sm px-2 py-0.5 text-2xs font-semibold bg-[var(--warn-14)] text-[var(--warn)]">일시정지</span>
            ${hasActivitySignal ? html`<span class="text-[var(--text-muted)]">${renderActivitySignal()}</span>` : null}
            <button type="button"
              class="inline-flex items-center rounded px-2 py-0.5 text-2xs font-medium bg-[var(--white-6)] hover:bg-[var(--white-8)] text-[var(--text-strong)] transition-colors disabled:opacity-50"
              aria-label="키퍼 재개"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('resume')}
            >재개</button>`
          : html`<button type="button"
              class="inline-flex items-center rounded px-2 py-0.5 text-2xs font-medium bg-[var(--white-6)] hover:bg-[var(--white-8)] text-[var(--text-strong)] transition-colors disabled:opacity-50"
              aria-label="키퍼 일시정지"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('pause')}
            >일시정지</button>`}
        ${keeper.paused && keeper.keepalive_running && continueGate
          ? html`<span>하트비트는 유지되지만 승인 전까지 자동 재개하지 않습니다.</span>`
          : keeper.paused && keeper.keepalive_running
            ? html`<span>하트비트는 유지되지만 자율 행동은 멈춰 있습니다.</span>`
          : null}
        ${hbStale
          ? html`<span class="inline-flex items-center rounded-sm px-2 py-0.5 text-2xs font-semibold bg-[var(--bad-soft)] text-[var(--bad)]">하트비트 지연</span>
            <span>마지막 하트비트: <${TimeAgo} timestamp=${keeper.last_heartbeat} /></span>`
          : null}
        ${continueGate
          ? html`
              <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-2xs font-semibold bg-[var(--warn-14)] text-[var(--warn)]">
                계속 진행 승인 대기
              </span>
              ${hasActivitySignal ? html`<span class="text-[var(--text-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : socialFallbackActive
          ? html`
              <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-2xs font-semibold bg-[var(--warn-14)] text-[var(--warn)]">
                Social fallback
              </span>
              ${hasActivitySignal ? html`<span class="text-[var(--text-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : runtimeBlockerClass
          ? html`
              <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-2xs font-semibold bg-[var(--bad-soft)] text-[var(--bad)]">
                ${runtimeBlockerLabel ?? 'Runtime blocker'}
              </span>
              ${hasActivitySignal ? html`<span class="text-[var(--text-muted)]">${renderActivitySignal()}</span>` : null}
            `
          : null}
        ${runtimeBlocker
          ? html`<span><strong class="text-[var(--text-strong)]">런타임 차단</strong> · ${runtimeBlocker}</span>`
          : null}
        ${blocker
          ? html`<span><strong class="text-[var(--text-strong)]">차단 요인</strong> · ${blocker}</span>`
          : null}
        ${keeper.last_need
          ? html`<span><strong class="text-[var(--text-strong)]">최근 필요</strong> · ${keeper.last_need}</span>`
          : null}
        ${attentionReason
          ? html`<span><strong class="text-[var(--text-strong)]">주의 사유</strong> · ${attentionReason}</span>`
          : null}
        ${nextHumanAction
          ? html`<span><strong class="text-[var(--text-strong)]">다음 액션</strong> · ${nextHumanAction}</span>`
          : null}
        ${trustDisposition
          ? html`
              <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-2xs font-semibold ${trustToneClass}">
                Trust ${trustDisposition}
              </span>
            `
          : null}
        ${trustSummary
          ? html`<span><strong class="text-[var(--text-strong)]">신뢰</strong> · ${trustSummary}</span>`
          : null}
        ${runtimeProofStatus
          ? html`<span><strong class="text-[var(--text-strong)]">증명</strong> · ${runtimeProofStatus}</span>`
          : null}
        ${requiredTools.length > 0
          ? html`<span><strong class="text-[var(--text-strong)]">필수</strong> · ${requiredTools.join(', ')}</span>`
          : null}
        ${usedTools.length > 0
          ? html`<span><strong class="text-[var(--text-strong)]">사용됨</strong> · ${usedTools.join(', ')}</span>`
          : null}
        ${missingRequiredTools.length > 0
          ? html`<span class="text-[var(--bad)]"><strong>누락</strong> · ${missingRequiredTools.join(', ')}</span>`
          : null}
        ${providerSelectedModel || cascadeOutcome || typeof providerAttempts === 'number'
          ? html`
              <span>
                <strong class="text-[var(--text-strong)]">공급자</strong>
                · ${providerSelectedModel ?? cascadeOutcome ?? '관측됨'}
                ${typeof providerAttempts === 'number' ? ` · ${providerAttempts}회 시도` : ''}
                ${providerFallback === true ? ' · 폴백' : ''}
              </span>
            `
          : null}
        ${trustLatestEvent
          ? html`
              <span>
                <strong class="text-[var(--text-strong)]">최근 trust event</strong>
                · ${trustLatestEvent.title}
                · <${TimeAgo} timestamp=${trustLatestEvent.ts} />
              </span>
            `
          : null}
        ${sandboxTarget
          ? html`<span><strong class="text-[var(--text-strong)]">샌드박스</strong> · ${sandboxTarget}</span>`
          : null}
        ${typeof persistedPolicyCount === 'number'
          ? html`<span><strong class="text-[var(--text-strong)]">항상</strong> · ${persistedPolicyCount} 규칙</span>`
          : null}
        ${typeof goalLinkedTasks === 'number'
          ? html`<span><strong class="text-[var(--text-strong)]">목표 태스크</strong> · ${goalLinkedTasks}</span>`
          : null}
        ${typeof goalConvergence === 'number'
          ? html`<span><strong class="text-[var(--text-strong)]">목표 진행</strong> · ${Math.round(goalConvergence * 100)}%</span>`
          : null}
        ${hasActivitySignal
          ? html`<span><strong class="text-[var(--text-strong)]">최근 신호</strong> · ${renderActivitySignal()}</span>`
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
      aria-label="${keeper.name} 기동"
      class="py-1 px-3 rounded text-2xs font-semibold cursor-pointer border border-[rgba(34,197,94,0.4)] bg-[var(--emerald-8)] text-[var(--ok)] hover:bg-[rgba(34,197,94,0.15)] transition-colors"
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
      aria-label="${keeper.name} 종료"
      class="py-1 px-3 rounded text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors"
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
      overlayClass="fixed inset-0 z-[80] bg-[var(--white-5)]/70 backdrop-blur-sm isolate flex items-center justify-center p-4"
      panelClass="w-full max-w-130 rounded border border-[var(--bad-30)] bg-[rgba(13,21,38,0.98)] shadow-[0_24px_64px_rgba(0,0,0,0.6)]"
    >
      <div class="p-5 flex flex-col gap-4">
        <div class="flex flex-col gap-1">
          <h3 id=${titleId} class="m-0 text-[17px] font-semibold text-[var(--text-strong)]">키퍼 컨텍스트 비우기</h3>
          <p id=${descId} class="m-0 text-sm leading-relaxed text-[var(--text-muted)]">
            ${keeperName}의 checkpoint 대화와 continuity summary를 비웁니다. 사유는 감사 로그에 남습니다.
          </p>
        </div>

        <label class="flex flex-col gap-2" for="keeper-reason-input">
          <span class="text-2xs font-semibold uppercase tracking-1 text-[var(--text-muted)]">사유</span>
          <textarea autoComplete="off"
            id="keeper-reason-input"
            ref=${reasonRef}
            class="min-h-[112px] resize-y rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-2 text-sm leading-paragraph text-[var(--text-body)] outline-none focus:border-[var(--accent-45)] focus:ring-2 focus:ring-[var(--accent-18)]"
            placeholder="예: stale continuity replay 제거"
            disabled=${pending}
            value=${reason}
            onInput=${(event: Event) => onReasonInput((event.currentTarget as HTMLTextAreaElement).value)}
          ></textarea>
        </label>

        <label class="flex items-start gap-3 rounded border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3 text-xs text-[var(--text-body)]">
          <input
            type="checkbox"
            class="mt-0.5"
            checked=${preserveSystemPrompt}
            disabled=${pending}
            onChange=${(event: Event) => onPreserveToggle((event.currentTarget as HTMLInputElement).checked)}
          />
          <span>
            system prompt는 보존하고 나머지 메시지만 비웁니다.
            <span class="block mt-1 text-[var(--text-muted)]">끄면 system prompt까지 같이 제거합니다.</span>
          </span>
        </label>

        <div class="rounded border border-[var(--warn-24)] bg-[var(--warn-8)] px-3 py-2 text-2xs leading-relaxed text-[var(--text-muted)]">
          마지막 수단용 액션입니다. 잘못된 continuity가 재주입될 때만 쓰고, 실행 후 즉시 상태를 다시 확인하세요.
        </div>

        <div class="flex items-center justify-end gap-2">
          <button type="button"
            class="px-4 py-2 rounded text-sm font-medium border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)] hover:bg-[var(--white-8)] transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${pending}
            onClick=${onClose}
          >취소</button>
          <button type="button"
            class="px-4 py-2 rounded text-sm font-medium border border-transparent bg-[var(--bad)] text-white hover:bg-[rgba(239,68,68,0.88)] transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
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
    <div class="border-t border-[var(--border-slate-12)] pt-5">
      <h3 class="m-0 mb-3 text-sm font-semibold text-[var(--text-strong)] uppercase tracking-[0.06em]">직접 통신</h3>

      ${isOffline ? html`
        <div class="px-4 py-3 rounded border border-[var(--card-border)] bg-[rgba(90,100,120,0.08)] text-sm text-[var(--text-muted)]">
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

// ── Profile field (label + value inline) ────────────────

function ProfileField({ label, value, color }: { label: string; value: string; color: string }) {
  return html`
    <div class="flex items-start gap-2 text-xs text-[var(--text-muted)]">
      <span class="flex-shrink-0">${label}:</span>
      <span class="font-medium leading-relaxed" style="color: ${color}">${value}</span>
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
    <${SectionCard} title="플레이그라운드">
      <div class="flex flex-col gap-3">
        ${repos.length > 0 ? html`
          <div>
            <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1.5">저장소 (${repos.length})</div>
            <div class="flex flex-col gap-1.5">
              ${repos.map(r => html`
                <div class="flex items-center gap-3 px-3 py-2 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium text-[var(--text-strong)] truncate" title=${r.name}>${r.name}</span>
                      <span class="text-3xs font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-15)]">${r.branch}</span>
                      ${r.shallow ? html`<span class="text-3xs px-1 py-0.5 rounded bg-[var(--warn-10)] text-[var(--warn)] border border-[var(--warn-20)]">shallow</span>` : null}
                    </div>
                    <div class="text-3xs text-[var(--text-muted)] font-mono mt-0.5 truncate" title=${r.latest_commit}>${r.latest_commit}</div>
                  </div>
                  <span class="text-3xs text-[var(--text-dim)] flex-shrink-0">${r.last_action}</span>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${prs.length > 0 ? html`
          <div>
            <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1.5">PRs (${prs.length})</div>
            <div class="flex flex-col gap-1.5">
              ${prs.map(pr => html`
                <div class="flex items-center gap-2 px-3 py-1.5 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
                  <span class="text-xs text-[var(--text-strong)] truncate flex-1" title=${pr.title}>${pr.title}</span>
                  <span class="text-3xs font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-15)]">${pr.branch}</span>
                  ${pr.draft ? html`<span class="text-3xs px-1 py-0.5 rounded bg-[var(--warn-10)] text-[var(--warn)] border border-[var(--warn-20)]">draft</span>` : null}
                  <a href=${pr.pr_url} target="_blank" rel="noopener noreferrer" class="text-3xs text-[var(--accent)] hover:underline flex-shrink-0">PR<span class="sr-only"> (새 창)</span></a>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${worktrees.length > 0 ? html`
          <div>
            <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1.5">워크트리 (${worktrees.length})</div>
            <div class="flex flex-wrap gap-1.5">
              ${worktrees.map(w => html`
                <span class="text-3xs font-mono px-2 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] text-[var(--text-muted)]" title=${w.path}>${w.name}</span>
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

  const fallback = selectedKeeper.value
  const keeper = findKeeper(keeperName)
    ?? (fallback && (fallback.name === keeperName || fallback.agent_name === keeperName) ? fallback : null)
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
      <div class="sticky top-0 z-20 overflow-hidden rounded-[28px] border border-[var(--card-border)] bg-[rgba(13,21,38,0.96)] shadow-[0_24px_64px_rgba(0,0,0,0.22)] backdrop-blur-xl">
        <div class="flex items-center justify-between gap-4 border-b border-[var(--card-border)] px-5 py-4 sm:px-6">
          <${KeeperDetailHeaderInfo}
            keeper=${keeper}
            titleId=${titleId}
            phaseEnteredAtSec=${phaseEnteredAtSec}
            onClose=${closeKeeperDetail}
          />
          <div class="flex items-center gap-2">
            <button type="button"
              aria-label="${keeper.name} 컨텍스트 비우기"
              class="py-1 px-3 rounded text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors"
              onClick=${() => setClearDialogOpen(true)}
            >비우기</button>
            <button type="button"
              disabled=${purgePending}
              aria-label="${keeper.name} 완전 삭제"
              class="py-1 px-3 rounded text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              onClick=${submitPurgeKeeper}
            >${purgePending ? '삭제 중...' : '완전 삭제'}</button>
            <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${effectiveStatus} />
            <button type="button"
              onClick=${() => closeKeeperDetail()}
              class="flex items-center justify-center size-8 rounded border border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:text-[var(--text-strong)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[#0d1526]"
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
            eyebrow="State Overview"
            title="운영 상태 개요"
            description="상태 기계, 메모리 티어, KPI, 추론/컨텍스트 계측을 먼저 훑어 keeper의 현재 건강도를 빠르게 판단합니다."
          >
        <${PipelineStageBar} stage=${keeper.pipeline_stage} />
        <details class="rounded border border-[var(--white-8)] bg-[var(--white-2)]">
          <summary class="cursor-pointer py-2 px-4 text-2xs font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[rgba(71,184,255,0.5)]" aria-hidden="true"></span>
            Phase State Machine
          </summary>
          <div class="px-4 pb-4 pt-1">
            <${KeeperStateDiagramPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
          </div>
        </details>

        <details class="rounded border border-[var(--white-8)] bg-[var(--white-2)]">
          <summary class="cursor-pointer py-2 px-4 text-2xs font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[rgba(99,102,241,0.5)]" aria-hidden="true"></span>
            Memory Tier & Compaction
          </summary>
          <div class="px-4 pb-4 pt-1">
            <${KeeperMemoryTierPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
          </div>
        </details>

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
                ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--text-muted)] px-2.5 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
                    하트비트 <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                  </span>`
                : null}
              ${keeper.last_speech_act
                ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--text-muted)] px-2.5 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
                    최근 <span class="font-mono text-[var(--text-body)]">${keeper.last_speech_act}</span>
                  </span>`
                : null}
              ${keeper.social_model_recognized === false
                ? html`<span class="inline-flex items-center gap-1.5 text-2xs text-[var(--warn)] px-2.5 py-1 rounded border border-[var(--warn-24)] bg-[var(--warn-8)]">
                    소셜 모델
                    ${keeper.configured_social_model
                      ? html`<span class="font-mono text-[var(--text-body)]">${keeper.configured_social_model}</span>`
                      : null}
                    ${keeper.configured_social_model && keeper.social_model_fallback
                      ? html`<span>→</span>`
                      : null}
                    ${keeper.social_model_fallback
                      ? html`<span class="font-mono text-[var(--text-body)]">${keeper.social_model_fallback}</span>`
                      : null}
                  </span>`
                : null}
              ${(keeper.k2k_count ?? 0) > 0
                ? html`<span class="inline-flex items-center gap-1 text-2xs px-2.5 py-1 rounded bg-[rgba(167,139,250,0.08)] border border-[rgba(167,139,250,0.15)] text-[var(--text-muted)]">
                    K2K <span class="font-mono font-medium text-[var(--purple)]">${keeper.k2k_count}</span>
                  </span>`
                : null}
              ${keeper.memory_recent_note
                ? html`<span class="text-2xs text-[var(--text-muted)] px-2.5 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] truncate max-w-90" title=${keeper.memory_recent_note}>${keeper.memory_recent_note}</span>`
                : null}
            </div>
            ${keeper.recent_output_preview
              ? html`<div class="py-2 px-3 rounded bg-[rgba(71,184,255,0.06)] border border-[var(--accent-12)] text-xs text-[var(--text-body)] leading-relaxed">
                  <div class="line-clamp-2" title=${keeper.recent_output_preview}>${keeper.recent_output_preview}</div>
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
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-comms"
            eyebrow="Conversation & Session"
            title="대화 / 활동 흐름"
            description="운영자가 keeper와 바로 대화하고, 같은 화면에서 세션 이벤트를 대조할 수 있도록 묶었습니다."
          >
            <${KeeperCommsPanel} keeper=${keeper} />
            <${SectionCard} title="세션 활동 로그">
              <div class="text-2xs text-[var(--text-muted)] mb-3">현재 세션의 도구 호출, 태스크 완료, 메시지 등 이벤트 기록</div>
              <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} keeperStatus=${keeper.status} keeperGeneration=${keeper.generation} />
            <//>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-runtime"
            eyebrow="Runtime Diagnostics"
            title="진단 / 운영"
            description="eval, supervisor, 복구 액션, tool audit, 품질 시그널을 한 군데로 모아 원인 파악과 개입을 빠르게 합니다."
          >
            <${KeeperToolTelemetry} keeperName=${keeper.name} />
            <${KeeperEvalQualityPanel} keeperName=${keeper.name} />
            <details
          class="rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm"
          open=${diagOpen}
          onToggle=${(e: Event) => setDiagOpen((e.currentTarget as HTMLDetailsElement).open)}
        >
          <summary class="cursor-pointer py-3 px-5 text-2xs font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
            런타임 진단
          </summary>
          <div class="flex flex-col gap-3 px-5 pb-5 pt-2">
            <${SupervisorDiagnosticsPanel} keeper=${keeper} />
            <${KeeperDiagnosticSummary} keeper=${keeper} />
            <${KeeperRuntimeActions}
              actor=${currentDashboardActor()}
              keeper=${keeper}
              onSocialSweep=${() => { void runSocialSweep() }}
            />
            <div class="pt-3 border-t border-[var(--border-slate-12)]">
              <h4 class="m-0 mb-3 text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">호출 검사기</h4>
              ${diagOpen ? html`<${KeeperToolCallInspector} keeperName=${keeper.name} />` : null}
            </div>
          </div>
        </details>
            <details class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm">
              <summary class="cursor-pointer text-2xs font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
                품질 시그널 (고급 지표)
              </summary>
              <div class="mt-3 text-2xs text-[var(--text-muted)] mb-3">폴백 비율, 정렬 품질, 자율 행동 비율 등 metrics_window 기반 런타임 품질 지표</div>
              <${RuntimeSignals} keeper=${keeper} />
            </details>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-identity"
            eyebrow="Identity & Lineage"
            title="정체성 / 세대"
            description="프로필, 관계, 장비, generation lineage, checkpoints를 하나의 맥락으로 보고 continuity를 해석합니다."
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <${SectionCard} title="프로필">
            <${TraitsList} traits=${keeper.traits ?? []} label="특성" />
            <${TraitsList} traits=${keeper.interests ?? []} label="관심사" />
            ${keeper.primaryValue
              ? html`<div class="flex items-center gap-2 mt-3 text-xs text-[var(--text-muted)]">
                  <span class="text-[var(--text-muted)]">핵심 가치:</span>
                  <span class="font-medium text-[var(--ok)]">${keeper.primaryValue}</span>
                </div>`
              : null}
            ${keeper.skill_primary
              ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>스킬 경로:</span>
                  <span class="font-medium text-[var(--cyan)]">${keeper.skill_primary}</span>
                </div>`
              : null}
            ${keeper.skill_reason
              ? html`<div class="text-2xs text-[var(--text-muted)] mt-1 leading-relaxed">${keeper.skill_reason}</div>`
              : null}

            ${'' /* ── Identity: will / needs / desires ── */}
            ${keeper.will || keeper.needs || keeper.desires
              ? html`
                <div class="mt-3 flex flex-col gap-1.5">
                  ${keeper.will ? html`<${ProfileField} label="의지" value=${keeper.will} color="var(--cyan)" />` : null}
                  ${keeper.needs ? html`<${ProfileField} label="필요" value=${keeper.needs} color="var(--warn)" />` : null}
                  ${keeper.desires ? html`<${ProfileField} label="열망" value=${keeper.desires} color="var(--purple)" />` : null}
                </div>
              `
              : null}
              <//>

          ${keeper.inventory && keeper.inventory.length > 0
            ? html`
              <${SectionCard} title="장비 (${keeper.inventory.length})">
                <${EquipmentList} items=${keeper.inventory} />
              <//>
            `
            : null}

          ${keeper.relationships && Object.keys(keeper.relationships).length > 0
            ? html`
              <${SectionCard} title="관계 (${Object.keys(keeper.relationships).length})">
                <${RelationshipList} rels=${keeper.relationships} />
              <//>
            `
            : null}

          <${GenerationLineagePanel} keeperName=${keeper.name} />
            </div>

          <details class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm">
            <summary class="cursor-pointer text-2xs font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
              Checkpoint & Snapshots
            </summary>
            <div class="mt-4">
              <${KeeperCheckpointPanel}
                keeperName=${keeper.name}
                refreshToken=${checkpointRefreshToken}
              />
            </div>
          </details>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-config"
            eyebrow="Configuration"
            title="설정 / 작업 방식"
            description="분산되어 있던 tool policy, 작업 budget, playground repo, keeper config를 한 섹션으로 모았습니다."
          >
            <${TurnBudgetSection} keeper=${keeper} />
            <details class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm">
              <summary class="cursor-pointer text-2xs font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
                도구 정책
              </summary>
              <div class="mt-3">
                <${KeeperNeighborhood} keeper=${keeper} />
              </div>
            </details>
            <${PlaygroundReposPanel} keeperName=${keeper.name} />
            <details class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm">
              <summary class="cursor-pointer text-2xs font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
                <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
                Keeper 설정
              </summary>
              <div class="mt-4">
                <${KeeperConfigPanel} keeperName=${keeper.name} />
              </div>
            </details>
          </${KeeperDetailSection}>

          <${KeeperDetailSection}
            id="keeper-debug"
            eyebrow="Debug"
            title="디버그"
            description="운영 중에는 덜 자주 보지만, 문제를 깊게 파고들 때 필요한 raw surface를 마지막에 모았습니다."
          >
            <details class="mt-0">
          <summary class="cursor-pointer py-3 px-4 text-2xs font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none rounded border border-[var(--card-border)] bg-[var(--white-3)] hover:bg-[var(--white-6)] transition-colors flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[var(--text-dim)]" aria-hidden="true"></span>
            디버그
          </summary>
          <div class="mt-2 flex flex-col gap-4">
            <div class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm">
              <h4 class="m-0 mb-3 text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">저널</h4>
              <${AgentJournalStream} agentName=${keeper.name} />
            </div>
            <div class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm">
              <h4 class="m-0 mb-3 text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">원시 데이터</h4>
              <${RawDataDebug} keeper=${keeper} />
            </div>
          </div>
        </details>
          </${KeeperDetailSection}>

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
