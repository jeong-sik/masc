// Keeper Health Strip — compact keeper status overview for Live Monitor

import { html } from 'htm/preact'
import {
  keeperHealthSummary,
  type KeeperHealthSummary,
  type KeeperPressure,
} from '../../live-store'
import { contextThresholds } from '../../config/context-thresholds'
import { StatusChip, type StatusChipTone } from '../common/status-chip'

type KeeperHealthChipTone = Extract<StatusChipTone, 'ok' | 'warn' | 'bad'>

interface KeeperHealthChip {
  key: string
  label: string
  tone: KeeperHealthChipTone
}

function pressureColor(ratio: number): string {
  const t = contextThresholds.value
  if (ratio > t.critical) return 'bg-[var(--color-status-err)]'
  if (ratio > t.warn) return 'bg-[var(--color-status-warn)]'
  if (ratio > t.compacting) return 'bg-[var(--color-status-warn)]'
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

export function keeperHealthStatusChips(
  summary: Pick<KeeperHealthSummary, 'criticalCount' | 'warningCount'>,
): KeeperHealthChip[] {
  const alertCount = summary.warningCount + summary.criticalCount
  const chips: KeeperHealthChip[] = alertCount > 0
    ? [{ key: 'warning', label: `${alertCount} 주의`, tone: 'warn' }]
    : [{ key: 'ok', label: '정상', tone: 'ok' }]

  if (summary.criticalCount > 0) {
    chips.push({ key: 'critical', label: `${summary.criticalCount} 위험`, tone: 'bad' })
  }

  return chips
}

export function KeeperHealthStrip() {
  const summary = keeperHealthSummary.value

  if (summary.totalCount === 0) return null

  const statusChips = keeperHealthStatusChips(summary)

  return html`
    <div class="flex items-center gap-4 rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--white-3)] px-4 py-2.5">
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
        ${statusChips.map(chip => html`
          <${StatusChip}
            key=${chip.key}
            tone=${chip.tone}
            uppercase=${false}
          >${chip.label}<//>
        `)}
      </div>
    </div>
  `
}
