// Planning main component — orchestrates goals, MDAL, and kanban views

import { html } from 'htm/preact'
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
    <div>

      <!-- Task-based stats grid -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-3 mb-4">
        <div class="flex flex-col gap-2 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
          <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">전체 태스크</span>
          <span class="text-[28px] font-bold text-[var(--text-strong)] leading-none tabular-nums">${totalTasks}</span>
        </div>
        <div class="flex flex-col gap-2 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
          <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">할 일</span>
          <span class="text-[28px] font-bold leading-none tabular-nums text-[#e0e0e0]">${todo.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
          <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">진행 중</span>
          <span class="text-[28px] font-bold leading-none tabular-nums text-[var(--warn)]">${inProgress.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
          <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">완료</span>
          <span class="text-[28px] font-bold leading-none tabular-nums text-[var(--ok)]">${done.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
          <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">높은 우선순위</span>
          <span class="text-[28px] font-bold leading-none tabular-nums" style="color:${highPriority > 0 ? '#f87171' : '#888'}">${highPriority}</span>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="flex justify-end py-2 mb-1">
        <button
          class="px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
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
      <details class="overview-section-collapsible" open=${hasGoals}>
        <summary>
          목표 파이프라인
          <span class="inline-flex items-center rounded-full px-2 py-[3px] text-[10px] uppercase tracking-[0.06em] ml-auto bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-18)]">${goals.value.length}</span>
        </summary>
        <div>
          ${hasGoals ? html`
            <${GoalsSummary} />
            <${FilterBar} />
            ${goalsLoading.value && goals.value.length === 0
              ? html`<div class="loading-state loading-pulse">목표 불러오는 중...</div>`
              : filteredGoals.value.length === 0
                ? html`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`
                : html`
                    <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
                    <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
                    <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
                  `}
          ` : html`
            <div class="empty-state">
              장기 목표가 아직 없습니다. <code class="px-1 py-0.5 rounded bg-[var(--white-8)] text-[var(--text-body)] text-[11px]">masc_goal_upsert</code>로 단기/중기/장기 목표를 등록하면 메트릭 기반 추적이 시작됩니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${hasLoops}>
        <summary>
          MDAL 루프
          <span class="inline-flex items-center rounded-full px-2 py-[3px] text-[10px] uppercase tracking-[0.06em] ml-auto bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-18)]">${loops.length}</span>
        </summary>
        <div>
          ${mdalLoading.value && loops.length === 0
            ? html`<div class="loading-state loading-pulse">MDAL 루프 불러오는 중...</div>`
            : loops.length === 0 && (mdalState === 'error' || lastMdalError.value)
              ? html`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${lastMdalError.value ? `: ${lastMdalError.value}` : ''}. 백엔드 상태를 확인하세요.</div>`
              : loops.length === 0
                ? html`<div class="empty-state">가동 중인 루프가 없습니다. <code class="px-1 py-0.5 rounded bg-[var(--white-8)] text-[var(--text-body)] text-[11px]">masc_mdal_start</code>로 시작할 수 있습니다.</div>`
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
