// Supervisor diagnostics panel — health score, restart budget,
// crash cohort bar, self-protection events.
// Extracted from keeper-detail.ts to reduce file size.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatTimeAgo } from '../lib/format-time'
import { FilterChips } from './common/filter-chips'
import { PanelCard } from './common/panel-card'
import { ProgressBar } from './common/progress-bar'
import {
  groupCrashCohorts,
  filterCrashLog,
  CRASH_CATEGORY_KEYS,
  type CrashCategory,
} from './keeper-supervisor-helpers'
import type { Keeper, KeeperSupervisorCrashLogEntry } from '../types'

function MutedLabel({ children }: { children: unknown }) {
  return html`<span class="text-xs text-[var(--color-fg-muted)]">${children}</span>`
}

type CrashFilterKey = 'all' | CrashCategory

// Module-level signals (per-keeper instance ok — panel only renders for active keeper).
const crashCategoryFilter = signal<CrashFilterKey>('all')
const crashShowAll = signal<boolean>(false)

// ── Helpers ──────────────────────────────────────────────

function registryStateBadge(state: string | null) {
  if (!state) return null
  const colors: Record<string, { bg: string; text: string }> = {
    Running: { bg: 'bg-[var(--emerald-12)]', text: 'text-[var(--color-status-ok)]' },
    Crashed: { bg: 'bg-[var(--bad-soft)]', text: 'text-[var(--color-status-err)]' },
    Dead: { bg: 'bg-[var(--white-8)]', text: 'text-[var(--color-fg-muted)]' },
    Stopped: { bg: 'bg-[var(--warn-soft)]', text: 'text-[var(--color-status-warn)]' },
    Paused: { bg: 'bg-[var(--white-10)]', text: 'text-[var(--stalled-fg)]' },
  }
  const c = colors[state] ?? { bg: 'bg-[var(--white-4)]', text: 'text-[var(--color-fg-muted)]' }
  return html`<span class="inline-flex items-center py-0.5 px-2 rounded text-3xs font-semibold ${c.bg} ${c.text}">${state}</span>`
}

const COHORT_COLORS: Record<CrashCategory, string> = {
  heartbeat: 'var(--amber-bright)',
  turn: 'var(--color-status-err)',
  fiber: 'var(--stalled-fg)',
  exception: 'var(--err-fg)',
  other: 'var(--color-fg-muted)',
}

function CrashCohortBar({ crash_log }: { crash_log: KeeperSupervisorCrashLogEntry[] }) {
  if (!crash_log || crash_log.length === 0) return null
  const cohorts = groupCrashCohorts(crash_log)
  const total = crash_log.length
  const entries = CRASH_CATEGORY_KEYS
    .map((key) => [key, cohorts[key] ?? 0] as const)
    .filter(([, count]) => count > 0)
  return html`
    <div>
      <div class="text-3xs font-semibold uppercase tracking-widest text-[var(--color-fg-muted)] mb-2">장애 유형 분포</div>
      <div class="flex w-full h-3 rounded-sm overflow-hidden bg-[var(--white-5)]">
        ${entries.map(([key, count]) => html`
          <div style="width: ${(count / total * 100).toFixed(1)}%; background: ${COHORT_COLORS[key]}"
               title="${key}: ${count}건 (${(count / total * 100).toFixed(0)}%)"
               class="h-full"></div>
        `)}
      </div>
      <div class="flex flex-wrap gap-x-3 gap-y-1 mt-1.5">
        ${entries.map(([key, count]) => html`
          <span class="text-3xs text-[var(--color-fg-muted)] flex items-center gap-1">
            <span class="inline-block w-2 h-2 rounded-full" style="background: ${COHORT_COLORS[key]}" aria-hidden="true"></span>
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
      <div class="text-3xs font-semibold uppercase tracking-widest text-[var(--color-fg-muted)] mb-2">자기 보호 발동 이력</div>
      <div class="space-y-1 max-h-28 overflow-y-auto">
        ${entries.map((e) => html`
          <div class="flex items-center justify-between py-1 px-2 rounded text-2xs bg-[var(--purple-12)]">
            <span class="font-mono text-[var(--color-fg-muted)]">${formatTimeAgo(e.ts ?? 0)}</span>
            <span class="text-[var(--stalled-fg)]">${e.suppressed_count ?? 0}/${e.total ?? 0} 억제 (${e.dominant_cohort ?? '--'})</span>
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
  const budgetFillClass = budgetPct >= 80 ? 'bg-[var(--color-status-err)]' : budgetPct >= 50 ? 'bg-[var(--amber-bright)]' : 'bg-[var(--color-status-ok)]'
  const hs = typeof health_score === 'number' ? health_score : 100
  const hsColor = hs >= 80 ? 'var(--color-status-ok)' : hs >= 50 ? 'var(--amber-bright)' : 'var(--color-status-err)'
  return html`
    <${PanelCard} title="감독 진단">
      <div class="space-y-3">
        <div class="flex items-center justify-between">
          <${MutedLabel}>건강도</${MutedLabel}>
          <span class="text-sm font-bold font-mono" style="color: ${hsColor}">${hs}</span>
        </div>
        <div class="flex items-center justify-between">
          <${MutedLabel}>실행 상태</${MutedLabel}>
          ${registryStateBadge(keeper.registry_state ?? null)}
        </div>
        <div>
          <div class="flex items-center justify-between mb-1">
            <${MutedLabel}>재시작 예산</${MutedLabel}>
            <span class="text-xs font-mono text-[var(--color-fg-primary)]">${restart_count}/${max_restarts}</span>
          </div>
          <${ProgressBar} pct=${budgetPct} size="sm" class=${budgetFillClass} />
        </div>
        ${typeof dead_eta_sec === 'number' && dead_eta_sec > 0 && dead_since == null ? html`
          <div class="flex items-center justify-between">
            <${MutedLabel}>종료 예상</${MutedLabel}>
            <span class="text-2xs font-mono" style="color: ${budgetPct >= 50 ? 'var(--amber-bright)' : 'var(--color-fg-primary)'}">${dead_eta_sec >= 3600 ? (dead_eta_sec / 3600).toFixed(1) + 'h' : (dead_eta_sec / 60).toFixed(0) + 'm'} 후</span>
          </div>
        ` : null}
        ${last_failure_reason ? html`
          <div class="flex items-center justify-between">
            <${MutedLabel}>마지막 실패 원인</${MutedLabel}>
            <span class="text-2xs font-mono text-[var(--rose-light)]">${last_failure_reason}</span>
          </div>
        ` : null}
        ${dead_since ? html`
          <div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--bad-6)] border border-[var(--bad-soft)] text-xs text-[var(--rose-light)]">
            ${formatTimeAgo(dead_since)} 이후 중단됨. 재기동 필요.
          </div>
        ` : null}
        <${CrashCohortBar} crash_log=${crash_log} />
        ${crash_log && crash_log.length > 0 ? (() => {
          const cohorts = groupCrashCohorts(crash_log)
          const filtered = filterCrashLog(crash_log, crashCategoryFilter.value)
          const visible = crashShowAll.value ? filtered : filtered.slice(0, 10)
          const chips: { key: CrashFilterKey; label: string; count: number }[] = [
            { key: 'all', label: '전체', count: crash_log.length },
            ...CRASH_CATEGORY_KEYS
              .filter((k) => (cohorts[k] ?? 0) > 0)
              .map((k) => ({ key: k as CrashFilterKey, label: k, count: cohorts[k] ?? 0 })),
          ]
          return html`
            <div>
              <div class="flex items-center justify-between mb-2">
                <div class="text-3xs font-semibold uppercase tracking-widest text-[var(--color-fg-muted)]">장애 이력</div>
                ${filtered.length > 10 ? html`
                  <button type="button"
                    class="text-3xs font-medium px-2 py-0.5 rounded border border-[var(--white-10)] bg-[var(--white-4)] text-[var(--color-fg-disabled)] hover:bg-[var(--white-8)] hover:text-[var(--color-fg-primary)] transition-colors"
                    onClick=${() => { crashShowAll.value = !crashShowAll.value }}
                    aria-pressed=${crashShowAll.value}>
                    ${crashShowAll.value ? `최근 10건 보기` : `전체 ${filtered.length}건 보기`}
                  </button>
                ` : null}
              </div>
              ${chips.length > 1 ? html`
                <${FilterChips}
                  chips=${chips}
                  active=${crashCategoryFilter}
                  size="sm"
                  tone="accent"
                  class="mb-2"
                />
              ` : null}
              <div class="space-y-1 ${crashShowAll.value ? 'max-h-64' : 'max-h-32'} overflow-y-auto">
                ${visible.length === 0 ? html`
                  <div class="py-2 px-2 text-2xs text-[var(--color-fg-muted)] italic">선택된 카테고리에 해당하는 장애가 없습니다.</div>
                ` : visible.map((e) => html`
                  <div class="flex items-center justify-between py-1 px-2 rounded text-2xs bg-[var(--white-3)]">
                    <span class="font-mono text-[var(--color-fg-muted)]">${formatTimeAgo(e.ts ?? 0)}</span>
                    <span class="text-[var(--rose-light)]">${e.reason ?? 'unknown'}</span>
                  </div>
                `)}
              </div>
            </div>
          `
        })() : null}
        <${SpEventsPanel} sp_events=${sp_events} />
      </div>
    <//>
  `
}
