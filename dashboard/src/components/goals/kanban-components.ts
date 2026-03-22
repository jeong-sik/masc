// Kanban board components: KanbanCard, TaskBacklog

import { html } from 'htm/preact'
import { Card } from '../common/card'
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
    <div class="kanban-card ${pClass}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${pClass}">${priorityLabel(p)}</span>
        <div class="kanban-card-title">${task.title}</div>
      </div>
      ${hasDescription ? html`
        <div
          class="task-description-preview ${isExpanded ? 'task-description-preview--expanded' : ''}"
          onClick=${() => toggleTaskExpand(task.id)}
        >
          ${isExpanded ? task.description : truncate(task.description ?? '', 80)}
        </div>
      ` : null}
      <div class="kanban-card-meta">
        ${task.created_at ? html`<${TimeAgo} timestamp=${task.created_at} />` : html`<span>-</span>`}
        ${task.assignee ? html`<span class="kanban-assignee">${task.assignee}</span>` : null}
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
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${todo.length}</span>
          </div>
          ${sortedTodo.length === 0
            ? html`<div class="empty-state" class="opacity-50">대기 중인 태스크가 없습니다</div>`
            : sortedTodo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${inProgress.length}</span>
          </div>
          ${sortedInProgress.length === 0
            ? html`<div class="empty-state" class="opacity-50">진행 중인 태스크가 없습니다</div>`
            : sortedInProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${done.length}</span>
          </div>
          ${sortedDone.length === 0
            ? html`<div class="empty-state" class="opacity-50">완료된 태스크가 없습니다</div>`
            : sortedDone.slice(0, 20).map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
          ${sortedDone.length > 20
            ? html`<div class="empty-state" class="opacity-50">...외 ${sortedDone.length - 20}개 더 있음</div>`
            : null}
        </div>
      </div>
    <//>
  `
}
