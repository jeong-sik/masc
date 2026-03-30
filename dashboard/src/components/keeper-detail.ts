// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// Redesigned: professional dashboard-grade layout with Tailwind inline styles.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useRef } from 'preact/hooks'
import { currentDashboardActor, runOperatorAction } from '../api'
import { bootKeeper, shutdownKeeper } from '../api/keeper'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { selectKeeper } from '../keeper-runtime'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { showToast } from './common/toast'
import {
  ContextChart,
  EquipmentList,
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
import { KeeperConfigPanel, resetKeeperConfig } from './keeper-config-panel'
import { PipelineStageBar } from './keeper-pipeline-stage'
import { KeeperTrajectoryTimeline } from './keeper-trajectory-timeline'
import { DialogOverlay } from './common/dialog'
import { CollapsibleSection } from './common/collapsible'
import { SessionTraceView } from './session-trace/session-trace-view'

// ── Global overlay state ──────────────────────────────────

export const selectedKeeper = signal<Keeper | null>(null)

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  selectKeeper(k.name)
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
      target_type: 'room',
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

// ── Status Badge (colored pill) ──────────────────────────

function statusColor(status: string): { bg: string; text: string; dot: string } {
  switch (status.trim().toLowerCase()) {
    case 'active':
    case 'running':
      return { bg: 'bg-[rgba(74,222,128,0.12)]', text: 'text-[#4ade80]', dot: 'bg-[#4ade80]' }
    case 'working':
      return { bg: 'bg-[rgba(74,222,128,0.12)]', text: 'text-[#7ae09a]', dot: 'bg-[#7ae09a]' }
    case 'idle':
    case 'quiet':
      return { bg: 'bg-[rgba(251,191,36,0.12)]', text: 'text-[#fbbf24]', dot: 'bg-[#fbbf24]' }
    case 'offline':
    case 'inactive':
      return { bg: 'bg-[rgba(148,163,184,0.12)]', text: 'text-[#94a3b8]', dot: 'bg-[#64748b]' }
    case 'error':
    case 'critical':
      return { bg: 'bg-[rgba(239,68,68,0.12)]', text: 'text-[#ef4444]', dot: 'bg-[#ef4444]' }
    default:
      return { bg: 'bg-[rgba(138,163,211,0.1)]', text: 'text-[#86a0cf]', dot: 'bg-[#86a0cf]' }
  }
}

function KeeperStatusPill({ status }: { status: string }) {
  const c = statusColor(status)
  return html`
    <span class="inline-flex items-center gap-1.5 py-1 px-3 rounded-full text-xs font-medium ${c.bg} ${c.text}">
      <span class="size-2 rounded-full ${c.dot}"></span>
      ${status}
    </span>
  `
}

// ── Comms Panel ──────────────────────────────────────────

function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  return html`
    <div class="border-t border-[var(--border-slate-12)] pt-5">
      <h3 class="m-0 mb-3 text-[13px] font-semibold text-[var(--text-strong)] uppercase tracking-[0.06em]">직접 통신</h3>

      <div class="flex flex-col gap-4">
        <div class="w-full">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder="이 키퍼에게 직접 프롬프트 전송"
          />
        </div>

        <details class="group">
          <summary class="cursor-pointer py-2.5 px-4 text-xs text-[var(--text-muted)] tracking-wider uppercase list-none select-none rounded-lg hover:bg-[var(--white-3)] transition-colors">런타임 진단</summary>
          <div class="flex flex-col gap-3 px-4 pb-4 pt-2">
            <${KeeperDiagnosticSummary} keeper=${keeper} />
            <${KeeperRuntimeActions}
              actor=${currentDashboardActor()}
              keeper=${keeper}
              onSocialSweep=${() => { void runSocialSweep() }}
            />
          </div>
        </details>
      </div>
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

// ── Supervisor Diagnostics Panel ────────────────────────

function registryStateBadge(state: string | null) {
  if (!state) return null
  const colors: Record<string, { bg: string; text: string }> = {
    Running: { bg: 'bg-[rgba(34,197,94,0.12)]', text: 'text-[#4ade80]' },
    Crashed: { bg: 'bg-[rgba(239,68,68,0.15)]', text: 'text-[#ef4444]' },
    Dead: { bg: 'bg-[rgba(100,116,139,0.15)]', text: 'text-[#94a3b8]' },
    Stopped: { bg: 'bg-[rgba(234,179,8,0.12)]', text: 'text-[#facc15]' },
    Paused: { bg: 'bg-[rgba(168,85,247,0.12)]', text: 'text-[#c084fc]' },
  }
  const c = colors[state] ?? { bg: 'bg-[rgba(138,163,211,0.1)]', text: 'text-[#86a0cf]' }
  return html`<span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-semibold ${c.bg} ${c.text}">${state}</span>`
}

function SupervisorDiagnosticsPanel({ keeper }: { keeper: Keeper }) {
  const diag = (keeper as any).supervisor_diagnostics
  if (!diag) return null
  const { restart_count, max_restarts, crash_log, last_failure_reason, dead_since } = diag
  const budgetPct = max_restarts > 0 ? Math.min(100, (restart_count / max_restarts) * 100) : 0
  const budgetColor = budgetPct >= 80 ? '#ef4444' : budgetPct >= 50 ? '#f59e0b' : '#4ade80'
  return html`
    <${SectionCard} title="Supervisor 진단">
      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <span class="text-xs text-[var(--text-muted)]">Fiber 상태</span>
          ${registryStateBadge((keeper as any).registry_state)}
        </div>
        <div>
          <div class="flex items-center justify-between mb-1">
            <span class="text-xs text-[var(--text-muted)]">재시작 예산</span>
            <span class="text-xs font-mono text-[var(--text-body)]">${restart_count}/${max_restarts}</span>
          </div>
          <div class="w-full h-1.5 rounded-full bg-[var(--white-5)] overflow-hidden">
            <div class="h-full rounded-full transition-all duration-300" style="width: ${budgetPct}%; background: ${budgetColor}"></div>
          </div>
        </div>
        ${last_failure_reason ? html`
          <div class="flex items-center justify-between">
            <span class="text-xs text-[var(--text-muted)]">마지막 실패 원인</span>
            <span class="text-[11px] font-mono text-[#fb7185]">${last_failure_reason}</span>
          </div>
        ` : null}
        ${dead_since ? html`
          <div class="py-2 px-3 rounded-lg bg-[rgba(239,68,68,0.06)] border border-[rgba(239,68,68,0.15)] text-xs text-[#fb7185]">
            Dead since ${new Date(dead_since * 1000).toLocaleString()}. Reboot 필요.
          </div>
        ` : null}
        ${crash_log && crash_log.length > 0 ? html`
          <div>
            <div class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] mb-2">Crash 이력</div>
            <div class="space-y-1 max-h-32 overflow-y-auto">
              ${crash_log.slice(0, 10).map((e: any) => html`
                <div class="flex items-center justify-between py-1 px-2 rounded text-[11px] bg-[var(--white-3)]">
                  <span class="font-mono text-[var(--text-muted)]">${new Date((e.ts ?? 0) * 1000).toLocaleTimeString()}</span>
                  <span class="text-[#fb7185]">${e.reason ?? 'unknown'}</span>
                </div>
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
  const keeper = selectedKeeper.value
  if (!keeper) return null
  const closeButtonRef = useRef<HTMLButtonElement>(null)
  const titleId = `keeper-detail-title-${keeper.name}`

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
                <${KeeperStatusPill} status=${keeper.status} />
                ${(() => {
                  const series = keeper.metrics_series ?? []
                  const lastUsed = series.length > 0 ? series[series.length - 1]?.model_used : null
                  const display = lastUsed || keeper.active_model || keeper.model
                  return display ? html`
                    <span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-mono bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.2)]"
                      title=${lastUsed && keeper.model ? `마지막 호출: ${lastUsed}\n설정: ${keeper.model}` : ''}
                    >${display}</span>
                  ` : null
                })()}
              </div>
              ${keeper.koreanName ? html`<span class="text-xs text-[var(--text-muted)]">${keeper.koreanName}</span>` : null}
            </div>
          </div>
          <div class="flex items-center gap-2">
            ${(() => {
              const isOffline = ['offline', 'inactive', 'dead', 'crashed'].includes(keeper.status)
              const isRunning = ['active', 'running', 'idle', 'busy', 'listening', 'working'].includes(keeper.status)
              if (isOffline) return html`
                <button type="button"
                  class="py-1 px-3 rounded-lg text-[11px] font-semibold cursor-pointer border border-[rgba(34,197,94,0.4)] bg-[rgba(34,197,94,0.08)] text-[#4ade80] hover:bg-[rgba(34,197,94,0.15)] transition-colors"
                  onClick=${() => {
                    void bootKeeper(keeper.name).then(res => {
                      if (res.ok) {
                        showToast(keeper.name + ' booted', 'success')
                        void refreshDashboard({ force: true })
                      } else showToast(res.error ?? 'Boot 실패', 'error')
                    }).catch(() => showToast('Boot 실패', 'error'))
                  }}
                >Boot</button>`
              if (isRunning) return html`
                <button type="button"
                  class="py-1 px-3 rounded-lg text-[11px] font-semibold cursor-pointer border border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)] text-[#fb7185] hover:bg-[rgba(239,68,68,0.15)] transition-colors"
                  onClick=${() => {
                    if (confirm(keeper.name + ' 키퍼를 종료합니까?')) {
                      void shutdownKeeper(keeper.name).then(() => {
                        showToast(keeper.name + ' 종료됨', 'success')
                        void refreshDashboard({ force: true })
                      }).catch(() => showToast('종료 실패', 'error'))
                    }
                  }}
                >Shutdown</button>`
              return null
            })()}
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

        ${'' /* ── Body ── */}
        <div class="p-6 flex flex-col gap-6">

        ${'' /* ── Pipeline stage indicator ── */}
        <${PipelineStageBar} stage=${keeper.pipeline_stage} />

        ${'' /* ── KPIs ── */}
        <${KpiGrid} keeper=${keeper} />

        ${'' /* ── Context chart ── */}
        <${ContextChart} keeper=${keeper} />

        ${'' /* ── Supervisor diagnostics ── */}
        <${SupervisorDiagnosticsPanel} keeper=${keeper} />

        ${'' /* ── Latency / Cost / Model charts ── */}
        <${MetricsCharts} keeper=${keeper} />

        ${'' /* ── Direct conversation ── */}
        <${KeeperCommsPanel} keeper=${keeper} />

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
            ${keeper.last_heartbeat
              ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>마지막 하트비트:</span>
                  <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                </div>`
              : null}
            ${keeper.memory_recent_note
              ? html`
                <div class="mt-3 py-2 px-3 rounded-lg bg-[rgba(167,139,250,0.06)] border border-[rgba(167,139,250,0.12)] text-xs text-[var(--text-body)] leading-relaxed">
                  ${keeper.memory_recent_note}
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

          <div class="md:col-span-2">
            <${SectionCard} title="도구 호출 궤적">
              <${KeeperTrajectoryTimeline} keeperName=${keeper.name} />
            <//>
          </div>

          <div class="md:col-span-2">
            <${CollapsibleSection} title="통합 활동 추적" badge=${html`<span class="text-[10px] text-[var(--text-dim)] font-normal ml-1">브로드캐스트 + 태스크 + 도구 호출</span>`}>
              <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} />
            <//>
          </div>

          <${SectionCard} title="품질 시그널">
            <${RuntimeSignals} keeper=${keeper} />
          <//>

          <${SectionCard} title="인근 환경 & 도구 감사">
            <${KeeperNeighborhood} keeper=${keeper} />
          <//>

          <${SectionCard} title="설정">
            <${KeeperConfigPanel} keeperName=${keeper.name} />
          <//>
        </div>

        ${'' /* ── Raw Data (Debug) — collapsed by default ── */}
        <details class="mt-4">
          <summary class="cursor-pointer py-3 px-4 text-[11px] font-semibold uppercase tracking-widest text-[var(--text-muted)] list-none select-none rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] hover:bg-[var(--white-6)] transition-colors flex items-center gap-2">
            <span class="w-1.5 h-1.5 rounded-full bg-[var(--text-dim)]"></span>
            Raw Data (Debug)
          </summary>
          <div class="mt-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md">
            <${RawDataDebug} keeper=${keeper} />
          </div>
        </details>

        </div>
    <//>
  `
}
