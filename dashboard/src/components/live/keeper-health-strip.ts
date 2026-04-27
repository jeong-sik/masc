// Keeper Health Strip — compact keeper status overview for Live Monitor

import { html } from 'htm/preact'
import { keeperHealthSummary, type KeeperPressure } from '../../live-store'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN, CONTEXT_RATIO_COMPACTING } from '../../config/constants'

function pressureColor(ratio: number): string {
  if (ratio > CONTEXT_RATIO_CRITICAL) return 'bg-[var(--color-status-err)]'
  if (ratio > CONTEXT_RATIO_WARN) return 'bg-[var(--color-status-warn)]'
  if (ratio > CONTEXT_RATIO_COMPACTING) return 'bg-[var(--color-status-warn)]'
  return 'bg-[var(--color-status-ok)]'
}

function stageIndicator(stage: string): string {
  if (stage === 'thinking') return 'border-[var(--color-accent-soft)]'
  return 'border-transparent'
}

function ContextBar({ p }: { p: KeeperPressure }) {
  const pct = Math.round(p.ratio * 100)
  return html`
    <div
      class="relative h-5 w-1.5 rounded-sm ${pressureColor(p.ratio)} border ${stageIndicator(p.stage)} opacity-90"
      title="${p.name}: ctx ${pct}% (${p.stage})"
    />
  `
}

export function KeeperHealthStrip() {
  const summary = keeperHealthSummary.value

  if (summary.totalCount === 0) return null

  const alertCount = summary.warningCount + summary.criticalCount

  return html`
    <div class="flex items-center gap-4 rounded border border-[var(--color-border-divider)] bg-[var(--white-3)] px-4 py-2.5">
      <div class="flex items-center gap-2 min-w-0">
        <span class="text-sm font-medium text-[var(--color-fg-secondary)] whitespace-nowrap">
          Keeper
        </span>
        <span class="text-sm text-[var(--color-fg-primary)] whitespace-nowrap">
          ${summary.activeCount} 활성
          <span class="text-[var(--color-fg-muted)]">/ ${summary.totalCount}</span>
        </span>
      </div>

      ${summary.pressures.length > 0 && html`
        <div class="flex items-end gap-px flex-1 min-w-0" title="keeper별 context 사용률">
          ${summary.pressures.map(p => html`<${ContextBar} p=${p} key=${p.name} />`)}
        </div>
      `}

      <div class="flex items-center gap-2 ml-auto whitespace-nowrap">
        ${alertCount > 0
          ? html`<span class="text-xs font-medium text-[var(--color-status-warn)]">${alertCount} 주의</span>`
          : html`<span class="text-xs text-[var(--color-fg-muted)]">정상</span>`
        }
        ${summary.criticalCount > 0 && html`
          <span class="text-xs font-medium text-[var(--color-status-err)]">${summary.criticalCount} 위험</span>
        `}
      </div>
    </div>
  `
}
