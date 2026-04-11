// Supervisor diagnostics panel — health score, restart budget,
// crash cohort bar, self-protection events.
// Extracted from keeper-detail.ts to reduce file size.

import { html } from 'htm/preact'
import { formatTimeAgo } from '../lib/format-time'
import type { Keeper, KeeperSupervisorCrashLogEntry } from '../types'

// ── Helpers ──────────────────────────────────────────────

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

function CrashCohortBar({ crash_log }: { crash_log: KeeperSupervisorCrashLogEntry[] }) {
  if (!crash_log || crash_log.length === 0) return null
  const cohorts: Record<string, number> = {}
  for (const e of crash_log) {
    const reason = e.reason ?? 'unknown'
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

interface SpEventLike {
  ts?: number
  suppressed_count?: number
  total?: number
  dominant_cohort?: string
}

function SpEventsPanel({ sp_events }: { sp_events?: unknown[] }) {
  if (!sp_events || sp_events.length === 0) return null
  const entries = sp_events.slice(0, 10) as SpEventLike[]
  return html`
    <div>
      <div class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] mb-2">자기 보호 발동 이력</div>
      <div class="space-y-1 max-h-28 overflow-y-auto">
        ${entries.map((e) => html`
          <div class="flex items-center justify-between py-1 px-2 rounded text-[11px] bg-[rgba(139,92,246,0.06)]">
            <span class="font-mono text-[var(--text-muted)]">${formatTimeAgo(e.ts ?? 0)}</span>
            <span class="text-[#8b5cf6]">${e.suppressed_count ?? 0}/${e.total ?? 0} 억제 (${e.dominant_cohort ?? '--'})</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── Main Panel ──────────────────────────────────────────

export function SupervisorDiagnosticsPanel({ keeper }: { keeper: Keeper }) {
  const diag = keeper.supervisor_diagnostics
  if (!diag) return null
  const {
    restart_count = 0,
    max_restarts = 0,
    crash_log,
    last_failure_reason,
    dead_since,
    sp_events,
    health_score,
    dead_eta_sec,
  } = diag
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
          ${registryStateBadge(null)}
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
            ${formatTimeAgo(dead_since)} 이후 중단됨. 재기동 필요.
          </div>
        ` : null}
        <${CrashCohortBar} crash_log=${crash_log} />
        ${crash_log && crash_log.length > 0 ? html`
          <div>
            <div class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-muted)] mb-2">장애 이력</div>
            <div class="space-y-1 max-h-32 overflow-y-auto">
              ${crash_log.slice(0, 10).map((e: any) => html`
                <div class="flex items-center justify-between py-1 px-2 rounded text-[11px] bg-[var(--white-3)]">
                  <span class="font-mono text-[var(--text-muted)]">${formatTimeAgo(e.ts ?? 0)}</span>
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
