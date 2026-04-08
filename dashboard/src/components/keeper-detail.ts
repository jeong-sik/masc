// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// Redesigned: professional dashboard-grade layout with Tailwind inline styles.

import { html } from 'htm/preact'
import { isOfflineStatus } from '../lib/status-utils'
import { keeperDisplayStatus } from '../lib/keeper-runtime-display'
import { signal } from '@preact/signals'
import { useRef, useState } from 'preact/hooks'
import { requestConfirm } from './common/confirm-dialog'
import { currentDashboardActor, runOperatorAction } from '../api'
import { bootKeeper, shutdownKeeper } from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { selectKeeper } from '../keeper-runtime'
import { findKeeper } from '../lib/keeper-utils'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { showToast } from './common/toast'
import {
  ContextChart,
  EquipmentList,
  InferenceTelemetryPanel,
  KpiGrid,
  MetricsCharts,
  RawDataDebug,
  RelationshipList,
  TraitsList,
} from './keeper-detail-panels'
import {
  KeeperNeighborhood,
  RuntimeSignals,
} from './keeper-detail-runtime'
import {
  KeeperConfigPanel,
  loadKeeperConfig,
  resetKeeperConfig,
} from './keeper-config-panel'
import { PipelineStageBar } from './keeper-pipeline-stage'
import { KeeperPhaseAndStage } from './keeper-phase-indicator'
import { KeeperStateDiagramPanel } from './keeper-state-diagram'
import { AgentJournalStream } from './agent-detail-journal'
import { DialogOverlay } from './common/dialog'
import { SessionTraceView } from './session-trace/session-trace-view'
import { KeeperToolTelemetry } from './keeper-tool-telemetry'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import { SupervisorDiagnosticsPanel } from './keeper-supervisor-diagnostics'

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
      target_type: 'namespace',
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

function KeeperRuntimeAlertStrip({ keeper }: { keeper: Keeper }) {
  const blocker = keeper.last_blocker?.trim()
  const needsAttention = keeper.paused || Boolean(blocker)
  if (!needsAttention && !keeper.last_autonomous_action_at) return null

  const toneClass = keeper.paused || blocker
    ? 'border-[rgba(251,191,36,0.24)] bg-[rgba(251,191,36,0.08)]'
    : 'border-[var(--card-border)] bg-[var(--white-3)]'

  return html`
    <div class="px-6 pt-4">
      <div class="rounded-xl border ${toneClass} px-4 py-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-[12px] text-[var(--text-body)]">
        ${keeper.paused
          ? html`<span class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold bg-[rgba(251,191,36,0.14)] text-[var(--warn)]">일시정지</span>`
          : null}
        ${keeper.paused && keeper.keepalive_running
          ? html`<span>하트비트는 유지되지만 자율 행동은 멈춰 있습니다.</span>`
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

// ── Main Detail Overlay ─────────────────────────────────

export function KeeperDetailOverlay() {
  const selected = selectedKeeper.value
  if (!selected) return null
  const keeper = findKeeper(selected.name) ?? selected
  const closeButtonRef = useRef<HTMLButtonElement>(null)
  const titleId = `keeper-detail-title-${keeper.name}`
  const effectiveStatus = keeperDisplayStatus(keeper)
  const [diagOpen, setDiagOpen] = useState(false)

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
                <${KeeperPhaseAndStage} phase=${keeper.phase} pipelineStage=${keeper.pipeline_stage} />
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
            <span class="w-1.5 h-1.5 rounded-full bg-[var(--accent)]/50"></span>
            Phase State Machine
          </summary>
          <div class="px-4 pb-4 pt-1">
            <${KeeperStateDiagramPanel} keeperName=${keeper.name} currentPhase=${keeper.phase} />
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

        ${'' /* ── Inference Telemetry (tok/s, cache, reasoning) ── */}
        <${InferenceTelemetryPanel} keeper=${keeper} />
        ${'' /* ── Per-keeper tool telemetry ── */}
        <${KeeperToolTelemetry} keeperName=${keeper.name} />

        ${'' /* ── Direct conversation ── */}
        <${KeeperCommsPanel} keeper=${keeper} />

        ${'' /* ── Runtime diagnostics (supervisor + keeper diagnostics unified) ── */}
        <details class="rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm" onToggle=${(e: Event) => setDiagOpen((e.currentTarget as HTMLDetailsElement).open)}>
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

          <details class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
            <summary class="cursor-pointer text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
              도구 정책
            </summary>
            <div class="mt-3">
              <${KeeperNeighborhood} keeper=${keeper} />
            </div>
          </details>

          <details class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
            <summary class="cursor-pointer text-[11px] font-semibold uppercase tracking-widest text-text-muted list-none select-none flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
              설정
            </summary>
            <div class="mt-4">
              <${KeeperConfigPanel} keeperName=${keeper.name} />
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
    <//>
  `
}
