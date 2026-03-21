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
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">전체 태스크</div>
          <div class="stat-value">${totalTasks}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">할 일</div>
          <div class="stat-value" style="color:#e0e0e0">${todo.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">진행 중</div>
          <div class="stat-value" style="color:#fbbf24">${inProgress.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">완료</div>
          <div class="stat-value" style="color:#4ade80">${done.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">높은 우선순위</div>
          <div class="stat-value" style="color:${highPriority > 0 ? '#f87171' : '#888'}">${highPriority}</div>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="planning-toolbar">
        <button
          class="control-btn secondary"
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
          <span class="monitor-pill">${goals.value.length}</span>
        </summary>
        <div>
          ${hasGoals ? html`
            <${GoalsSummary} />
            <${FilterBar} />
            ${goalsLoading.value && goals.value.length === 0
              ? html`<div class="loading-indicator">목표 불러오는 중...</div>`
              : filteredGoals.value.length === 0
                ? html`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`
                : html`
                    <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
                    <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
                    <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
                  `}
          ` : html`
            <div class="empty-state">
              장기 목표가 아직 없습니다. <code>masc_goal_upsert</code>로 단기/중기/장기 목표를 등록하면 메트릭 기반 추적이 시작됩니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${hasLoops}>
        <summary>
          MDAL 루프
          <span class="monitor-pill">${loops.length}</span>
        </summary>
        <div>
          ${mdalLoading.value && loops.length === 0
            ? html`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`
            : loops.length === 0 && (mdalState === 'error' || lastMdalError.value)
              ? html`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${lastMdalError.value ? `: ${lastMdalError.value}` : ''}. 백엔드 상태를 확인하세요.</div>`
              : loops.length === 0
                ? html`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`
                : html`
                  <div class="planning-loop-list">
                    ${loops.map(loop => html`<${LoopRow} key=${loop.loop_id} loop=${loop} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `
}

export const Goals = Planning
