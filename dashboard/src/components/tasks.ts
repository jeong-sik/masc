// Tasks tab — Kanban Board style

import { html } from "htm/preact"
import { TimeAgo } from "./common/time-ago"
import { tasksByStatus } from "../store"
import type { Task } from "../types"

function KanbanCard({ task }: { task: Task }) {
  // Priority 1=urgent, 5=low
  const pClass = (task.priority ?? 4) <= 1 ? "p1" : (task.priority ?? 4) === 2 ? "p2" : (task.priority ?? 4) === 3 ? "p3" : "p4"
  
  return html`
    <div class="kanban-card ${pClass}">
      <div class="kanban-card-title">${task.title}</div>
      <div class="kanban-card-meta">
        ${task.created_at ? html`<${TimeAgo} timestamp=${task.created_at} />` : html`<span>-</span>`}
        ${task.assignee ? html`<span class="kanban-assignee">${task.assignee}</span>` : null}
      </div>
    </div>
  `
}

export function Tasks() {
  const { todo, inProgress, done } = tasksByStatus.value

  return html`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${todo.length}</span>
        </div>
        ${todo.length === 0
          ? html`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`
          : todo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${inProgress.length}</span>
        </div>
        ${inProgress.length === 0
          ? html`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`
          : inProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${done.length}</span>
        </div>
        ${done.length === 0
          ? html`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`
          : done.slice(0, 20).map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        ${done.length > 20
          ? html`<div class="empty-state" style="opacity: 0.5;">...and ${done.length - 20} more</div>`
          : null}
      </div>
    </div>
  `
}
