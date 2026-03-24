// Kanban board components: KanbanCard, TaskBacklog

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { EmptyState } from '../common/empty-state'
import { Card } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { showToast } from '../common/toast'
import { tasksByStatus, refreshExecution } from '../../store'
import { deleteTask } from '../../api/actions'
import type { Task } from '../../types'
import { truncate } from '../../lib/truncate'
import {
  expandedTasks,
  toggleTaskExpand,
  priorityLabel,
  sortByPriority,
  sortByTimeDesc,
} from './goal-helpers'

const deletingTaskId = signal<string | null>(null)

export function KanbanCard({ task }: { task: Task }) {
  const p = task.priority ?? 4
  const pClass = p <= 1 ? 'p1' : p === 2 ? 'p2' : p === 3 ? 'p3' : 'p4'
  const isExpanded = expandedTasks.value.has(task.id)
  const hasDescription = Boolean(task.description)
  const isDeleting = deletingTaskId.value === task.id

  async function handleDelete(e: Event) {
    e.stopPropagation()
    if (!confirm(`"${task.title}" 태스크를 삭제하시겠습니까?`)) return
    deletingTaskId.value = task.id
    try {
      await deleteTask(task.id)
      showToast('태스크를 삭제했습니다', 'success')
      await refreshExecution({ force: true })
    } catch {
      showToast('태스크 삭제에 실패했습니다', 'error')
    } finally {
      deletingTaskId.value = null
    }
  }

  return html`
    <div class="kanban-card rounded-xl ${pClass} group">
      <div class="kanban-card rounded-xl-header">
        <span class="priority-badge rounded priority-badge--${pClass}">${priorityLabel(p)}</span>
        <div class="kanban-card rounded-xl-title flex-1">${task.title}</div>
        <button type="button"
          class="px-2 py-0.5 rounded text-[10px] font-semibold border border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.1)] text-[#f87171] hover:bg-[rgba(239,68,68,0.2)] transition-all cursor-pointer opacity-0 group-hover:opacity-100 disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
          onClick=${handleDelete}
          disabled=${isDeleting}
        >
          ${isDeleting ? '...' : 'x'}
        </button>
      </div>
      ${hasDescription ? html`
        <div
          class="text-[13px] text-[var(--text-dim)] cursor-pointer transition-colors duration-150 hover:text-[var(--text-body)]"
          onClick=${() => toggleTaskExpand(task.id)}
        >
          ${isExpanded ? task.description : truncate(task.description ?? '', 80)}
        </div>
      ` : null}
      <div class="kanban-card rounded-xl-meta">
        ${task.created_at ? html`<${TimeAgo} timestamp=${task.created_at} />` : html`<span>-</span>`}
        ${task.assignee ? html`<span class="inline-flex items-center bg-[rgba(0,240,255,0.1)] text-[var(--accent)] px-2 py-1 gap-1 font-semibold before:content-['@'] rounded-lg">${task.assignee}</span>` : null}
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
    <${Card} title="태스크 백로그" class="section mb-4">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(320px,1fr))] gap-6 items-start">
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[13px] font-bold">${todo.length}</span>
          </div>
          ${sortedTodo.length === 0
            ? html`<${EmptyState} message="대기 중인 태스크가 없습니다" compact />`
            : sortedTodo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[13px] font-bold">${inProgress.length}</span>
          </div>
          ${sortedInProgress.length === 0
            ? html`<${EmptyState} message="진행 중인 태스크가 없습니다" compact />`
            : sortedInProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[13px] font-bold">${done.length}</span>
          </div>
          ${sortedDone.length === 0
            ? html`<${EmptyState} message="완료된 태스크가 없습니다" compact />`
            : sortedDone.slice(0, 20).map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
          ${sortedDone.length > 20
            ? html`<${EmptyState} message=${`...외 ${sortedDone.length - 20}개 더 있음`} compact />`
            : null}
        </div>
      </div>
    <//>
  `
}
