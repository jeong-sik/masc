// Tasks tab — Task list grouped by status

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { tasksByStatus } from '../store'
import type { Task } from '../types'

function TaskRow({ task }: { task: Task }) {
  return html`
    <div class="task-row">
      <${StatusBadge} status=${task.status} />
      <div class="task-info">
        <span class="task-title">${task.title}</span>
        ${task.assignee
          ? html`<span class="task-assignee">${task.assignee}</span>`
          : null}
      </div>
      ${task.created_at ? html`<${TimeAgo} timestamp=${task.created_at} />` : null}
    </div>
  `
}

export function Tasks() {
  const { todo, inProgress, done } = tasksByStatus.value

  return html`
    <div class="grid-2col">
      <${Card} title="In Progress (${inProgress.length})" class="section">
        <div class="task-list">
          ${inProgress.length === 0
            ? html`<div class="empty-state">No tasks in progress</div>`
            : inProgress.map(t => html`<${TaskRow} key=${t.id} task=${t} />`)}
        </div>
      <//>

      <${Card} title="To Do (${todo.length})" class="section">
        <div class="task-list">
          ${todo.length === 0
            ? html`<div class="empty-state">No pending tasks</div>`
            : todo.map(t => html`<${TaskRow} key=${t.id} task=${t} />`)}
        </div>
      <//>
    </div>

    ${done.length > 0
      ? html`
        <${Card} title="Done (${done.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${done.slice(0, 20).map(t => html`<${TaskRow} key=${t.id} task=${t} />`)}
            ${done.length > 20
              ? html`<div class="empty-state">...and ${done.length - 20} more</div>`
              : null}
          </div>
        <//>
      `
      : null}
  `
}
