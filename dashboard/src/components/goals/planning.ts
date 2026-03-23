// Planning main component — orchestrates goals, MDAL, and kanban views

import { html } from 'htm/preact'
import { EmptyState } from '../common/empty-state'
import { LoadingState } from '../common/feedback-state'
import {
  goals,
  goalsLoading,
  mdalLoading,
  mdalSnapshotState,
  lastMdalError,
  refreshGoals,
  refreshMdal,
  tasksByStatus,
} from '../../store'
import {
  filteredGoals,
  groupedByHorizon,
  loopsList,
} from './goal-helpers'
import { GoalsSummary, FilterBar, HorizonGroup } from './goal-components'
import { LoopRow } from './mdal-components'
import { TaskBacklog } from './kanban-components'

export function Planning() {
  const { todo, inProgress, done } = tasksByStatus.value
  const totalTasks = todo.length + inProgress.length + done.length
  const highPriority = [...todo, ...inProgress].filter(t => (t.priority ?? 4) <= 2).length

  const grouped = groupedByHorizon.value
  const loops = loopsList.value
  const hasGoals = goals.value.length > 0
  const hasLoops = loops.length > 0
  const mdalState = mdalSnapshotState.value

  return html`
    <div class="flex flex-col gap-6">

      <!-- Task-based stats grid -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-4">
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">전체 태스크</span>
          <span class="text-[32px] font-bold text-text-strong leading-none tabular-nums">${totalTasks}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">할 일</span>
          <span class="text-[32px] font-bold leading-none tabular-nums text-[#e0e0e0]">${todo.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">진행 중</span>
          <span class="text-[32px] font-bold leading-none tabular-nums text-warn">${inProgress.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">완료</span>
          <span class="text-[32px] font-bold leading-none tabular-nums text-ok">${done.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">높은 우선순위</span>
          <span class="text-[32px] font-bold leading-none tabular-nums ${highPriority > 0 ? 'text-bad' : 'text-text-muted/50'}">${highPriority}</span>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="flex justify-end">
        <button
          class="px-4 py-2 rounded-xl text-[12px] font-semibold border border-transparent bg-white/5 text-text-muted hover:bg-white/10 hover:text-text-strong transition-all duration-200 cursor-pointer shadow-sm disabled:opacity-50 disabled:cursor-not-allowed"
          onClick=${() => {
            refreshGoals()
            refreshMdal()
          }}
          disabled=${goalsLoading.value || mdalLoading.value}
        >
          ${goalsLoading.value || mdalLoading.value ? '새로고침 중...' : '계획 데이터 새로고침'}
        </button>
      </div>

      <!-- Task Backlog at top -->
      <${TaskBacklog} />

      <!-- Goals in collapsible details -->
      <details class="overview-section-collapsible group bg-card/20 backdrop-blur-sm rounded-2xl border border-card-border/50 overflow-hidden" open=${hasGoals}>
        <summary class="px-5 py-4 cursor-pointer flex items-center bg-card/40 hover:bg-card/60 transition-colors border-b border-transparent group-open:border-card-border/50 text-[14px] font-bold text-text-strong">
          목표 파이프라인
          <span class="inline-flex items-center rounded-lg px-2.5 py-1 text-[10px] uppercase tracking-wider ml-auto bg-accent/10 text-accent border border-accent/20 shadow-sm font-semibold">${goals.value.length}</span>
        </summary>
        <div class="p-5">
          ${hasGoals ? html`
            <${GoalsSummary} />
            <${FilterBar} />
            ${goalsLoading.value && goals.value.length === 0
              ? html`<${LoadingState}>목표 불러오는 중...<//>`
              : filteredGoals.value.length === 0
                ? html`<${EmptyState} message="현재 필터에 맞는 목표가 없습니다" compact />`
                : html`
                    <div class="mt-4 flex flex-col gap-6">
                      <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
                      <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
                      <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
                    </div>
                  `}
          ` : html`
            <${EmptyState} message="장기 목표가 아직 없습니다. masc_goal_upsert로 등록하면 메트릭 기반 추적이 시작됩니다." />
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible group bg-card/20 backdrop-blur-sm rounded-2xl border border-card-border/50 overflow-hidden" open=${hasLoops}>
        <summary class="px-5 py-4 cursor-pointer flex items-center bg-card/40 hover:bg-card/60 transition-colors border-b border-transparent group-open:border-card-border/50 text-[14px] font-bold text-text-strong">
          MDAL 루프
          <span class="inline-flex items-center rounded-lg px-2.5 py-1 text-[10px] uppercase tracking-wider ml-auto bg-accent/10 text-accent border border-accent/20 shadow-sm font-semibold">${loops.length}</span>
        </summary>
        <div class="p-5">
          ${mdalLoading.value && loops.length === 0
            ? html`<${LoadingState}>MDAL 루프 불러오는 중...<//>`
            : loops.length === 0 && (mdalState === 'error' || lastMdalError.value)
              ? html`<div class="p-4 border border-bad/30 bg-bad/10 rounded-xl shadow-sm text-[13px] text-bad font-medium text-center">MDAL 스냅샷을 불러오지 못했습니다${lastMdalError.value ? `: ${lastMdalError.value}` : ''}. 백엔드 상태를 확인하세요.</div>`
              : loops.length === 0
                ? html`<${EmptyState} message="가동 중인 루프가 없습니다. masc_mdal_start로 시작할 수 있습니다." />`
                : html`
                  <div class="grid gap-3">
                    ${loops.map(loop => html`<${LoopRow} key=${loop.loop_id} loop=${loop} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `
}

export const Goals = Planning
