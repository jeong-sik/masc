// Planning surface — task-first layout with collapsible goals and MDAL

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import {
  goals,
  goalsLoading,
  mdalLoops,
  mdalLoading,
  mdalSnapshotState,
  lastMdalError,
  refreshGoals,
  refreshMdal,
  tasksByStatus,
} from '../store'
import type { Goal, MdalLoop, Task } from '../types'

// -- Filter state ------------------------------------------------

type HorizonFilter = 'all' | 'short' | 'mid' | 'long'
type StatusFilter = 'all' | 'active' | 'completed' | 'paused'

const horizonFilter = signal<HorizonFilter>('all')
const statusFilter = signal<StatusFilter>('all')

// -- Expand state for task description previews ------------------

const expandedTasks = signal<Set<string>>(new Set())

function toggleTaskExpand(id: string) {
  const next = new Set(expandedTasks.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedTasks.value = next
}

// -- Derived data ------------------------------------------------

const filteredGoals = computed(() => {
  let list = goals.value
  if (horizonFilter.value !== 'all') {
    list = list.filter(g => g.horizon === horizonFilter.value)
  }
  if (statusFilter.value !== 'all') {
    list = list.filter(g => g.status === statusFilter.value)
  }
  return list
})

const groupedByHorizon = computed(() => {
  const groups: Record<string, Goal[]> = { short: [], mid: [], long: [] }
  for (const g of filteredGoals.value) {
    const bucket = groups[g.horizon]
    if (bucket) bucket.push(g)
  }
  return groups
})

const loopsList = computed(() => {
  const loops = Array.from(mdalLoops.value.values())
  loops.sort((a, b) => {
    if (a.status === 'running' && b.status !== 'running') return -1
    if (b.status === 'running' && a.status !== 'running') return 1
    if (a.status === 'interrupted' && b.status !== 'interrupted') return -1
    if (b.status === 'interrupted' && a.status !== 'interrupted') return 1
    return b.elapsed_seconds - a.elapsed_seconds
  })
  return loops
})

// -- Helpers -----------------------------------------------------

function priorityStars(n: number): string {
  return '\u2605'.repeat(Math.min(n, 5)) + '\u2606'.repeat(Math.max(0, 5 - n))
}

function horizonLabel(h: string): string {
  switch (h) {
    case 'short': return 'Short-term'
    case 'mid': return 'Mid-term'
    case 'long': return 'Long-term'
    default: return h
  }
}

function horizonColor(h: string): string {
  switch (h) {
    case 'short': return '#4ade80'
    case 'mid': return '#f59e0b'
    case 'long': return '#818cf8'
    default: return '#888'
  }
}

function formatElapsed(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`
}

function formatMetric(value: number): string {
  return value.toFixed(4)
}

function formatMetricDelta(loop: MdalLoop): string {
  const delta = loop.current_metric - loop.baseline_metric
  const sign = delta >= 0 ? '+' : ''
  return `${sign}${delta.toFixed(4)}`
}

function priorityLabel(p: number): string {
  switch (p) {
    case 1: return 'P1'
    case 2: return 'P2'
    case 3: return 'P3'
    default: return 'P4'
  }
}

function sortByPriority(a: Task, b: Task): number {
  return (a.priority ?? 4) - (b.priority ?? 4)
}

function sortByTimeDesc(a: Task, b: Task): number {
  const ta = a.updated_at ?? a.created_at ?? ''
  const tb = b.updated_at ?? b.created_at ?? ''
  return tb.localeCompare(ta)
}

function truncate(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text
  return text.slice(0, maxLen) + '...'
}

// -- Sub-components: Goals & MDAL (unchanged rendering logic) ----

function GoalRow({ goal }: { goal: Goal }) {
  return html`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${horizonColor(goal.horizon)}">
            ${horizonLabel(goal.horizon)}
          </span>
          <span class="goal-title">${goal.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${goal.priority}">${priorityStars(goal.priority)}</span>
          ${goal.metric ? html`<span class="goal-metric">${goal.metric}${goal.target_value ? ` \u2192 ${goal.target_value}` : ''}</span>` : null}
          ${goal.due_date ? html`<span class="goal-due">Due: <${TimeAgo} timestamp=${goal.due_date} /></span>` : null}
        </div>
        ${goal.last_review_note ? html`
          <div class="goal-review-note">${goal.last_review_note}</div>
        ` : null}
      </div>
      <div class="goal-row-right">
        <${StatusBadge} status=${goal.status} />
        <div class="goal-updated">
          <${TimeAgo} timestamp=${goal.updated_at} />
        </div>
      </div>
    </div>
  `
}

function HorizonGroup({ horizon, items }: { horizon: string; items: Goal[] }) {
  if (items.length === 0) return null
  const sorted = [...items].sort((a, b) => b.priority - a.priority)
  return html`
    <${Card} title="${horizonLabel(horizon)} Goals (${items.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${sorted.map(g => html`<${GoalRow} key=${g.id} goal=${g} />`)}
      </div>
    <//>
  `
}

function FilterBar() {
  return html`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${(['all', 'short', 'mid', 'long'] as HorizonFilter[]).map(h => html`
          <button
            class="goal-filter-btn ${horizonFilter.value === h ? 'active' : ''}"
            onClick=${() => { horizonFilter.value = h }}
          >
            ${h === 'all' ? 'All' : horizonLabel(h)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${(['all', 'active', 'completed', 'paused'] as StatusFilter[]).map(s => html`
          <button
            class="goal-filter-btn ${statusFilter.value === s ? 'active' : ''}"
            onClick=${() => { statusFilter.value = s }}
          >
            ${s === 'all' ? 'All' : s.charAt(0).toUpperCase() + s.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `
}

function GoalsSummary() {
  const all = goals.value
  const active = all.filter(g => g.status === 'active').length
  const completed = all.filter(g => g.status === 'completed').length
  const byHorizon = { short: 0, mid: 0, long: 0 }
  for (const g of all) {
    if (g.horizon in byHorizon) byHorizon[g.horizon as keyof typeof byHorizon]++
  }
  return html`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${all.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${active}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${completed}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('short')}">${byHorizon.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('mid')}">${byHorizon.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('long')}">${byHorizon.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `
}

function LoopRow({ loop }: { loop: MdalLoop }) {
  const latest = loop.history[0]
  const latestToolSummary =
    loop.latest_tool_names && loop.latest_tool_names.length > 0
      ? `${loop.latest_tool_call_count ?? loop.latest_tool_names.length} tool${(loop.latest_tool_call_count ?? loop.latest_tool_names.length) === 1 ? '' : 's'}: ${loop.latest_tool_names.join(', ')}`
      : 'No evidence yet'

  return html`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${loop.profile}</div>
            <div class="planning-loop-sub">${loop.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${StatusBadge} status=${loop.status} />
            <span class="pill">${loop.current_iteration}${loop.max_iterations > 0 ? `/${loop.max_iterations}` : ''}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${formatMetric(loop.baseline_metric)}</span>
          <span>Current ${formatMetric(loop.current_metric)}</span>
          <span class=${formatMetricDelta(loop).startsWith('+') ? 'planning-loop-good' : 'planning-loop-bad'}>
            Delta ${formatMetricDelta(loop)}
          </span>
          <span>Elapsed ${formatElapsed(loop.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${loop.target || 'No explicit target provided'}</div>
        ${(loop.stop_reason || loop.error_message)
          ? html`
              <div class="planning-loop-footnote">
                ${loop.error_message ?? loop.stop_reason}
              </div>
            `
          : null}
        <div class="planning-loop-footnote">
          ${loop.strict_mode ? 'Strict hard evidence' : 'Legacy'} · ${loop.worker_engine ?? 'unknown engine'} · ${latestToolSummary}
        </div>
        ${latest
          ? html`
              <div class="planning-loop-footnote">
                Latest iteration #${latest.iteration}: ${latest.changes || latest.next_suggestion || 'No narrative'}
              </div>
            `
          : html`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `
}

// -- Enhanced Kanban components ----------------------------------

function KanbanCard({ task }: { task: Task }) {
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

function TaskBacklog() {
  const { todo, inProgress, done } = tasksByStatus.value
  const sortedTodo = [...todo].sort(sortByPriority)
  const sortedInProgress = [...inProgress].sort(sortByPriority)
  const sortedDone = [...done].sort(sortByTimeDesc)

  return html`
    <${Card} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${todo.length}</span>
          </div>
          ${sortedTodo.length === 0
            ? html`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`
            : sortedTodo.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${inProgress.length}</span>
          </div>
          ${sortedInProgress.length === 0
            ? html`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`
            : sortedInProgress.map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${done.length}</span>
          </div>
          ${sortedDone.length === 0
            ? html`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`
            : sortedDone.slice(0, 20).map(t => html`<${KanbanCard} key=${t.id} task=${t} />`)}
          ${sortedDone.length > 20
            ? html`<div class="empty-state" style="opacity: 0.5;">...and ${sortedDone.length - 20} more</div>`
            : null}
        </div>
      </div>
    <//>
  `
}

// -- Main export -------------------------------------------------

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
      <${SurfaceSemanticIntro} surfaceId="planning" />

      <!-- Step 1: Task-based stats grid -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Total tasks</div>
          <div class="stat-value">${totalTasks}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">TODO</div>
          <div class="stat-value" style="color:#e0e0e0">${todo.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">In Progress</div>
          <div class="stat-value" style="color:#fbbf24">${inProgress.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Done</div>
          <div class="stat-value" style="color:#4ade80">${done.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">High Priority</div>
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
          ${goalsLoading.value || mdalLoading.value ? 'Refreshing...' : 'Refresh planning data'}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${TaskBacklog} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" ...${hasGoals ? { open: true } : {}}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${goals.value.length}</span>
        </summary>
        <div>
          ${hasGoals ? html`
            <${GoalsSummary} />
            <${FilterBar} />
            ${goalsLoading.value && goals.value.length === 0
              ? html`<div class="loading-indicator">Loading goals...</div>`
              : filteredGoals.value.length === 0
                ? html`<div class="empty-state">No goals match the current filters</div>`
                : html`
                    <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
                    <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
                    <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
                  `}
          ` : html`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" ...${hasLoops ? { open: true } : {}}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${loops.length}</span>
        </summary>
        <div>
          ${mdalLoading.value && loops.length === 0
            ? html`<div class="loading-indicator">Loading MDAL loops...</div>`
            : loops.length === 0 && (mdalState === 'error' || lastMdalError.value)
              ? html`<div class="empty-state">MDAL snapshot could not be loaded${lastMdalError.value ? `: ${lastMdalError.value}` : ''}. Check backend health.</div>`
              : loops.length === 0
                ? html`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`
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
