// Goal sub-components: GoalRow, HorizonGroup, FilterBar, GoalsSummary

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { FilterChips } from '../common/filter-chips'
import { showToast } from '../common/toast'
import { goals, refreshGoals } from '../../store'
import { deleteGoal } from '../../api/actions'
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

const deletingGoalId = signal<string | null>(null)

export function GoalRow({ goal }: { goal: Goal }) {
  const isDeleting = deletingGoalId.value === goal.id

  async function handleDelete(e: Event) {
    e.stopPropagation()
    if (!confirm(`"${goal.title}" 목표를 삭제하시겠습니까?`)) return
    deletingGoalId.value = goal.id
    try {
      await deleteGoal(goal.id)
      showToast('목표를 삭제했습니다', 'success')
      await refreshGoals()
    } catch {
      showToast('목표 삭제에 실패했습니다', 'error')
    } finally {
      deletingGoalId.value = null
    }
  }

  return html`
    <div class="goal-row flex justify-between items-start gap-4 p-4 rounded-xl border border-card-border/50 bg-card/40 backdrop-blur-md transition-all duration-200 hover:bg-card/60 hover:border-accent/30 shadow-sm hover:shadow-md hover:-translate-y-0.5 group">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1.5 min-w-0">
          <span class="text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-md bg-white/5 border border-white/10 shrink-0" style="color:${horizonColor(goal.horizon)}">
            ${horizonLabel(goal.horizon)}
          </span>
          <span class="text-[15px] font-bold text-text-strong group-hover:text-accent transition-colors tracking-wide truncate">${goal.title}</span>
        </div>
        <div class="flex gap-3 flex-wrap items-center mt-2.5 text-[11px] font-medium text-text-muted/90">
          <span class="text-amber-500 tracking-[1px] text-[13px] drop-shadow-sm" title="Priority ${goal.priority}">${priorityStars(goal.priority)}</span>
          ${goal.metric ? html`<span class="flex items-center gap-1.5 px-2 py-0.5 bg-accent/10 text-accent rounded-md border border-accent/20"><span class="w-1.5 h-1.5 rounded-full bg-accent/60"></span>${goal.metric}${goal.target_value ? ` \u2192 ${goal.target_value}` : ''}</span>` : null}
          ${goal.due_date ? html`<span class="flex items-center gap-1.5 px-2 py-0.5 bg-bad/10 text-bad rounded-md border border-bad/20"><span>마감:</span><${TimeAgo} timestamp=${goal.due_date} /></span>` : null}
        </div>
        ${goal.last_review_note ? html`
          <div class="text-[12px] text-text-body/80 italic mt-3 p-2.5 rounded-lg border border-white/5 bg-white/5 leading-relaxed shadow-inner">${goal.last_review_note}</div>
        ` : null}
      </div>
      <div class="flex flex-col items-end gap-1.5 shrink-0 pt-0.5">
        <${StatusBadge} status=${goal.status} />
        <div class="text-[11px] font-mono text-text-dim">
          <${TimeAgo} timestamp=${goal.updated_at} />
        </div>
        <button type="button"
          class="mt-1 px-2.5 py-1 rounded-lg text-[10px] font-semibold border border-bad/30 bg-bad/10 text-bad hover:bg-bad/25 transition-all cursor-pointer opacity-0 group-hover:opacity-100 disabled:opacity-50 disabled:cursor-not-allowed"
          onClick=${handleDelete}
          disabled=${isDeleting}
        >
          ${isDeleting ? '삭제 중...' : '삭제'}
        </button>
      </div>
    </div>
  `
}

export function HorizonGroup({ horizon, items }: { horizon: string; items: Goal[] }) {
  if (items.length === 0) return null
  const sorted = [...items].sort((a, b) => b.priority - a.priority)
  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2 mb-1 px-1">
        <span class="text-[12px] font-bold uppercase tracking-widest" style="color:${horizonColor(horizon)}">${horizonLabel(horizon)} 목표</span>
        <span class="text-[10px] font-semibold px-2 py-0.5 rounded-md bg-white/5 text-text-muted border border-white/10 shadow-sm">${items.length}</span>
      </div>
      <div class="flex flex-col gap-2.5">
        ${sorted.map(g => html`<${GoalRow} key=${g.id} goal=${g} />`)}
      </div>
    </div>
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
        <label class="text-[11px] text-[var(--text-dim)]">범위</label>
        <${FilterChips} chips=${horizonChips} active=${horizonFilter} />
      </div>
      <div class="flex items-center gap-1.5">
        <label class="text-[11px] text-[var(--text-dim)]">상태</label>
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
    <div class="flex gap-4 flex-wrap pb-2 border-b border-card-border/50">
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${all.length}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">전체</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold text-ok tabular-nums">${active}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">진행 중</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold text-text-dim tabular-nums">${completed}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">완료</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold tabular-nums" style="color:${horizonColor('short')}">${byHorizon.short}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">단기</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold tabular-nums" style="color:${horizonColor('mid')}">${byHorizon.mid}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">중기</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold tabular-nums" style="color:${horizonColor('long')}">${byHorizon.long}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">장기</div>
      </div>
    </div>
  `
}
