// Kanban board components: KanbanCard, TaskBacklog

import { html } from 'htm/preact'
import { Card } from '../common/card'
import { EmptyState } from '../common/feedback-state'
import { TimeAgo } from '../common/time-ago'
import { tasksByStatus } from '../../store'
import type { Task } from '../../types'
import { truncate } from '../../lib/truncate'
import {
  expandedTasks,
  toggleTaskExpand,
  priorityLabel,
  sortByPriority,
  sortByTimeDesc,
} from './goal-helpers'

export function KanbanCard({ task }: { task: Task }) {
  const p = task.priority ?? 4
  const pClass = p <= 1 ? 'p1' : p === 2 ? 'p2' : p === 3 ? 'p3' : 'p4'
  const isExpanded = expandedTasks.value.has(task.id)
  const hasDescription = Boolean(task.description)

  return html`
    <div class="kanban-card rounded-xl ${pClass}">
      <div class="kanban-card rounded-xl-header">
        <span class="priority-badge rounded priority-badge--${pClass}">${priorityLabel(p)}</span>
        <div class="kanban-card rounded-xl-title">${task.title}</div>
      </div>
      ${hasDescription ? html`
        <div
          class="task-description-preview transition-colors duration-150 ${isExpanded ? 'task-description-preview--expanded' : ''}"
          onClick=${() => toggleTaskExpand(task.id)}
        >
          ${isExpanded ? task.description : truncate(task.description ?? '', 80)}
        </div>
      ` : null}
      <div class="kanban-card rounded-xl-meta">
        ${task.created_at ? html`<${TimeAgo} timestamp=${task.created_at} />` : html`<span>-</span>`}
        ${task.assignee ? html`<span class="inline-flex items-center bg-[rgba(0,240,255,0.1)] text-[color:var(--accent)] px-2 py-1 gap-1 font-semibold before:content-['@'] rounded-lg">${task.assignee}</span>` : null}
      </div>
    </div>
  `
}

export function TaskBacklog() {
  const { todo, inProgress, done } = tasksByStatus.value
  const sortedTodo = [...todo].sort(sortByPriority)
  const sortedInProgress = [...inProgress].sort(sortByPriority)
  const sortedDone = [...done].sort(sortByTimeDesc)

  return html`
    <${Card} title="태스크 백로그" class="section mb-3.5">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(320px,1fr))] gap-6 items-start">
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[0.8rem] font-bold">${todo.length}</span>
          </div>
          ${sortedTodo.length === 0
            ? html`<${EmptyState}>대기 중인 태스크가 없습니다<//>`
            : sortedTodo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[0.8rem] font-bold">${inProgress.length}</span>
          </div>
          ${sortedInProgress.length === 0
            ? html`<${EmptyState}>진행 중인 태스크가 없습니다<//>`
            : sortedInProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[0.8rem] font-bold">${done.length}</span>
          </div>
          ${sortedDone.length === 0
            ? html`<${EmptyState}>완료된 태스크가 없습니다<//>`
            : sortedDone.slice(0, 20).map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
          ${sortedDone.length > 20
            ? html`<${EmptyState}>...외 ${sortedDone.length - 20}개 더 있음<//>`
            : null}
        </div>
      </div>
    <//>
  `
}
