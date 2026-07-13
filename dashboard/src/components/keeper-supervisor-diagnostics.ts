// Supervisor diagnostics panel — raw restart and crash observations.
// Extracted from keeper-detail.ts to reduce file size.

import { html } from 'htm/preact'
import { formatPct, formatPct1 } from '../lib/format-number'
import { signal } from '@preact/signals'
import { formatTimeAgo } from '../lib/format-time'
import { FilterChips } from './common/filter-chips'
import { PanelCard } from './common/panel-card'
import { failureReasonLabel } from './fsm-hub-types'
import {
  groupCrashCohorts,
  filterCrashLog,
  CRASH_CATEGORY_KEYS,
  type SupervisorCrashCategory,
} from './keeper-supervisor-helpers'
import type { Keeper, KeeperSupervisorCrashLogEntry } from '../types'

function MutedLabel({ children }: { children: unknown }) {
  return html`<span class="text-xs text-[var(--color-fg-muted)]">${children}</span>`
}

type CrashFilterKey = 'all' | SupervisorCrashCategory

// Module-level signals (per-keeper instance ok — panel only renders for active keeper).
const crashCategoryFilter = signal<CrashFilterKey>('all')
const crashShowAll = signal<boolean>(false)

// ── Helpers ──────────────────────────────────────────────

function registryStateBadge(state: string | null) {
  if (!state) return null
  const colors: Record<string, { bg: string; text: string }> = {
    Running: { bg: 'bg-[var(--emerald-12)]', text: 'text-[var(--color-status-ok)]' },
    Crashed: { bg: 'bg-[var(--bad-soft)]', text: 'text-[var(--color-status-err)]' },
    Dead: { bg: 'bg-[var(--color-bg-hover)]', text: 'text-[var(--color-fg-muted)]' },
    Stopped: { bg: 'bg-[var(--warn-soft)]', text: 'text-[var(--color-status-warn)]' },
    Paused: { bg: 'bg-[var(--color-bg-hover)]', text: 'text-[var(--stalled-fg)]' },
  }
  const c = colors[state] ?? { bg: 'bg-[var(--color-bg-elevated)]', text: 'text-[var(--color-fg-muted)]' }
  return html`<span class="inline-flex items-center py-0.5 px-2 rounded-[var(--r-1)] text-3xs font-semibold ${c.bg} ${c.text}">${state}</span>`
}

const COHORT_COLORS: Record<SupervisorCrashCategory, string> = {
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
    <div class="v2-monitoring-panel">
      <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)] mb-2">장애 유형 분포</div>
      <div class="flex w-full h-3 rounded-[var(--r-0)] overflow-hidden bg-[var(--color-bg-elevated)] v2-monitoring-row">
        ${entries.map(([key, count]) => html`
          <div style="width: ${formatPct1(count / total)}; background: ${COHORT_COLORS[key]}"
               title="${key}: ${count}건 (${formatPct(count / total)})"
               class="h-full"></div>
        `)}
      </div>
      <div class="flex flex-wrap gap-x-3 gap-y-1 mt-1.5 v2-monitoring-row">
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

// ── Main Panel ──────────────────────────────────────────

export function SupervisorDiagnosticsPanel({ keeper }: { keeper: Keeper }) {
  const diag = keeper.supervisor_diagnostics
  if (!diag) return null
  const {
    restart_count = 0,
    crash_log,
    last_failure_reason,
    dead_since,
  } = diag
  return html`
    <${PanelCard} title="감독 진단">
      <div class="space-y-3 v2-monitoring-panel">
        <div class="flex items-center justify-between v2-monitoring-row">
          <${MutedLabel}>실행 상태</${MutedLabel}>
          ${registryStateBadge(keeper.registry_state ?? null)}
        </div>
        <div class="flex items-center justify-between v2-monitoring-row">
          <${MutedLabel}>재시작 관측</${MutedLabel}>
          <span class="text-xs font-mono text-[var(--color-fg-primary)]">${restart_count}</span>
        </div>
        ${last_failure_reason ? html`
          <div class="flex items-center justify-between v2-monitoring-row">
            <${MutedLabel}>마지막 실패 원인</${MutedLabel}>
            <span class="text-2xs font-mono text-[var(--rose-light)]" title=${last_failure_reason}>${failureReasonLabel(last_failure_reason)}</span>
          </div>
        ` : null}
        ${dead_since ? html`
          <div class="py-2 px-3 rounded-[var(--r-1)] bg-[var(--bad-6)] border border-[var(--bad-soft)] text-xs text-[var(--rose-light)] v2-monitoring-panel">
            ${formatTimeAgo(dead_since)} 이후 Dead tombstone 유지 중.
          </div>
        ` : null}
        <div class="v2-monitoring-row"><${CrashCohortBar} crash_log=${crash_log} /></div>
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
            <div class="v2-monitoring-panel">
              <div class="flex items-center justify-between mb-2 v2-monitoring-toolbar">
                <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">장애 이력</div>
                ${filtered.length > 10 ? html`
                  <button type="button"
                    class="text-3xs font-medium px-2 py-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] transition-colors v2-monitoring-action"
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
              <div class="space-y-1 ${crashShowAll.value ? 'max-h-64' : 'max-h-32'} overflow-y-auto v2-monitoring-row">
                ${visible.length === 0 ? html`
                  <div class="py-2 px-2 text-2xs text-[var(--color-fg-muted)] italic v2-monitoring-row">선택된 카테고리에 해당하는 장애가 없습니다.</div>
                ` : visible.map((e) => html`
                  <div class="flex items-center justify-between py-1 px-2 rounded-[var(--r-1)] text-2xs bg-[var(--color-bg-surface)] v2-monitoring-row">
                    <span class="font-mono text-[var(--color-fg-muted)]">${formatTimeAgo(e.ts ?? 0)}</span>
                    <span class="text-[var(--rose-light)]">${e.reason ?? 'unknown'}</span>
                  </div>
                `)}
              </div>
            </div>
          `
        })() : null}
      </div>
    <//>
  `
}
