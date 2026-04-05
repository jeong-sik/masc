// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// Redesigned: professional dashboard-grade layout with Tailwind inline styles.

import { html } from 'htm/preact'
import { isOfflineStatus } from '../lib/status-utils'
import { keeperDisplayStatus } from '../lib/keeper-runtime-display'
import { signal } from '@preact/signals'
import { useRef } from 'preact/hooks'
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
import { AgentJournalStream } from './agent-detail-journal'
import { KeeperTrajectoryTimeline } from './keeper-trajectory-timeline'
import { DialogOverlay } from './common/dialog'
import { CollapsibleSection } from './common/collapsible'
import { SessionTraceView } from './session-trace/session-trace-view'

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

// ── Status Badge (colored pill) ──────────────────────────

function statusColor(status: string): { bg: string; text: string; dot: string } {
  switch (status.trim().toLowerCase()) {
    case 'active':
    case 'running':
      return { bg: 'bg-[var(--ok-10)]', text: 'text-[var(--ok)]', dot: 'bg-[var(--ok)]' }
    case 'working':
      return { bg: 'bg-[var(--ok-10)]', text: 'text-[#7ae09a]', dot: 'bg-[#7ae09a]' }
    case 'idle':
    case 'quiet':
      return { bg: 'bg-[rgba(251,191,36,0.12)]', text: 'text-[var(--warn)]', dot: 'bg-[#fbbf24]' }
    case 'paused':
    case 'blocked':
      return { bg: 'bg-[rgba(251,191,36,0.12)]', text: 'text-[var(--warn)]', dot: 'bg-[#fbbf24]' }
    case 'offline':
    case 'inactive':
      return { bg: 'bg-[rgba(148,163,184,0.12)]', text: 'text-[#94a3b8]', dot: 'bg-[#64748b]' }
    case 'unbooted':
      return { bg: 'bg-[rgba(148,163,184,0.08)]', text: 'text-[#64748b]', dot: 'bg-[#475569]' }
    case 'stopped':
      return { bg: 'bg-[rgba(239,68,68,0.08)]', text: 'text-[#fb7185]', dot: 'bg-[#f43f5e]' }
    case 'error':
    case 'critical':
      return { bg: 'bg-[rgba(239,68,68,0.12)]', text: 'text-[var(--bad)]', dot: 'bg-[var(--bad)]' }
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
      ` : null}

      <div class="flex flex-col gap-4">
        <div class="w-full">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder=${isOffline ? '키퍼 오프라인 — 기동 필요' : '이 키퍼에게 직접 프롬프트 전송'}
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

// ── Profile field (label + value inline) ────────────────

function ProfileField({ label, value, color }: { label: string; value: string; color: string }) {
  return html`
    <div class="flex items-start gap-2 text-xs text-[var(--text-muted)]">
      <span class="flex-shrink-0">${label}:</span>
      <span class="font-medium leading-relaxed" style="color: ${color}">${value}</span>
    </div>
  `
}

// ── Supervisor Diagnostics Panel ────────────────────────

function registryStateBadge(state: string | null) {
  if (!state) return null
  const colors: Record<string, { bg: string; text: string }> = {
    Running: { bg: 'bg-[rgba(34,197,94,0.12)]', text: 'text-[var(--ok)]' },
    Crashed: { bg: 'bg-[rgba(239,68,68,0.15)]', text: 'text-[var(--bad)]' },
    Dead: { bg: 'bg-[rgba(100,116,139,0.15)]', text: 'text-[#94a3b8]' },
    Stopped: { bg: 'bg-[rgba(234,179,8,0.12)]', text: 'text-[var(--warn)]' },
    Paused: { bg: 'bg-[var(--white-10)]', text: 'text-[var(--purple)]' },
  }
  const c = colors[state] ?? { bg: 'bg-[rgba(138,163,211,0.1)]', text: 'text-[#86a0cf]' }
  return html`<span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-semibold ${c.bg} ${c.text}">${state}</span>`
}

function CrashCohortBar({ crash_log }: { crash_log: any[] }) {
  if (!crash_log || crash_log.length === 0) return null
  const cohorts: Record<string, number> = {}
  for (const e of crash_log) {
    const reason = (e.reason ?? 'unknown') as string
    const key = reason.startsWith('heartbeat') ? 'heartbeat'
      : reason.startsWith('turn') ? 'turn'
      : reason.startsWith('fiber') ? 'fiber'
      : reason.startsWith('exception') ? 'exception'
      : 'other'
    cohorts[key] = (cohorts[key] ?? 0) + 1
  }
  const total = crash_log.length
  const colors: Record<string, string> = {
    heartbeat: '#f59e0b', turn: '#ef4444', fiber: '#8b5cf6',
    exception: '#ec4899', other: '#6b7280',
  }
  return html`
    <div>
      <div class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] mb-2">장애 유형 분포</div>
      <div class="flex w-full h-3 rounded-full overflow-hidden bg-[var(--white-5)]">
        ${Object.entries(cohorts).map(([key, count]) => html`
          <div style="width: ${(count / total * 100).toFixed(1)}%; background: ${colors[key] ?? '#6b7280'}"
               title="${key}: ${count}건 (${(count / total * 100).toFixed(0)}%)"
               class="h-full"></div>
        `)}
      </div>
      <div class="flex flex-wrap gap-x-3 gap-y-1 mt-1.5">
        ${Object.entries(cohorts).map(([key, count]) => html`
          <span class="text-[10px] text-[var(--text-muted)] flex items-center gap-1">
            <span class="inline-block w-2 h-2 rounded-full" style="background: ${colors[key] ?? '#6b7280'}"></span>
            ${key} ${count}
          </span>
        `)}
      </div>
    </div>
  `
}

function SpEventsPanel({ sp_events }: { sp_events: any[] }) {
  if (!sp_events || sp_events.length === 0) return null
  return html`
    <div>
      <div class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] mb-2">자기 보호 발동 이력</div>
      <div class="space-y-1 max-h-28 overflow-y-auto">
        ${sp_events.slice(0, 10).map((e: any) => html`
          <div class="flex items-center justify-between py-1 px-2 rounded text-[11px] bg-[rgba(139,92,246,0.06)]">
            <span class="font-mono text-[var(--text-muted)]">${new Date((e.ts ?? 0) * 1000).toLocaleTimeString()}</span>
            <span class="text-[#8b5cf6]">${e.suppressed_count}/${e.total} 억제 (${e.dominant_cohort})</span>
          </div>
        `)}
      </div>
    </div>
  `
}

function SupervisorDiagnosticsPanel({ keeper }: { keeper: Keeper }) {
  const diag = (keeper as any).supervisor_diagnostics
  if (!diag) return null
  const { restart_count, max_restarts, crash_log, last_failure_reason, dead_since, sp_events, health_score, dead_eta_sec } = diag
  const budgetPct = max_restarts > 0 ? Math.min(100, (restart_count / max_restarts) * 100) : 0
  const budgetColor = budgetPct >= 80 ? '#ef4444' : budgetPct >= 50 ? '#f59e0b' : '#4ade80'
  const hs = typeof health_score === 'number' ? health_score : 100
  const hsColor = hs >= 80 ? '#4ade80' : hs >= 50 ? '#f59e0b' : '#ef4444'
  return html`
    <${SectionCard} title="감독 진단">
      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <span class="text-xs text-[var(--text-muted)]">건강도</span>
          <span class="text-sm font-bold font-mono" style="color: ${hsColor}">${hs}</span>
        </div>
        <div class="flex items-center justify-between">
          <span class="text-xs text-[var(--text-muted)]">실행 상태</span>
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
        ${typeof dead_eta_sec === 'number' && dead_eta_sec > 0 && dead_since == null ? html`
          <div class="flex items-center justify-between">
            <span class="text-xs text-[var(--text-muted)]">종료 예상</span>
            <span class="text-[11px] font-mono" style="color: ${budgetPct >= 50 ? '#f59e0b' : 'var(--text-body)'}">${dead_eta_sec >= 3600 ? (dead_eta_sec / 3600).toFixed(1) + 'h' : (dead_eta_sec / 60).toFixed(0) + 'm'} 후</span>
          </div>
        ` : null}
        ${last_failure_reason ? html`
          <div class="flex items-center justify-between">
            <span class="text-xs text-[var(--text-muted)]">마지막 실패 원인</span>
            <span class="text-[11px] font-mono text-[#fb7185]">${last_failure_reason}</span>
          </div>
        ` : null}
        ${dead_since ? html`
          <div class="py-2 px-3 rounded-lg bg-[rgba(239,68,68,0.06)] border border-[rgba(239,68,68,0.15)] text-xs text-[#fb7185]">
            ${new Date(dead_since * 1000).toLocaleString()} 이후 중단됨. 재기동 필요.
          </div>
        ` : null}
        <${CrashCohortBar} crash_log=${crash_log} />
        ${crash_log && crash_log.length > 0 ? html`
          <div>
            <div class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] mb-2">장애 이력</div>
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
        <${SpEventsPanel} sp_events=${sp_events} />
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
                <${KeeperStatusPill} status=${effectiveStatus} />
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
              ${keeper.koreanName ? html`<span class="text-xs text-[var(--text-muted)]">${keeper.koreanName}</span>` : null}
            </div>
          </div>
          <div class="flex items-center gap-2">
            ${(() => {
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

        <${KeeperRuntimeAlertStrip} keeper=${keeper} />

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

        ${'' /* ── Live journal stream ── */}
        <${AgentJournalStream} agentName=${keeper.name} />

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

            ${'' /* ── Timestamps ── */}
            <div class="mt-3 flex flex-col gap-1">
              ${keeper.last_heartbeat
                ? html`<div class="flex items-center gap-2 text-xs text-[var(--text-muted)]">
                    <span>마지막 하트비트:</span>
                    <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                  </div>`
                : null}
              ${keeper.created_at
                ? html`<div class="flex items-center gap-2 text-xs text-[var(--text-muted)]">
                    <span>생성일:</span>
                    <${TimeAgo} timestamp=${keeper.created_at} />
                  </div>`
                : null}
            </div>

            ${'' /* ── Recent activity preview ── */}
            ${keeper.recent_output_preview
              ? html`
                <div class="mt-3 py-2 px-3 rounded-lg bg-[rgba(71,184,255,0.06)] border border-[rgba(71,184,255,0.12)] text-xs text-[var(--text-body)] leading-relaxed">
                  <div class="text-[10px] font-semibold text-[var(--accent)] uppercase tracking-wider mb-1">최근 출력</div>
                  <div class="line-clamp-3">${keeper.recent_output_preview}</div>
                </div>
              `
              : null}

            ${'' /* ── K2K social stats ── */}
            ${(keeper.k2k_count ?? 0) > 0 || (keeper.conversation_tail_count ?? 0) > 0
              ? html`
                <div class="mt-3 flex flex-wrap gap-2">
                  ${(keeper.k2k_count ?? 0) > 0
                    ? html`<span class="inline-flex items-center gap-1 text-[11px] px-2 py-1 rounded-md bg-[rgba(167,139,250,0.08)] border border-[rgba(167,139,250,0.15)] text-[var(--text-muted)]">
                        K2K 소통 <span class="font-mono font-medium text-[#a78bfa]">${keeper.k2k_count}</span>회
                      </span>`
                    : null}
                  ${(keeper.conversation_tail_count ?? 0) > 0
                    ? html`<span class="inline-flex items-center gap-1 text-[11px] px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-muted)]">
                        대화 <span class="font-mono font-medium">${keeper.conversation_tail_count}</span>건
                      </span>`
                    : null}
                </div>
              `
              : null}

            ${keeper.memory_recent_note
              ? html`
                <div class="mt-3 py-2 px-3 rounded-lg bg-[rgba(167,139,250,0.06)] border border-[rgba(167,139,250,0.12)] text-xs text-[var(--text-body)] leading-relaxed">
                  <div class="text-[10px] font-semibold text-[#a78bfa] uppercase tracking-wider mb-1">메모리 노트</div>
                  ${keeper.memory_recent_note}
                </div>
              `
              : null}

            ${'' /* ── Last speech act ── */}
            ${keeper.last_speech_act
              ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>최근 행동:</span>
                  <span class="font-mono text-[11px] px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-body)]">${keeper.last_speech_act}</span>
                </div>`
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
              <${KeeperTrajectoryTimeline} keeperName=${keeper.name} keeper=${keeper} />
            <//>
          </div>

          <div class="md:col-span-2">
            <${CollapsibleSection} title="통합 활동 추적" badge=${html`<span class="text-[10px] text-[var(--text-dim)] font-normal ml-1">공지 + 태스크 + 도구 호출</span>`}>
              <${SessionTraceView} agentName=${keeper.name} isKeeper=${true} keeperStatus=${keeper.status} keeperGeneration=${keeper.generation} />
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
            원시 데이터 (디버그)
          </summary>
          <div class="mt-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md">
            <${RawDataDebug} keeper=${keeper} />
          </div>
        </details>

        </div>
    <//>
  `
}
