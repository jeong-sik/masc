// Goal sub-components: GoalRow, HorizonGroup, FilterBar, GoalsSummary

import { html } from 'htm/preact'
import { Card } from '../common/card'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { FilterChips } from '../common/filter-chips'
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
    <div class="goal-row flex justify-between items-start gap-3 py-2.5 px-3 bg-[var(--white-2)] rounded-lg transition-[background] duration-150 hover:bg-[var(--white-5)]">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-[length:var(--fs-xs)] font-semibold uppercase tracking-[0.5px]" style="color:${horizonColor(goal.horizon)}">
            ${horizonLabel(goal.horizon)}
          </span>
          <span class="text-[length:var(--fs-base)] font-medium text-[color:var(--text-near-white)]">${goal.title}</span>
        </div>
        <div class="flex gap-2.5 flex-wrap mt-1 text-[length:var(--fs-xs)] text-[var(--text-dim)]">
          <span class="text-amber-500 tracking-[1px]" title="Priority ${goal.priority}">${priorityStars(goal.priority)}</span>
          ${goal.metric ? html`<span class="text-cyan">${goal.metric}${goal.target_value ? ` \u2192 ${goal.target_value}` : ''}</span>` : null}
          ${goal.due_date ? html`<span class="text-[var(--bad-light)]">Due: <${TimeAgo} timestamp=${goal.due_date} /></span>` : null}
        </div>
        ${goal.last_review_note ? html`
          <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] italic mt-1 pl-2 border-l-2 border-[var(--white-8)]">${goal.last_review_note}</div>
        ` : null}
      </div>
      <div class="flex flex-col items-end gap-1 shrink-0">
        <${StatusBadge} status=${goal.status} />
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)]">
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
      <div class="flex flex-col gap-0.5">
        ${sorted.map(g => html`<${GoalRow} key=${g.id} goal=${g} />`)}
      </div>
    <//>
  `
}

export function FilterBar() {
  const horizonChips = (['all', 'short', 'mid', 'long'] as HorizonFilter[]).map(h => ({
    key: h, label: h === 'all' ? '전체' : horizonLabel(h),
  }))
  const statusChips = (['all', 'active', 'completed', 'paused'] as StatusFilter[]).map(s => ({
    key: s, label: statusFilterLabel(s),
  }))

  return html`
    <div class="flex gap-4 flex-wrap mt-3">
      <div class="flex items-center gap-1.5">
        <label class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)]">범위</label>
        <${FilterChips} chips=${horizonChips} active=${horizonFilter} />
      </div>
      <div class="flex items-center gap-1.5">
        <label class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)]">상태</label>
        <${FilterChips} chips=${statusChips} active=${statusFilter} />
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
    <div class="flex gap-3 flex-wrap">
      <div class="flex-1 min-w-[60px] text-center py-2 px-1 bg-[var(--white-3)] rounded-lg">
        <div class="text-xl font-bold text-[color:var(--text-near-white)]">${all.length}</div>
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] mt-0.5">전체</div>
      </div>
      <div class="flex-1 min-w-[60px] text-center py-2 px-1 bg-[var(--white-3)] rounded-lg">
        <div class="text-xl font-bold text-[color:var(--ok)]">${active}</div>
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] mt-0.5">진행 중</div>
      </div>
      <div class="flex-1 min-w-[60px] text-center py-2 px-1 bg-[var(--white-3)] rounded-lg">
        <div class="text-xl font-bold text-[color:var(--text-dim)]">${completed}</div>
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] mt-0.5">완료</div>
      </div>
      <div class="flex-1 min-w-[60px] text-center py-2 px-1 bg-[var(--white-3)] rounded-lg">
        <div class="text-xl font-bold" style="color:${horizonColor('short')}">${byHorizon.short}</div>
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] mt-0.5">단기</div>
      </div>
      <div class="flex-1 min-w-[60px] text-center py-2 px-1 bg-[var(--white-3)] rounded-lg">
        <div class="text-xl font-bold" style="color:${horizonColor('mid')}">${byHorizon.mid}</div>
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] mt-0.5">중기</div>
      </div>
      <div class="flex-1 min-w-[60px] text-center py-2 px-1 bg-[var(--white-3)] rounded-lg">
        <div class="text-xl font-bold" style="color:${horizonColor('long')}">${byHorizon.long}</div>
        <div class="text-[length:var(--fs-xs)] text-[color:var(--text-dim)] mt-0.5">장기</div>
      </div>
    </div>
  `
}
