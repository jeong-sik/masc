// Keeper Health Strip — compact keeper status overview for Live Monitor

import { html } from 'htm/preact'
import { keeperHealthSummary, type KeeperPressure } from '../../live-store'

function pressureColor(ratio: number): string {
  if (ratio > 0.85) return 'bg-[#e05050]'
  if (ratio > 0.70) return 'bg-[#e0a030]'
  if (ratio > 0.50) return 'bg-[#c0b040]'
  return 'bg-[#40a060]'
}

function stageIndicator(stage: string): string {
  if (stage === 'thinking') return 'border-[var(--accent-soft)]'
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
    <div class="flex items-center gap-4 rounded-2xl border border-[var(--border-slate-12)] bg-[var(--white-3)] px-4 py-2.5">
      <div class="flex items-center gap-2 min-w-0">
        <span class="text-[13px] font-medium text-[var(--text-strong)] whitespace-nowrap">
          Keeper
        </span>
        <span class="text-[13px] text-[var(--text-body)] whitespace-nowrap">
          ${summary.activeCount} 활성
          <span class="text-[var(--text-muted)]">/ ${summary.totalCount}</span>
        </span>
      </div>

      ${summary.pressures.length > 0 && html`
        <div class="flex items-end gap-px flex-1 min-w-0" title="keeper별 context 사용률">
          ${summary.pressures.map(p => html`<${ContextBar} p=${p} key=${p.name} />`)}
        </div>
      `}

      <div class="flex items-center gap-2 ml-auto whitespace-nowrap">
        ${alertCount > 0
          ? html`<span class="text-[12px] font-medium text-[#e0a030]">${alertCount} 주의</span>`
          : html`<span class="text-[12px] text-[var(--text-muted)]">정상</span>`
        }
        ${summary.criticalCount > 0 && html`
          <span class="text-[12px] font-medium text-[#e05050]">${summary.criticalCount} 위험</span>
        `}
      </div>
    </div>
  `
}
