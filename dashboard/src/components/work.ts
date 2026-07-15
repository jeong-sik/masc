// MASC Dashboard — task-only Work surface.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useCallback, useMemo, useState } from 'preact/hooks'
import { route } from '../router'
import { tasks } from '../store'
import { BoardModerationSurface } from './board/board-moderation-surface'
import { BoardSurface } from './board/board-surface'
import { SubBoardSurface } from './board/sub-board-surface'
import { PlanningPanel } from './planning-panel'
import { VerificationRequestsPanel } from './verification-requests-panel'
import { ErrorBoundary } from './common/error-boundary'
import { LoadingState } from './common/feedback-state'
import { VirtualList } from './common/virtual-list'
import { claimTask as claimTaskAction } from '../api/actions'
import { showToast } from './common/toast'
import { errorToString } from '../lib/format-string'
import type { Task } from '../types'

type WorkSection =
  | 'work'
  | 'board'
  | 'sub-boards'
  | 'moderation'
  | 'planning'
  | 'repositories'
  | 'verification'

type TaskFilter = 'all' | 'todo' | 'claimed' | 'in_progress' | 'awaiting_verification' | 'done'

const TASK_FILTERS: ReadonlyArray<{ id: TaskFilter; label: string }> = [
  { id: 'all', label: '전체' },
  { id: 'todo', label: '백로그' },
  { id: 'claimed', label: '클레임' },
  { id: 'in_progress', label: '진행' },
  { id: 'awaiting_verification', label: '검증' },
  { id: 'done', label: '완료' },
]

const LazyRepositoryManagement = lazy(async () => ({
  default: (await import('./repository-management')).RepositoryManagement,
}))

function isWorkSection(value: string | undefined): value is WorkSection {
  return value === 'work'
    || value === 'board'
    || value === 'sub-boards'
    || value === 'moderation'
    || value === 'planning'
    || value === 'repositories'
    || value === 'verification'
}

function taskStatusLabel(status: Task['status']): string {
  switch (status) {
    case 'todo': return '백로그'
    case 'claimed': return '클레임'
    case 'in_progress': return '진행 중'
    case 'awaiting_verification': return '검증 대기'
    case 'done': return '완료'
    case 'cancelled': return '취소'
    case 'blocked': return '차단'
    case 'paused': return '정지'
    case 'unknown': return '미확인'
  }
}

function taskMatchesFilter(task: Task, filter: TaskFilter): boolean {
  return filter === 'all' || task.status === filter
}

function WorkSurface() {
  const taskList = tasks.value
  const [filter, setFilter] = useState<TaskFilter>('all')
  const [claiming, setClaiming] = useState<Set<string>>(new Set())

  const claimTask = useCallback((taskId: string) => {
    setClaiming(previous => new Set(previous).add(taskId))
    void claimTaskAction(taskId)
      .catch((error: unknown) => {
        showToast(`claim 실패: ${errorToString(error)}`, 'error')
      })
      .finally(() => {
        setClaiming(previous => {
          const next = new Set(previous)
          next.delete(taskId)
          return next
        })
      })
  }, [])

  const visibleTasks = useMemo(
    () => taskList.filter(task => taskMatchesFilter(task, filter)),
    [taskList, filter],
  )
  const counts = useMemo(() => ({
    active: taskList.filter(task => task.status !== 'done' && task.status !== 'cancelled').length,
    inProgress: taskList.filter(task => task.status === 'in_progress' || task.status === 'claimed').length,
    verification: taskList.filter(task => task.status === 'awaiting_verification').length,
    backlog: taskList.filter(task => task.status === 'todo' && !task.assignee).length,
  }), [taskList])

  return html`
    <main class="ov ss-surface bg-surface-page text-text-primary" data-testid="work-task-surface">
      <div class="ov-scroll">
        <header class="ov-head wk-head">
          <div>
            <span class="ov-eyebrow">TASK RUNTIME</span>
            <h1>작업</h1>
            <p class="ov-sub">Task 상태 · 명시적 소유권 · 검증 흐름</p>
          </div>
        </header>

        <section class="wk-kpis" data-testid="work-kpis">
          <div class="wk-kpi primary"><div class="wk-kpi-k">활성 작업</div><div class="wk-kpi-v brass">${counts.active}</div></div>
          <div class="wk-kpi"><div class="wk-kpi-k">진행 중</div><div class="wk-kpi-v volt">${counts.inProgress}</div></div>
          <div class="wk-kpi"><div class="wk-kpi-k">검증 대기</div><div class="wk-kpi-v">${counts.verification}</div></div>
          <div class="wk-kpi"><div class="wk-kpi-k">미배정 백로그</div><div class="wk-kpi-v warn">${counts.backlog}</div></div>
        </section>

        <div class="wk-viewseg" role="tablist" aria-label="작업 상태 필터">
          ${TASK_FILTERS.map(option => html`
            <button
              key=${option.id}
              type="button"
              class=${filter === option.id ? 'on' : ''}
              role="tab"
              aria-selected=${filter === option.id}
              onClick=${() => setFilter(option.id)}
            >${option.label}</button>
          `)}
        </div>

        ${visibleTasks.length === 0
          ? html`<div class="ap-clear"><h3>표시할 작업이 없습니다</h3></div>`
          : html`
              <${VirtualList}
                items=${visibleTasks}
                estimatedItemHeight=${56}
                className="wk-backlog-list"
                tabIndex=${0}
                ariaLabel="작업 목록"
                getKey=${(task: Task) => task.id}
                renderItem=${(task: Task) => html`
                  <div key=${task.id} class="wk-bl-row" data-task-id=${task.id}>
                    <span class="wk-task-id mono">${task.id}</span>
                    <span class="wk-bl-title">${task.title}</span>
                    <span class="wk-spacer"></span>
                    <span class="mono">${taskStatusLabel(task.status)}</span>
                    <span class="mono">${task.assignee ?? '미배정'}</span>
                    <span class="wk-bl-prio mono">P${task.priority ?? 0}</span>
                    ${task.status === 'todo' && !task.assignee
                      ? html`<button
                          type="button"
                          class="wk-task-claim"
                          disabled=${claiming.has(task.id)}
                          onClick=${() => claimTask(task.id)}
                        >${claiming.has(task.id) ? 'claiming…' : '＋ claim'}</button>`
                      : null}
                  </div>
                `}
              />
            `}
      </div>
    </main>
  `
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'work'

  return html`
    <div class="v2-workspace-surface flex min-w-0 flex-col gap-3">
      <${ErrorBoundary} label=${current}>
        ${current === 'work' ? html`<${WorkSurface} />`
          : current === 'board' ? html`<${BoardSurface} />`
          : current === 'sub-boards' ? html`<${SubBoardSurface} />`
          : current === 'moderation' ? html`<${BoardModerationSurface} />`
          : current === 'planning' ? html`<${PlanningPanel} />`
          : current === 'verification' ? html`<${VerificationRequestsPanel} />`
          : html`<${Suspense} fallback=${html`<${LoadingState}>저장소 관리 불러오는 중...<//>`}>
              <${LazyRepositoryManagement} />
            <//>`}
      <//>
    </div>
  `
}
