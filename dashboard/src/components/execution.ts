// Execution tab — Product-owner oriented work queue and assignee visibility

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { activeAgents, tasksByStatus } from '../store'
import type { Task } from '../types'

function taskPriorityLabel(priority?: number): string {
  if (priority == null) return 'P3'
  if (priority <= 1) return 'P1'
  if (priority === 2) return 'P2'
  if (priority >= 4) return 'P4+'
  return 'P3'
}

function ExecutionTaskRow({ task }: { task: Task }) {
  return html`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${task.title}</div>
        <div class="council-sub">
          <span>${taskPriorityLabel(task.priority)}</span>
          ${task.assignee ? html`<span>Assignee: ${task.assignee}</span>` : html`<span>Unassigned</span>`}
          ${task.created_at ? html`<span><${TimeAgo} timestamp=${task.created_at} /></span>` : null}
        </div>
      </div>
      <span class="council-state ${task.status}">${task.status}</span>
    </div>
  `
}

export function Execution() {
  const grouped = tasksByStatus.value
  const inProgress = grouped.inProgress
  const todo = grouped.todo
  const done = grouped.done
  const agents = activeAgents.value
  const urgentTodo = todo.filter(t => (t.priority ?? 3) <= 2)
  const unassigned = todo.filter(t => !t.assignee)

  return html`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">In Progress</div>
        <div class="stat-value" style="color:#fbbf24">${inProgress.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Ready Queue</div>
        <div class="stat-value">${todo.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Urgent Ready</div>
        <div class="stat-value" style="color:#fb7185">${urgentTodo.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Done (Visible)</div>
        <div class="stat-value" style="color:#4ade80">${done.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${Card} title="Execution Queue" class="section">
        <div class="council-list">
          ${inProgress.length === 0
            ? html`<div class="empty-state">No active execution tasks</div>`
            : inProgress.slice(0, 20).map(task => html`<${ExecutionTaskRow} key=${task.id} task=${task} />`)}
        </div>
      <//>

      <${Card} title="Ready Queue" class="section">
        <div class="council-list">
          ${todo.length === 0
            ? html`<div class="empty-state">No ready tasks</div>`
            : todo.slice(0, 20).map(task => html`<${ExecutionTaskRow} key=${task.id} task=${task} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${Card} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${agents.length === 0
            ? html`<div class="empty-state">No active agents</div>`
            : agents.map(agent => html`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${agent.name}</div>
                    <div class="council-sub">
                      ${agent.current_task ? html`<span>${agent.current_task}</span>` : html`<span>Idle</span>`}
                    </div>
                  </div>
                  <${StatusBadge} status=${agent.status} />
                </div>
              `)}
        </div>
      <//>

      <${Card} title="Attention Needed" class="section">
        <div class="council-list">
          ${unassigned.length === 0
            ? html`<div class="empty-state">No unassigned tasks</div>`
            : unassigned.slice(0, 20).map(task => html`<${ExecutionTaskRow} key=${task.id} task=${task} />`)}
        </div>
      <//>
    </div>
  `
}
