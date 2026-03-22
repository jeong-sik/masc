// Goal sub-components: GoalRow, HorizonGroup, FilterBar, GoalsSummary

import { html } from 'htm/preact'
import { Card } from '../common/card'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { goals } from '../../store'
import type { Goal } from '../../types'
import {
  type HorizonFilter,
  type StatusFilter,
  horizonFilter,
  statusFilter,
  horizonLabel,
  horizonColor,
  priorityStars,
  statusFilterLabel,
} from './goal-helpers'

export function GoalRow({ goal }: { goal: Goal }) {
  return html`
    <div class="goal-row">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="goal-horizon-badge" style="color:${horizonColor(goal.horizon)}">
            ${horizonLabel(goal.horizon)}
          </span>
          <span class="goal-title">${goal.title}</span>
        </div>
        <div class="goal-meta">
          <span class="text-amber-500 tracking-[1px]" title="Priority ${goal.priority}">${priorityStars(goal.priority)}</span>
          ${goal.metric ? html`<span class="text-cyan">${goal.metric}${goal.target_value ? ` \u2192 ${goal.target_value}` : ''}</span>` : null}
          ${goal.due_date ? html`<span class="text-[var(--bad-light)]">Due: <${TimeAgo} timestamp=${goal.due_date} /></span>` : null}
        </div>
        ${goal.last_review_note ? html`
          <div class="goal-review-note">${goal.last_review_note}</div>
        ` : null}
      </div>
      <div class="goal-row-right">
        <${StatusBadge} status=${goal.status} />
        <div class="goal-updated">
          <${TimeAgo} timestamp=${goal.updated_at} />
        </div>
      </div>
    </div>
  `
}

export function HorizonGroup({ horizon, items }: { horizon: string; items: Goal[] }) {
  if (items.length === 0) return null
  const sorted = [...items].sort((a, b) => b.priority - a.priority)
  return html`
    <${Card} title="${horizonLabel(horizon)} 목표 (${items.length})" class="section mb-3.5">
      <div class="goal-list">
        ${sorted.map(g => html`<${GoalRow} key=${g.id} goal=${g} />`)}
      </div>
    <//>
  `
}

export function FilterBar() {
  return html`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${(['all', 'short', 'mid', 'long'] as HorizonFilter[]).map(h => html`
          <button
            class="goal-filter-btn ${horizonFilter.value === h ? 'active' : ''}"
            onClick=${() => { horizonFilter.value = h }}
          >
            ${h === 'all' ? '전체' : horizonLabel(h)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${(['all', 'active', 'completed', 'paused'] as StatusFilter[]).map(s => html`
          <button
            class="goal-filter-btn ${statusFilter.value === s ? 'active' : ''}"
            onClick=${() => { statusFilter.value = s }}
          >
            ${statusFilterLabel(s)}
          </button>
        `)}
      </div>
    </div>
  `
}

export function GoalsSummary() {
  const all = goals.value
  const active = all.filter(g => g.status === 'active').length
  const completed = all.filter(g => g.status === 'completed').length
  const byHorizon = { short: 0, mid: 0, long: 0 }
  for (const g of all) {
    if (g.horizon in byHorizon) byHorizon[g.horizon as keyof typeof byHorizon]++
  }
  return html`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${all.length}</div>
        <div class="goal-summary-label">전체</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" class="text-[var(--ok)]">${active}</div>
        <div class="goal-summary-label">진행 중</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" class="text-[var(--text-dim)]">${completed}</div>
        <div class="goal-summary-label">완료</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('short')}">${byHorizon.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('mid')}">${byHorizon.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('long')}">${byHorizon.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `
}
