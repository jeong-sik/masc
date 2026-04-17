// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// Redesigned: professional dashboard-grade layout with Tailwind inline styles.

import { html } from 'htm/preact'
import { isOfflineStatus } from '../lib/status-utils'
import { keeperDisplayStatus, keeperRuntimeBlockerHint } from '../lib/keeper-runtime-display'
import { signal } from '@preact/signals'
import { useEffect, useRef, useState } from 'preact/hooks'
import { requestConfirm } from './common/confirm-dialog'
import { isRecord } from './common/normalize'
import { currentDashboardActor, runOperatorAction } from '../api'
import {
  bootKeeper,
  clearKeeper,
  deleteKeeperHistorySnapshots,
  fetchKeeperCheckpoints,
  fetchKeeperTransitions,
  pauseKeeper,
  resumeKeeper,
  shutdownKeeper,
  type KeeperCheckpointInventory,
  type KeeperCheckpointSummary,
} from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { fetchCascadeProfiles, updateKeeperCascade } from '../api/dashboard'
import { selectKeeper } from '../keeper-runtime'
import { keeperStatusDetails } from '../keeper-state'
import { findKeeper } from '../lib/keeper-utils'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { showToast } from './common/toast'
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
  peekLoadedKeeperConfig,
  resetKeeperConfig,
} from './keeper-config-panel'
import { PipelineStageBar } from './keeper-pipeline-stage'
import { KeeperPhaseAndStage } from './keeper-phase-indicator'
import { KeeperStateDiagramPanel } from './keeper-state-diagram'
import { KeeperMemoryTierPanel } from './keeper-memory-tier-panel'
import { AgentJournalStream } from './agent-detail-journal'
import { DialogOverlay } from './common/dialog'
import { SessionTraceView } from './session-trace/session-trace-view'
import { KeeperToolTelemetry } from './keeper-tool-telemetry'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import { SupervisorDiagnosticsPanel } from './keeper-supervisor-diagnostics'
import { KeeperEvalQualityPanel } from './keeper-eval-quality'

// ── Global overlay state ──────────────────────────────────

export const selectedKeeper = signal<Keeper | null>(null)

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  selectKeeper(k.name)
  void loadKeeperConfig(k.name)
}

export function closeKeeperDetail() {
  selectedKeeper.value = null
  resetKeeperConfig()
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
  const blocker = keeper.last_blocker?.trim()
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null && hbAgeMs > 300_000 // 5 minutes
  const needsAttention = keeperNeedsDiagnosticAttention(keeper)
  if (!needsAttention && !keeper.last_autonomous_action_at) return null

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
    ? 'border-[rgba(251,191,36,0.24)] bg-[rgba(251,191,36,0.08)]'
    : 'border-[var(--card-border)] bg-[var(--white-3)]'
  const runtimeBlockerLabel = runtimeBlockerClass
    ? {
        ambiguous_post_commit_timeout: 'Post-commit timeout',
        ambiguous_post_commit_failure: 'Post-commit failure',
        autonomous_slot_wait_timeout: 'Autonomous slot wait timeout',
        admission_queue_wait_timeout: 'Admission queue wait timeout',
        turn_timeout_after_queue_wait: 'Turn timeout after queue wait',
        turn_timeout: 'Turn timeout',
        completion_contract_violation: 'Completion contract violation',
      }[runtimeBlockerClass]
    : null

  return html`
    <div class="px-6 pt-4">
      <div class="rounded-xl border ${toneClass} px-4 py-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-[12px] text-[var(--text-body)]">
        ${keeper.paused
          ? html`<span class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold bg-[rgba(251,191,36,0.14)] text-[var(--warn)]">일시정지</span>
            <button
              class="inline-flex items-center rounded-md px-2 py-0.5 text-[11px] font-medium bg-[var(--white-6)] hover:bg-[var(--white-8)] text-[var(--text-strong)] transition-colors disabled:opacity-50"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('resume')}
            >재개</button>`
          : html`<button
              class="inline-flex items-center rounded-md px-2 py-0.5 text-[11px] font-medium bg-[var(--white-6)] hover:bg-[var(--white-8)] text-[var(--text-strong)] transition-colors disabled:opacity-50"
              disabled=${directiveLoading.value}
              onClick=${() => handleDirective('pause')}
            >일시정지</button>`}
        ${keeper.paused && keeper.keepalive_running && continueGate
          ? html`<span>하트비트는 유지되지만 승인 전까지 자동 재개하지 않습니다.</span>`
          : keeper.paused && keeper.keepalive_running
            ? html`<span>하트비트는 유지되지만 자율 행동은 멈춰 있습니다.</span>`
          : null}
        ${hbStale
          ? html`<span class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold bg-[rgba(239,68,68,0.14)] text-[var(--bad)]">Heartbeat stale</span>
            <span>마지막 하트비트: <${TimeAgo} timestamp=${keeper.last_heartbeat} /></span>`
          : null}
        ${continueGate
          ? html`
              <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold bg-[rgba(251,191,36,0.14)] text-[var(--warn)]">
                계속 진행 승인 대기
              </span>
            `
          : socialFallbackActive
          ? html`
              <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold bg-[rgba(251,191,36,0.14)] text-[var(--warn)]">
                Social fallback
              </span>
            `
          : runtimeBlockerClass
          ? html`
              <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold bg-[rgba(239,68,68,0.14)] text-[var(--bad)]">
                ${runtimeBlockerLabel ?? 'Runtime blocker'}
              </span>
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
        ${keeper.last_autonomous_action_at
          ? html`<span><strong class="text-[var(--text-strong)]">마지막 행동</strong> · <${TimeAgo} timestamp=${keeper.last_autonomous_action_at} /></span>`
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
      class="py-1 px-3 rounded-lg text-[11px] font-semibold cursor-pointer border border-[rgba(34,197,94,0.4)] bg-[rgba(34,197,94,0.08)] text-[var(--ok)] hover:bg-[rgba(34,197,94,0.15)] transition-colors"
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
      class="py-1 px-3 rounded-lg text-[11px] font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[#fb7185] hover:bg-[rgba(239,68,68,0.15)] transition-colors"
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
      overlayClass="fixed inset-0 z-[80] bg-black/70 backdrop-blur-sm isolate flex items-center justify-center p-4"
      panelClass="w-full max-w-[520px] rounded-2xl border border-[var(--bad-30)] bg-[rgba(13,21,38,0.98)] shadow-[0_24px_64px_rgba(0,0,0,0.6)]"
    >
      <div class="p-5 flex flex-col gap-4">
        <div class="flex flex-col gap-1">
          <h3 id=${titleId} class="m-0 text-[17px] font-semibold text-[var(--text-strong)]">키퍼 컨텍스트 비우기</h3>
          <p id=${descId} class="m-0 text-[13px] leading-relaxed text-[var(--text-muted)]">
            ${keeperName}의 checkpoint 대화와 continuity summary를 비웁니다. 사유는 감사 로그에 남습니다.
          </p>
        </div>

        <label class="flex flex-col gap-2">
          <span class="text-[11px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">사유</span>
          <textarea
            ref=${reasonRef}
            class="min-h-[112px] resize-y rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-2 text-[13px] leading-[1.55] text-[var(--text-body)] outline-none focus:border-[rgba(71,184,255,0.45)] focus:ring-2 focus:ring-[rgba(71,184,255,0.18)]"
            placeholder="예: stale continuity replay 제거"
            disabled=${pending}
            value=${reason}
            onInput=${(event: Event) => onReasonInput((event.currentTarget as HTMLTextAreaElement).value)}
          ></textarea>
        </label>

        <label class="flex items-start gap-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3 text-[12px] text-[var(--text-body)]">
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

        <div class="rounded-xl border border-[rgba(251,191,36,0.24)] bg-[rgba(251,191,36,0.08)] px-3 py-2 text-[11px] leading-relaxed text-[var(--text-muted)]">
          마지막 수단용 액션입니다. 잘못된 continuity가 재주입될 때만 쓰고, 실행 후 즉시 상태를 다시 확인하세요.
        </div>

        <div class="flex items-center justify-end gap-2">
          <button
            type="button"
            class="px-4 py-2 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)] hover:bg-[var(--white-8)] transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${pending}
            onClick=${onClose}
          >취소</button>
          <button
            type="button"
            class="px-4 py-2 rounded-lg text-[13px] font-medium border border-transparent bg-[var(--bad)] text-white hover:bg-[rgba(239,68,68,0.88)] transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${pending || reason.trim() === ''}
            onClick=${onSubmit}
          >${pending ? '비우는 중...' : '비우기'}</button>
        </div>
      </div>
    <//>
  `
}

function formatCheckpointTime(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '-'
  return new Date(timestamp * 1000).toLocaleString('ko-KR', {
    hour12: false,
  })
}

function CheckpointSummaryCard({
  title,
  summary,
}: {
  title: string
  summary: KeeperCheckpointSummary | null
}) {
  if (!summary) {
    return html`
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3 text-[12px] text-[var(--text-muted)]">
        ${title}: 저장된 checkpoint 없음
      </div>
    `
  }

  return html`
    <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-[12px] font-semibold text-[var(--text-strong)]">${title}</span>
        <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold bg-[var(--accent-12)] text-[var(--accent)] border border-[rgba(71,184,255,0.18)]">
          gen ${summary.generation}
        </span>
        <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold border border-[var(--white-8)] bg-[var(--white-3)] text-[var(--text-muted)]">
          ${summary.message_count} msgs
        </span>
        ${summary.system_prompt_present
          ? html`<span class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold border border-emerald-500/20 bg-emerald-500/10 text-emerald-400">system kept</span>`
          : null}
      </div>
      <div class="mt-2 text-[11px] text-[var(--text-muted)]">
        ${formatCheckpointTime(summary.created_at)}
      </div>
      ${summary.latest_preview
        ? html`<div class="mt-2 text-[12px] leading-relaxed text-[var(--text-body)]">${summary.latest_preview}</div>`
        : null}
      ${summary.continuity_summary
        ? html`<pre class="mt-2 whitespace-pre-wrap rounded-lg border border-[var(--white-8)] bg-[rgba(255,255,255,0.03)] px-3 py-2 text-[11px] leading-relaxed text-[var(--text-muted)]">${summary.continuity_summary}</pre>`
        : html`<div class="mt-2 text-[11px] text-[var(--text-dim)]">continuity snapshot 없음</div>`}
    </div>
  `
}

function KeeperCheckpointPanel({ keeperName, refreshToken }: { keeperName: string; refreshToken: number }) {
  const [inventory, setInventory] = useState<KeeperCheckpointInventory | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [deleting, setDeleting] = useState(false)

  const loadInventory = () => {
    void (async () => {
      setLoading(true)
      setError(null)
      try {
        const next = await fetchKeeperCheckpoints(keeperName)
        setInventory(next)
        setSelectedIds(prev =>
          prev.filter(id => next.history.some(item => item.snapshot_id === id)),
        )
      } catch (err) {
        setError(err instanceof Error ? err.message : 'checkpoint inventory load failed')
      } finally {
        setLoading(false)
      }
    })()
  }

  useEffect(() => {
    setInventory(null)
    setSelectedIds([])
    loadInventory()
  }, [keeperName, refreshToken])

  const toggleSnapshot = (snapshotId: string, checked: boolean) => {
    setSelectedIds(prev =>
      checked
        ? (prev.includes(snapshotId) ? prev : [...prev, snapshotId])
        : prev.filter(id => id !== snapshotId),
    )
  }

  const deleteSelected = () => {
    void (async () => {
      if (selectedIds.length === 0) {
        showToast('삭제할 snapshot을 먼저 고르세요', 'warning')
        return
      }
      const confirmed = await requestConfirm({
        title: 'OAS snapshot 삭제',
        message: `${selectedIds.length}개 snapshot history를 삭제합니다.\n현재 active checkpoint는 건드리지 않습니다.`,
        tone: 'danger',
        confirmText: '삭제',
      })
      if (!confirmed) return
      setDeleting(true)
      try {
        const result = await deleteKeeperHistorySnapshots(keeperName, selectedIds)
        setInventory(result.inventory)
        setSelectedIds([])
        const missingSuffix =
          result.missing_snapshot_ids.length > 0
            ? ` (누락 ${result.missing_snapshot_ids.length})`
            : ''
        showToast(`${result.deleted_snapshot_ids.length}개 snapshot 삭제${missingSuffix}`, 'success')
      } catch (err) {
        showToast(err instanceof Error ? err.message : 'snapshot 삭제 실패', 'error')
      } finally {
        setDeleting(false)
      }
    })()
  }

  if (loading) {
    return html`
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-3 text-[12px] text-[var(--text-muted)]">
        checkpoint inventory 로딩 중...
      </div>
    `
  }

  if (error) {
    return html`
      <div class="rounded-xl border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-3 text-[12px] text-[#fda4af]">
        ${error}
        <button
          type="button"
          class="ml-2 rounded border border-[var(--card-border)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] hover:bg-[var(--white-8)] cursor-pointer"
          onClick=${loadInventory}
        >다시 로드</button>
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center justify-between gap-3">
        <div class="text-[11px] text-[var(--text-muted)]">
          current OAS checkpoint와 OAS snapshot history만 노출합니다.
          ${inventory && inventory.legacy_shadow_count > 0
            ? html`<span class="block mt-1 text-amber-300">legacy shadow ${inventory.legacy_shadow_count}개는 picker에서 제외됩니다.</span>`
            : null}
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            class="rounded-lg border border-[var(--card-border)] bg-[var(--white-4)] px-3 py-1.5 text-[11px] font-semibold text-[var(--text-body)] hover:bg-[var(--white-8)] cursor-pointer"
            onClick=${loadInventory}
          >새로고침</button>
          <button
            type="button"
            class="rounded-lg border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-1.5 text-[11px] font-semibold text-[#fb7185] hover:bg-[rgba(239,68,68,0.15)] cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${deleting || selectedIds.length === 0}
            onClick=${deleteSelected}
          >${deleting ? '삭제 중...' : `선택 삭제 (${selectedIds.length})`}</button>
        </div>
      </div>

      <${CheckpointSummaryCard}
        title="현재 active checkpoint"
        summary=${inventory?.current ?? null}
      />

      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)]">
        <div class="border-b border-[var(--card-border)] px-3 py-2 text-[11px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          OAS Snapshot History
        </div>
        ${!inventory || inventory.history.length === 0
          ? html`<div class="px-3 py-3 text-[12px] text-[var(--text-muted)]">저장된 OAS history snapshot이 아직 없습니다.</div>`
          : html`
              <div class="flex flex-col">
                ${inventory.history.map(item => html`
                  <label class="flex gap-3 border-b border-[var(--card-border)] px-3 py-3 text-[12px] last:border-b-0">
                    <input
                      type="checkbox"
                      class="mt-1"
                      checked=${selectedIds.includes(item.snapshot_id)}
                      onChange=${(event: Event) => toggleSnapshot(item.snapshot_id, (event.currentTarget as HTMLInputElement).checked)}
                    />
                    <div class="min-w-0 flex-1">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="font-mono text-[var(--text-strong)]">${item.snapshot_id}</span>
                        <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold bg-[var(--accent-12)] text-[var(--accent)] border border-[rgba(71,184,255,0.18)]">
                          gen ${item.generation}
                        </span>
                        <span class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold border border-[var(--white-8)] bg-[var(--white-3)] text-[var(--text-muted)]">
                          ${item.message_count} msgs
                        </span>
                        ${item.system_prompt_present
                          ? html`<span class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold border border-emerald-500/20 bg-emerald-500/10 text-emerald-400">system kept</span>`
                          : null}
                      </div>
                      <div class="mt-1 text-[11px] text-[var(--text-muted)]">
                        ${formatCheckpointTime(item.created_at)}
                        ${item.file_stat?.size_bytes ? html` · ${(item.file_stat.size_bytes / 1024).toFixed(1)} KB` : null}
                      </div>
                      ${item.latest_preview
                        ? html`<div class="mt-2 text-[12px] leading-relaxed text-[var(--text-body)]">${item.latest_preview}</div>`
                        : null}
                      ${item.continuity_summary
                        ? html`<pre class="mt-2 whitespace-pre-wrap rounded-lg border border-[var(--white-8)] bg-[rgba(255,255,255,0.03)] px-3 py-2 text-[11px] leading-relaxed text-[var(--text-muted)]">${item.continuity_summary}</pre>`
                        : html`<div class="mt-2 text-[11px] text-[var(--text-dim)]">continuity snapshot 없음</div>`}
                    </div>
                  </label>
                `)}
              </div>
            `}
      </div>
    </div>
  `
}

// ── Comms Panel ──────────────────────────────────────────

function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  const isOffline = isOfflineStatus(keeper.status)

  return html`
    <div class="border-t border-[var(--border-slate-12)] pt-5">
      <h3 class="m-0 mb-3 text-[13px] font-semibold text-[var(--text-strong)] uppercase tracking-[0.06em]">직접 통신</h3>

      ${isOffline ? html`
        <div class="px-4 py-3 rounded-xl border border-[var(--card-border)] bg-[rgba(90,100,120,0.08)] text-[13px] text-[var(--text-muted)]">
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

// ── Section Card (detail page variant) ───────────────────

function SectionCard({ title, children }: { title: string; children: preact.ComponentChildren }) {
  return html`
    <div class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm transition-[border-color,box-shadow] duration-200 hover:border-accent/30 hover:shadow-md">
      <div class="text-[11px] font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
        ${title}
      </div>
      ${children}
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
    <${SectionCard} title="Playground">
      <div class="flex flex-col gap-3">
        ${repos.length > 0 ? html`
          <div>
            <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1.5">Repos (${repos.length})</div>
            <div class="flex flex-col gap-1.5">
              ${repos.map(r => html`
                <div class="flex items-center gap-3 px-3 py-2 rounded-lg border border-[var(--white-8)] bg-[var(--white-2)]">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium text-[var(--text-strong)] truncate">${r.name}</span>
                      <span class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--accent)] border border-[rgba(71,184,255,0.15)]">${r.branch}</span>
                      ${r.shallow ? html`<span class="text-[9px] px-1 py-0.5 rounded bg-amber-500/10 text-amber-400 border border-amber-500/20">shallow</span>` : null}
                    </div>
                    <div class="text-[10px] text-[var(--text-muted)] font-mono mt-0.5 truncate">${r.latest_commit}</div>
                  </div>
                  <span class="text-[10px] text-[var(--text-dim)] flex-shrink-0">${r.last_action}</span>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${prs.length > 0 ? html`
          <div>
            <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1.5">PRs (${prs.length})</div>
            <div class="flex flex-col gap-1.5">
              ${prs.map(pr => html`
                <div class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-[var(--white-8)] bg-[var(--white-2)]">
                  <span class="text-xs text-[var(--text-strong)] truncate flex-1">${pr.title}</span>
                  <span class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--accent)] border border-[rgba(71,184,255,0.15)]">${pr.branch}</span>
                  ${pr.draft ? html`<span class="text-[9px] px-1 py-0.5 rounded bg-amber-500/10 text-amber-400 border border-amber-500/20">draft</span>` : null}
                  <a href=${pr.pr_url} target="_blank" rel="noopener" class="text-[10px] text-[var(--accent)] hover:underline flex-shrink-0">PR</a>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${worktrees.length > 0 ? html`
          <div>
            <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-1.5">Worktrees (${worktrees.length})</div>
            <div class="flex flex-wrap gap-1.5">
              ${worktrees.map(w => html`
                <span class="text-[10px] font-mono px-2 py-1 rounded-lg border border-[var(--white-8)] bg-[var(--white-2)] text-[var(--text-muted)]" title=${w.path}>${w.name}</span>
              `)}
            </div>
          </div>
        ` : null}
      </div>
    <//>
  `
}

// ── Main Detail Overlay ─────────────────────────────────

export function KeeperDetailOverlay() {
  const selected = selectedKeeper.value
  if (!selected) return null
  const keeper = findKeeper(selected.name) ?? selected
  const closeButtonRef = useRef<HTMLButtonElement>(null)
  const titleId = `keeper-detail-title-${keeper.name}`
  const effectiveStatus = keeperDisplayStatus(keeper)
  const shouldOpenDiagnostics = keeperNeedsDiagnosticAttention(keeper)
  const [diagOpen, setDiagOpen] = useState(shouldOpenDiagnostics)
  const [clearDialogOpen, setClearDialogOpen] = useState(false)
  const [clearReason, setClearReason] = useState('')
  const [preserveSystemPrompt, setPreserveSystemPrompt] = useState(true)
  const [clearPending, setClearPending] = useState(false)
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

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      onClose=${closeKeeperDetail}
      initialFocusRef=${closeButtonRef}
      overlayClass="keeper-detail-overlay fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      panelClass="w-full max-w-[1100px] max-h-[90vh] overflow-y-auto bg-[#0d1526] rounded-2xl border border-[var(--card-border)] shadow-[0_24px_64px_rgba(0,0,0,0.5)]"
    >

        ${'' /* ── Sticky Header ── */}
        <div class="sticky top-0 z-10 flex items-center justify-between px-6 py-4 border-b border-[var(--card-border)] bg-[rgba(13,21,38,0.97)] backdrop-blur-md rounded-t-2xl">
          <div class="flex items-center gap-4">
            <div class="size-12 rounded-xl bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-2xl">${keeper.emoji}</div>
            <div class="flex flex-col gap-0.5">
              <div class="flex items-center gap-2.5">
                <h2 id=${titleId} class="m-0 text-lg font-semibold text-[var(--text-strong)]">${keeper.name}</h2>
                <${KeeperPhaseAndStage} phase=${keeper.phase} pipelineStage=${keeper.pipeline_stage} phaseEnteredAtSec=${phaseEnteredAtSec} />
                ${(() => {
                  const series = keeper.metrics_series ?? []
                  const lastUsed = series.length > 0 ? series[series.length - 1]?.model_used : null
                  const display = lastUsed || keeper.active_model || keeper.model
                  return display ? html`
                    <span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-mono bg-[var(--accent-12)] text-[var(--accent)] border border-[rgba(71,184,255,0.2)]"
                      title=${lastUsed && keeper.model ? `마지막 호출: ${lastUsed}\n설정: ${keeper.model}` : ''}
                    >${display}</span>
                  ` : null
                })()}
                ${(() => {
                  const preset = peekLoadedKeeperConfig(keeper.name)?.tools?.tool_preset
                  if (!preset) return null
                  // SSOT: config/tool_policy.toml [git_clone.workflow_presets]
                  const canPR = ['coding', 'delivery', 'full'].includes(preset)
                  return html`
                    <span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-semibold uppercase tracking-wide
                      ${canPR
                        ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                        : 'bg-[var(--white-5)] text-[var(--text-muted)] border border-[var(--white-8)]'
                      }"
                      title=${`Tool preset: ${preset}${canPR ? ' (clone/PR 가능)' : ''}`}
                    >${preset}</span>
                  `
                })()}
                ${(() => {
                  const [profiles, setProfiles] = useState<string[]>([])
                  const [currentCascade, setCurrentCascade] = useState(keeper.cascade_name || 'default')
                  if (profiles.length === 0) {
                    fetchCascadeProfiles().then(r => setProfiles(r.profiles)).catch(() => {})
                  }
                  if (profiles.length <= 1) return null
                  return html`
                    <select
                      class="py-0.5 px-1 rounded text-[10px] font-mono bg-[var(--white-5)] text-[var(--text-muted)] border border-[var(--white-8)] cursor-pointer"
                      title="Cascade profile"
                      value=${currentCascade}
                      onChange=${(e: Event) => {
                        const val = (e.target as HTMLSelectElement).value
                        setCurrentCascade(val)
                        updateKeeperCascade(keeper.name, val).then(() => {
                          refreshDashboard()
                        })
                      }}
                    >
                      ${profiles.map(p => html`<option value=${p}>${p}</option>`)}
                    </select>
                  `
                })()}
              </div>
              ${keeper.koreanName || keeper.created_at ? html`
                <div class="flex items-center gap-2 text-xs text-[var(--text-muted)]">
                  ${keeper.koreanName ? html`<span>${keeper.koreanName}</span>` : null}
                  ${keeper.created_at ? html`<span class="font-mono tabular-nums opacity-60"><${TimeAgo} timestamp=${keeper.created_at} /></span>` : null}
                </div>
              ` : null}
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="py-1 px-3 rounded-lg text-[11px] font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[#fb7185] hover:bg-[rgba(239,68,68,0.15)] transition-colors"
              onClick=${() => setClearDialogOpen(true)}
            >비우기</button>
            <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${effectiveStatus} />
            <button
              ref=${closeButtonRef}
              type="button"
              onClick=${() => closeKeeperDetail()}
              class="flex items-center justify-center size-8 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:text-[var(--text-strong)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[#0d1526]"
              aria-label="키퍼 상세 닫기"
            >
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="2" y1="2" x2="12" y2="12"/><line x1="12" y1="2" x2="2" y2="12"/></svg>
            </button>
          </div>
        </div>

        <${KeeperRuntimeAlertStrip} keeper=${keeper} />

        ${'' /* ── Body ── */}
        <div class="p-6 flex flex-col gap-6">

        ${'' /* ── Pipeline stage + Phase state diagram ── */}
        <${PipelineStageBar} stage=${keeper.pipeline_stage} />
        <details class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)]">
          <summary class="cursor-pointer py-2 px-4 text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[rgba(71,184,255,0.5)]"></span>
            Phase State Machine
          </summary>
          <div class="px-4 pb-4 pt-1">
            <${KeeperStateDiagramPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
          </div>
        </details>

        <details class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)]">
          <summary class="cursor-pointer py-2 px-4 text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[rgba(99,102,241,0.5)]"></span>
            Memory Tier & Compaction
          </summary>
          <div class="px-4 pb-4 pt-1">
            <${KeeperMemoryTierPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
          </div>
        </details>

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
                ? html`<span class="inline-flex items-center gap-1.5 text-[11px] text-[var(--text-muted)] px-2.5 py-1 rounded-lg border border-[var(--white-8)] bg-[var(--white-2)]">
                    하트비트 <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                  </span>`
                : null}
              ${keeper.last_speech_act
                ? html`<span class="inline-flex items-center gap-1.5 text-[11px] text-[var(--text-muted)] px-2.5 py-1 rounded-lg border border-[var(--white-8)] bg-[var(--white-2)]">
                    최근 <span class="font-mono text-[var(--text-body)]">${keeper.last_speech_act}</span>
                  </span>`
                : null}
              ${keeper.social_model_recognized === false
                ? html`<span class="inline-flex items-center gap-1.5 text-[11px] text-[var(--warn)] px-2.5 py-1 rounded-lg border border-[rgba(251,191,36,0.24)] bg-[rgba(251,191,36,0.08)]">
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
                ? html`<span class="inline-flex items-center gap-1 text-[11px] px-2.5 py-1 rounded-lg bg-[rgba(167,139,250,0.08)] border border-[rgba(167,139,250,0.15)] text-[var(--text-muted)]">
                    K2K <span class="font-mono font-medium text-[#a78bfa]">${keeper.k2k_count}</span>
                  </span>`
                : null}
              ${keeper.memory_recent_note
                ? html`<span class="text-[11px] text-[var(--text-muted)] px-2.5 py-1 rounded-lg border border-[var(--white-8)] bg-[var(--white-2)] truncate max-w-[360px]" title=${keeper.memory_recent_note}>${keeper.memory_recent_note}</span>`
                : null}
            </div>
            ${keeper.recent_output_preview
              ? html`<div class="py-2 px-3 rounded-lg bg-[rgba(71,184,255,0.06)] border border-[rgba(71,184,255,0.12)] text-xs text-[var(--text-body)] leading-relaxed">
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
        ${'' /* ── Per-keeper tool telemetry ── */}
        <${KeeperToolTelemetry} keeperName=${keeper.name} />

        ${'' /* ── Eval Quality (RFC-MASC-005 Phase 3) ── */}
        <${KeeperEvalQualityPanel} keeperName=${keeper.name} />

        ${'' /* ── Direct conversation ── */}
        <${KeeperCommsPanel} keeper=${keeper} />

        ${'' /* ── Runtime diagnostics (supervisor + keeper diagnostics unified) ── */}
        <details
          class="rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm"
          open=${diagOpen}
          onToggle=${(e: Event) => setDiagOpen((e.currentTarget as HTMLDetailsElement).open)}
        >
          <summary class="cursor-pointer py-3 px-5 text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
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
              <h4 class="m-0 mb-3 text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">호출 검사기</h4>
              ${diagOpen ? html`<${KeeperToolCallInspector} keeperName=${keeper.name} />` : null}
            </div>
          </div>
        </details>

        ${'' /* ── Detail sections grid ── */}
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
              ? html`<div class="text-[11px] text-[var(--text-muted)] mt-1 leading-relaxed">${keeper.skill_reason}</div>`
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

          ${'' /* ── Activity Trace (promoted to main view) ── */}
          <div class="md:col-span-2">
            <${SectionCard} title="세션 활동 로그">
              <div class="text-[11px] text-[var(--text-muted)] mb-3">현재 세션의 도구 호출, 태스크 완료, 메시지 등 이벤트 기록</div>
              <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} keeperStatus=${keeper.status} keeperGeneration=${keeper.generation} />
            <//>
          </div>

          <details class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
            <summary class="cursor-pointer text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
              품질 시그널 (고급 지표)
            </summary>
            <div class="mt-3 text-[11px] text-[var(--text-muted)] mb-3">폴백 비율, 정렬 품질, 자율 행동 비율 등 metrics_window 기반 런타임 품질 지표</div>
            <${RuntimeSignals} keeper=${keeper} />
          </details>

          <${TurnBudgetSection} keeper=${keeper} />

          <details class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
            <summary class="cursor-pointer text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
              도구 정책
            </summary>
            <div class="mt-3">
              <${KeeperNeighborhood} keeper=${keeper} />
            </div>
          </details>

          <${PlaygroundReposPanel} keeperName=${keeper.name} />

          <details class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
            <summary class="cursor-pointer text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
              설정
            </summary>
            <div class="mt-4">
              <${KeeperConfigPanel} keeperName=${keeper.name} />
            </div>
          </details>

          <details class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
            <summary class="cursor-pointer text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
              Checkpoint & Snapshots
            </summary>
            <div class="mt-4">
              <${KeeperCheckpointPanel}
                keeperName=${keeper.name}
                refreshToken=${checkpointRefreshToken}
              />
            </div>
          </details>
        </div>

        ${'' /* ── Debug (journal + raw data) ── */}
        <details class="mt-4">
          <summary class="cursor-pointer py-3 px-4 text-[11px] font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] hover:bg-[var(--white-6)] transition-colors flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[var(--text-dim)]"></span>
            디버그
          </summary>
          <div class="mt-2 flex flex-col gap-4">
            <div class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md">
              <h4 class="m-0 mb-3 text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">저널</h4>
              <${AgentJournalStream} agentName=${keeper.name} />
            </div>
            <div class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md">
              <h4 class="m-0 mb-3 text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">원시 데이터</h4>
              <${RawDataDebug} keeper=${keeper} />
            </div>
          </div>
        </details>

        </div>

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
    <//>
  `
}
