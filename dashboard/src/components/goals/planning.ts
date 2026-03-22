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

      <!-- Step 1: Task-based stats grid -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3 mb-4">
        <div class="border border-[var(--card-border)] rounded-[var(--radius-md)] bg-[var(--card)] py-[15px] px-3.5">
          <div class="stat-label">전체 태스크</div>
          <div class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${totalTasks}</div>
        </div>
        <div class="border border-[var(--card-border)] rounded-[var(--radius-md)] bg-[var(--card)] py-[15px] px-3.5">
          <div class="stat-label">할 일</div>
          <div class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums text-[#e0e0e0]">${todo.length}</div>
        </div>
        <div class="border border-[var(--card-border)] rounded-[var(--radius-md)] bg-[var(--card)] py-[15px] px-3.5">
          <div class="stat-label">진행 중</div>
          <div class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums text-[var(--warn)]">${inProgress.length}</div>
        </div>
        <div class="border border-[var(--card-border)] rounded-[var(--radius-md)] bg-[var(--card)] py-[15px] px-3.5">
          <div class="stat-label">완료</div>
          <div class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums text-[var(--ok)]">${done.length}</div>
        </div>
        <div class="border border-[var(--card-border)] rounded-[var(--radius-md)] bg-[var(--card)] py-[15px] px-3.5">
          <div class="stat-label">높은 우선순위</div>
          <div class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums" style="color:${highPriority > 0 ? '#f87171' : '#888'}">${highPriority}</div>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="planning-toolbar">
        <button
          class="control-btn rounded-lg secondary"
          onClick=${() => {
            refreshGoals()
            refreshMdal()
          }}
          disabled=${goalsLoading.value || mdalLoading.value}
        >
          ${goalsLoading.value || mdalLoading.value ? '새로고침 중...' : '계획 데이터 새로고침'}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${TaskBacklog} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${hasGoals}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill inline-flex items-center rounded-full px-2 py-[3px] text-[length:var(--fs-xs)] uppercase tracking-[0.06em] ml-auto">${goals.value.length}</span>
        </summary>
        <div>
          ${hasGoals ? html`
            <${GoalsSummary} />
            <${FilterBar} />
            ${goalsLoading.value && goals.value.length === 0
              ? html`<div class="text-center border border-dashed border-[var(--card-border)] rounded-xl py-12 px-4 text-[color:var(--text-muted)]">목표 불러오는 중...</div>`
              : filteredGoals.value.length === 0
                ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">현재 필터에 맞는 목표가 없습니다</div>`
                : html`
                    <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
                    <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
                    <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
                  `}
          ` : html`
            <div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">
              장기 목표가 아직 없습니다. <code>masc_goal_upsert</code>로 단기/중기/장기 목표를 등록하면 메트릭 기반 추적이 시작됩니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${hasLoops}>
        <summary>
          MDAL 루프
          <span class="monitor-pill inline-flex items-center rounded-full px-2 py-[3px] text-[length:var(--fs-xs)] uppercase tracking-[0.06em] ml-auto">${loops.length}</span>
        </summary>
        <div>
          ${mdalLoading.value && loops.length === 0
            ? html`<div class="text-center border border-dashed border-[var(--card-border)] rounded-xl py-12 px-4 text-[color:var(--text-muted)]">MDAL 루프 불러오는 중...</div>`
            : loops.length === 0 && (mdalState === 'error' || lastMdalError.value)
              ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">MDAL 스냅샷을 불러오지 못했습니다${lastMdalError.value ? `: ${lastMdalError.value}` : ''}. 백엔드 상태를 확인하세요.</div>`
              : loops.length === 0
                ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`
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
