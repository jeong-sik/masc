// Turn Budget Gauge — visual per-keeper restart budget indicator.
//
// Shows restart budget consumption (restarts used vs max_restarts)
// as an arc gauge and provides the action context for operators to see
// which keepers are approaching terminal state.
//
// Data sources:
//   keeper.supervisor_diagnostics.restart_count   — actual restarts used
//   keeper.supervisor_diagnostics.max_restarts    — configured ceiling
//   keeper.conditions.restart_budget_remaining    — fast boolean gate
//   keeper.outcomes.failures                      — rich failure summary
//
// The gauge is read-only; intervention buttons (pause/restart) live in
// the keeper-action-panel.ts component.

import { html } from 'htm/preact'
import type { Keeper } from '../types'

// ── Threshold constants ───────────────────────────────────────────────────

/** Fraction of budget consumed at which we show a warning. */
export const BUDGET_WARN_RATIO = 0.5

/** Fraction of budget consumed at which we show a critical alert. */
export const BUDGET_CRIT_RATIO = 0.8

// ── Derivations ───────────────────────────────────────────────────────────

export interface BudgetGaugeState {
  used: number
  max: number
  ratio: number
  tone: 'ok' | 'warn' | 'bad'
  remaining: boolean
}

/** Extract budget gauge state from a keeper. */
export function deriveBudgetGaugeState(keeper: Keeper): BudgetGaugeState | null {
  const diag = keeper.supervisor_diagnostics
  if (!diag) return null
  const used = typeof diag.restart_count === 'number' ? diag.restart_count : null
  const max = typeof diag.max_restarts === 'number' ? diag.max_restarts : null
  if (used === null || max === null || max <= 0) return null
  const ratio = used / max
  const remaining = keeper.conditions?.restart_budget_remaining ?? true
  const tone: BudgetGaugeState['tone'] =
    !remaining || ratio >= BUDGET_CRIT_RATIO ? 'bad'
    : ratio >= BUDGET_WARN_RATIO ? 'warn'
    : 'ok'
  return { used, max, ratio, tone, remaining }
}

// Tone-to-CSS helper
function toneColor(tone: BudgetGaugeState['tone']): string {
  switch (tone) {
    case 'bad':  return 'var(--bad-light)'
    case 'warn': return 'var(--color-status-warn)'
    case 'ok':
    default:     return 'var(--color-status-ok)'
  }
}

function toneLabel(tone: BudgetGaugeState['tone']): string {
  switch (tone) {
    case 'bad':  return '예산 초과 위험'
    case 'warn': return '예산 경고'
    case 'ok':
    default:     return '예산 양호'
  }
}

// ── Per-keeper row ────────────────────────────────────────────────────────

/** Compact inline bar gauge for a single keeper. */
function KeeperBudgetGaugeRow({ keeper }: { keeper: Keeper }) {
  const state = deriveBudgetGaugeState(keeper)
  if (!state) return null

  const pct = Math.min(100, Math.round(state.ratio * 100))
  const color = toneColor(state.tone)
  const label = toneLabel(state.tone)
  const crashLog = keeper.supervisor_diagnostics?.crash_log ?? []

  return html`
    <div
      class="flex items-center gap-3 py-1.5 px-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      role="listitem"
      aria-label="${keeper.name} 재시작 예산 ${state.used}/${state.max}"
    >
      <div class="w-20 shrink-0 truncate text-xs font-semibold text-[var(--color-fg-secondary)]">
        ${keeper.name}
      </div>
      <div class="flex-1 min-w-0">
        <div class="relative h-2.5 rounded-full overflow-hidden bg-[var(--color-bg-hover)]">
          <div
            class="absolute inset-y-0 left-0 rounded-full transition-[width]"
            style="width: ${pct}%; background: ${color}"
            role="progressbar"
            aria-valuenow=${state.used}
            aria-valuemin="0"
            aria-valuemax=${state.max}
            aria-label="${label}"
          />
        </div>
        <div class="flex items-center gap-1.5 mt-0.5 text-3xs text-[var(--color-fg-muted)] tabular-nums">
          <span>${state.used}/${state.max} 재시작</span>
          ${!state.remaining
            ? html`<span class="text-[var(--bad-light)] font-semibold">예산 소진</span>`
            : state.tone !== 'ok'
              ? html`<span style="color: ${color}">${label}</span>`
              : null}
          ${crashLog.length > 0
            ? html`<span class="ml-auto text-[var(--color-fg-disabled)]">충돌 ${crashLog.length}건</span>`
            : null}
        </div>
      </div>
      <div
        class="shrink-0 text-2xs font-semibold tabular-nums"
        style="color: ${color}"
      >${pct}%</div>
    </div>
  `
}

// ── Fleet overview panel ──────────────────────────────────────────────────

/**
 * Fleet-level restart budget panel.
 * Renders one gauge row per keeper that has supervisor diagnostics.
 * Keepers without diagnostics are silently omitted.
 */
export function TurnBudgetGaugePanel({ keepers }: { keepers: Keeper[] }) {
  const withBudget = keepers.filter(k => deriveBudgetGaugeState(k) !== null)

  if (withBudget.length === 0) {
    return html`
      <div class="text-xs text-[var(--color-fg-muted)] py-3 text-center">
        재시작 예산 데이터 없음 — supervisor diagnostics가 활성화될 때 표시됩니다.
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-1.5" role="list" aria-label="키퍼별 재시작 예산 게이지">
      ${withBudget.map(k => html`<${KeeperBudgetGaugeRow} keeper=${k} key=${k.name} />`)}
    </div>
  `
}
