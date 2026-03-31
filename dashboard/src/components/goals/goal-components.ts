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
    <div class="goal-row flex justify-between items-start gap-4 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] p-4 group">
      <div class="flex-1 min-w-0">
        <div class="mb-1.5 flex min-w-0 flex-wrap items-center gap-2">
          <span class="shrink-0 rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-bold uppercase tracking-widest" style="color:${horizonColor(goal.horizon)}">
            ${horizonLabel(goal.horizon)}
          </span>
          <span class="truncate text-[15px] font-semibold tracking-[-0.01em] text-text-strong">${goal.title}</span>
        </div>
        <div class="mt-2.5 flex flex-wrap items-center gap-2 text-[11px] font-medium text-text-muted">
          <span class="rounded-md border border-card-border/60 bg-white/4 px-2 py-1 text-[12px] text-amber-300" title="우선순위 ${goal.priority}">
            ${priorityStars(goal.priority)}
          </span>
          ${goal.metric ? html`
            <span class="rounded-md border border-accent/20 bg-accent/10 px-2 py-1 text-accent">
              ${goal.metric}${goal.target_value ? ` \u2192 ${goal.target_value}` : ''}
            </span>
          ` : null}
          ${goal.due_date ? html`
            <span class="rounded-md border border-bad/20 bg-bad/10 px-2 py-1 text-bad">
              마감 <${TimeAgo} timestamp=${goal.due_date} />
            </span>
          ` : null}
        </div>
        ${goal.last_review_note ? html`
          <div class="mt-3 rounded-lg border border-card-border/50 bg-white/4 p-3 text-[12px] italic leading-relaxed text-text-body/85">${goal.last_review_note}</div>
        ` : null}
      </div>
      <div class="flex flex-col items-end gap-1.5 shrink-0 pt-0.5">
        <${StatusBadge} status=${goal.status} />
        <div class="text-[11px] font-mono text-text-dim">
          <${TimeAgo} timestamp=${goal.updated_at} />
        </div>
        <button type="button"
          class="mt-1 rounded-lg border border-bad/25 bg-bad/10 px-2.5 py-1 text-[10px] font-semibold text-bad transition-colors hover:bg-bad/20 disabled:opacity-50 disabled:cursor-not-allowed"
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
    <div class="flex flex-wrap gap-3 border-b border-card-border/50 pb-3">
      <div class="min-w-[92px] flex-1 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] px-3 py-3 text-center">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${all.length}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">전체</div>
      </div>
      <div class="min-w-[92px] flex-1 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] px-3 py-3 text-center">
        <div class="text-2xl font-bold text-ok tabular-nums">${active}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">진행 중</div>
      </div>
      <div class="min-w-[92px] flex-1 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] px-3 py-3 text-center">
        <div class="text-2xl font-bold text-text-dim tabular-nums">${completed}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">완료</div>
      </div>
      <div class="min-w-[92px] flex-1 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] px-3 py-3 text-center">
        <div class="text-2xl font-bold tabular-nums" style="color:${horizonColor('short')}">${byHorizon.short}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">단기</div>
      </div>
      <div class="min-w-[92px] flex-1 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] px-3 py-3 text-center">
        <div class="text-2xl font-bold tabular-nums" style="color:${horizonColor('mid')}">${byHorizon.mid}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">중기</div>
      </div>
      <div class="min-w-[92px] flex-1 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] px-3 py-3 text-center">
        <div class="text-2xl font-bold tabular-nums" style="color:${horizonColor('long')}">${byHorizon.long}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">장기</div>
      </div>
    </div>
  `
}
