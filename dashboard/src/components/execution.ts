// Execution tab — live dispatch board for ownership gaps, active work, and task-state drift

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { type MonitorTone, toEpoch, toneRank, normalizeKey, limitText, taskPriorityValue, taskPriorityLabel } from './common/monitor'
import type { AgentMotionSnapshot } from './common/agent-motion'
import { openAgentDetail } from './agent-detail'
import { agents, tasks, agentMotionMap } from '../store'
import type { Agent, Task } from '../types'

const QUIET_EXECUTION_MS = 10 * 60 * 1000
const STALE_EXECUTION_MS = 20 * 60 * 1000
type DispatchState = 'dispatchable' | 'drift' | 'loaded' | 'quiet' | 'offline'

interface TaskExecutionRow {
  task: Task
  assigneeAgent: Agent | null
  motion: AgentMotionSnapshot | null
  tone: MonitorTone
  note: string
  focus: string
  lastSignalAt: string | null
  lastTouchedAt: string | null
  ownerGap: boolean
  quiet: boolean
}

interface DispatchRow {
  agent: Agent
  motion: AgentMotionSnapshot
  tone: MonitorTone
  state: DispatchState
  note: string
  focus: string
  lastSignalAt: string | null
  activeTaskCount: number
}

type InterventionItem =
  | {
      kind: 'task'
      key: string
      tone: MonitorTone
      title: string
      subtitle: string
      timestamp: string | null
      taskRow: TaskExecutionRow
    }
  | {
      kind: 'agent'
      key: string
      tone: MonitorTone
      title: string
      subtitle: string
      timestamp: string | null
      agentRow: DispatchRow
    }


function taskStatusLabel(status: Task['status']): string {
  switch (status) {
    case 'in_progress': return 'In Progress'
    case 'claimed': return 'Claimed'
    case 'done': return 'Done'
    case 'cancelled': return 'Cancelled'
    default: return 'Todo'
  }
}

function dispatchStateLabel(state: DispatchState): string {
  switch (state) {
    case 'dispatchable': return 'Dispatch'
    case 'drift': return 'Drift'
    case 'quiet': return 'Quiet'
    case 'offline': return 'Offline'
    default: return 'Loaded'
  }
}

function lastTouchedAt(task: Task): string | null {
  return task.updated_at ?? task.created_at ?? null
}

function buildTaskRow(
  task: Task,
  agentsByName: Map<string, Agent>,
  motionByName: Map<string, AgentMotionSnapshot>,
): TaskExecutionRow {
  const assigneeKey = normalizeKey(task.assignee)
  const assigneeAgent = assigneeKey ? (agentsByName.get(assigneeKey) ?? null) : null
  const motion = assigneeAgent ? (motionByName.get(assigneeKey) ?? null) : null
  const lastSignalAt = motion?.lastActivityAt ?? assigneeAgent?.last_seen ?? null
  const signalAgeMs = lastSignalAt ? Math.max(0, Date.now() - toEpoch(lastSignalAt)) : Number.POSITIVE_INFINITY
  const description = limitText(task.description)
  const ownerFocus = limitText(assigneeAgent?.current_task) ?? motion?.lastActivityText ?? null
  const activeTask = task.status === 'claimed' || task.status === 'in_progress'

  let tone: MonitorTone = 'ok'
  let note = 'Fresh owner coverage'
  let focus = ownerFocus ?? description ?? task.id
  let ownerGap = false
  let quiet = false

  if (task.status === 'todo') {
    if (!task.assignee) {
      ownerGap = true
      tone = taskPriorityValue(task.priority) <= 2 ? 'bad' : 'warn'
      note = taskPriorityValue(task.priority) <= 2 ? 'Urgent ready work has no owner' : 'Ready work has no owner'
      focus = 'Assign an agent before this queue item slips.'
    } else if (!assigneeAgent) {
      ownerGap = true
      tone = 'bad'
      note = 'Assigned owner is not present in the room'
      focus = 'Reassign or bring the owner back online.'
    } else if (assigneeAgent.status === 'offline' || assigneeAgent.status === 'inactive') {
      ownerGap = true
      tone = 'bad'
      note = 'Assigned owner is offline'
      focus = 'Queue item is blocked until ownership changes.'
    } else if (signalAgeMs > QUIET_EXECUTION_MS) {
      tone = 'warn'
      note = 'Owner exists but live signal is quiet'
      focus = ownerFocus ?? 'Owner may need a nudge before pickup.'
    } else if ((motion?.activeAssignedCount ?? 0) > 0 || Boolean(assigneeAgent.current_task?.trim())) {
      tone = 'warn'
      note = 'Owner is already carrying active work'
      focus = ownerFocus ?? `${motion?.activeAssignedCount ?? 0} active tasks already assigned.`
    } else {
      note = 'Ready and covered by a fresh operator'
      focus = ownerFocus ?? description ?? 'This can be picked up immediately.'
    }
  } else if (activeTask) {
    if (!task.assignee) {
      ownerGap = true
      tone = 'bad'
      note = 'Active work has no assignee'
      focus = 'Claim or reassign this task immediately.'
    } else if (!assigneeAgent) {
      ownerGap = true
      tone = 'bad'
      note = 'Assigned owner is not active in the room'
      focus = 'Execution is orphaned until ownership is restored.'
    } else if (assigneeAgent.status === 'offline' || assigneeAgent.status === 'inactive') {
      ownerGap = true
      tone = 'bad'
      note = 'Assigned owner is offline'
      focus = ownerFocus ?? 'Execution has no live operator right now.'
    } else if (signalAgeMs > STALE_EXECUTION_MS) {
      quiet = true
      tone = 'bad'
      note = 'Assigned owner has gone quiet'
      focus = ownerFocus ?? 'Fresh operator signal is missing.'
    } else if (signalAgeMs > QUIET_EXECUTION_MS) {
      quiet = true
      tone = 'warn'
      note = 'Execution has been quiet for too long'
      focus = ownerFocus ?? 'Check whether this work is blocked.'
    } else if (!assigneeAgent.current_task?.trim()) {
      tone = 'warn'
      note = task.status === 'claimed'
        ? 'Claimed work is waiting for explicit focus'
        : 'Owner is live but current_task is empty'
      focus = ownerFocus ?? 'Task state and agent focus are drifting apart.'
    } else {
      note = 'Execution has fresh owner coverage'
      focus = ownerFocus ?? description ?? task.id
    }
  }

  return {
    task,
    assigneeAgent,
    motion,
    tone,
    note,
    focus,
    lastSignalAt,
    lastTouchedAt: lastTouchedAt(task),
    ownerGap,
    quiet,
  }
}

function buildDispatchRow(
  agent: Agent,
  motionByName: Map<string, AgentMotionSnapshot>,
): DispatchRow {
  const motion = motionByName.get(normalizeKey(agent.name)) ?? {
    activeAssignedCount: 0,
    lastActivityAt: null,
    lastActivityText: null,
  }
  const lastSignalAt = motion.lastActivityAt ?? agent.last_seen ?? null
  const signalAgeMs = lastSignalAt ? Math.max(0, Date.now() - toEpoch(lastSignalAt)) : Number.POSITIVE_INFINITY
  const hasCurrentTask = Boolean(agent.current_task?.trim())
  const activeTaskCount = motion.activeAssignedCount
  const hasLoad = hasCurrentTask || activeTaskCount > 0

  let state: DispatchState = 'loaded'
  let tone: MonitorTone = 'ok'
  let note = 'Healthy active load'
  let focus = limitText(agent.current_task) ?? motion.lastActivityText ?? 'Ready for assignment'

  if (agent.status === 'offline' || agent.status === 'inactive') {
    state = 'offline'
    tone = 'bad'
    note = 'Agent is unavailable'
  } else if (hasLoad && signalAgeMs > STALE_EXECUTION_MS) {
    state = 'quiet'
    tone = 'bad'
    note = 'Working without a fresh signal'
  } else if (activeTaskCount > 0 && !hasCurrentTask) {
    state = 'drift'
    tone = 'warn'
    note = 'Claimed work exists but current_task is empty'
    focus = `${activeTaskCount} active tasks need explicit focus.`
  } else if (hasCurrentTask && activeTaskCount === 0) {
    state = 'drift'
    tone = 'warn'
    note = 'current_task has no matching claimed work'
    focus = limitText(agent.current_task) ?? 'Task metadata and operator state drifted.'
  } else if (!hasLoad && signalAgeMs <= QUIET_EXECUTION_MS) {
    state = 'dispatchable'
    tone = 'ok'
    note = 'Fresh signal and no active load'
    focus = motion.lastActivityText ?? 'Ready for assignment.'
  } else if (!hasLoad) {
    state = 'quiet'
    tone = signalAgeMs > STALE_EXECUTION_MS ? 'bad' : 'warn'
    note = signalAgeMs > STALE_EXECUTION_MS ? 'No fresh signal while idle' : 'Reachable, but not freshly active'
    focus = motion.lastActivityText ?? 'Likely available after a quick check-in.'
  } else if (signalAgeMs > QUIET_EXECUTION_MS) {
    state = 'loaded'
    tone = 'warn'
    note = 'Execution load is healthy but slightly quiet'
    focus = limitText(agent.current_task) ?? `${activeTaskCount} active tasks in flight.`
  }

  return {
    agent,
    motion,
    tone,
    state,
    note,
    focus,
    lastSignalAt,
    activeTaskCount,
  }
}

function ExecutionStat({
  label,
  value,
  color,
  caption,
}: {
  label: string
  value: string | number
  color?: string
  caption?: string
}) {
  return html`
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value" style=${color ? `color:${color}` : ''}>${value}</div>
      ${caption ? html`<div class="monitor-stat-caption">${caption}</div>` : null}
    </div>
  `
}

function InterventionRow({ item }: { item: InterventionItem }) {
  return html`
    <div class="execution-alert ${item.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${item.title}</div>
        <div class="monitor-alert-subtitle">${item.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${item.tone}">
          ${item.kind === 'task' ? taskPriorityLabel(item.taskRow.task.priority) : dispatchStateLabel(item.agentRow.state)}
        </span>
        ${item.kind === 'task'
          ? html`<span>${taskStatusLabel(item.taskRow.task.status)}</span>`
          : html`<span>${item.agentRow.agent.name}</span>`}
        ${item.timestamp ? html`<span><${TimeAgo} timestamp=${item.timestamp} /></span>` : html`<span>No signal</span>`}
      </div>
    </div>
  `
}

function TaskWatchRow({ row }: { row: TaskExecutionRow }) {
  return html`
    <div class="execution-task-row ${row.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${row.tone}">${taskPriorityLabel(row.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${row.task.title}</span>
            <span class="monitor-sub">${row.task.id}</span>
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        ${row.assigneeAgent ? html`<${StatusBadge} status=${row.assigneeAgent.status} />` : html`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${row.tone}">${taskStatusLabel(row.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${row.task.assignee ? html`<span>Owner ${row.task.assignee}</span>` : html`<span>Unassigned</span>`}
        ${row.lastTouchedAt ? html`<span>Touched <${TimeAgo} timestamp=${row.lastTouchedAt} /></span>` : null}
        ${row.lastSignalAt ? html`<span>Signal <${TimeAgo} timestamp=${row.lastSignalAt} /></span>` : html`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${row.assigneeAgent?.current_task
        && limitText(row.assigneeAgent.current_task) !== row.focus
        ? html`<div class="monitor-footnote">Owner focus: ${limitText(row.assigneeAgent.current_task)}</div>`
        : null}
    </div>
  `
}

function DispatchAgentRow({ row }: { row: DispatchRow }) {
  const { agent } = row

  return html`
    <button class="monitor-row ${row.tone}" onClick=${() => openAgentDetail(agent.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${agent.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${agent.name}</span>
            ${agent.koreanName ? html`<span class="monitor-sub">${agent.koreanName}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${StatusBadge} status=${agent.status} />
        <span class="monitor-pill ${row.tone}">${dispatchStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${row.lastSignalAt ? html`<span>Signal <${TimeAgo} timestamp=${row.lastSignalAt} /></span>` : html`<span>No recent signal</span>`}
        <span>${row.activeTaskCount > 0 ? `${row.activeTaskCount} active tasks` : 'No active tasks'}</span>
        ${agent.model ? html`<span>${agent.model}</span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
    </button>
  `
}

export function Execution() {
  const agentList = agents.value
  const taskList = tasks.value
  const agentsByName = new Map(agentList.map(agent => [normalizeKey(agent.name), agent] as const))
  const motionByName = agentMotionMap.value

  const activeRows = taskList
    .filter(task => task.status === 'claimed' || task.status === 'in_progress')
    .map(task => buildTaskRow(task, agentsByName, motionByName))
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.lastSignalAt ?? b.lastTouchedAt) - toEpoch(a.lastSignalAt ?? a.lastTouchedAt)
    })

  const readyRows = taskList
    .filter(task => task.status === 'todo')
    .map(task => buildTaskRow(task, agentsByName, motionByName))
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      const priorityDiff = taskPriorityValue(a.task.priority) - taskPriorityValue(b.task.priority)
      if (priorityDiff !== 0) return priorityDiff
      return toEpoch(a.lastTouchedAt) - toEpoch(b.lastTouchedAt)
    })

  const dispatchRows = agentList
    .map(agent => buildDispatchRow(agent, motionByName))
    .filter(row => row.state === 'dispatchable' || row.state === 'drift' || row.state === 'quiet')
    .sort((a, b) => {
      if (a.state === 'dispatchable' && b.state !== 'dispatchable') return -1
      if (b.state === 'dispatchable' && a.state !== 'dispatchable') return 1
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.lastSignalAt) - toEpoch(a.lastSignalAt)
    })

  const interventionItems: InterventionItem[] = [
    ...activeRows
      .filter(row => row.tone !== 'ok')
      .map(row => ({
        kind: 'task' as const,
        key: `active-${row.task.id}`,
        tone: row.tone,
        title: row.task.title,
        subtitle: `${row.note} · ${row.focus}`,
        timestamp: row.lastSignalAt ?? row.lastTouchedAt,
        taskRow: row,
      })),
    ...readyRows
      .filter(row => row.tone === 'bad')
      .map(row => ({
        kind: 'task' as const,
        key: `ready-${row.task.id}`,
        tone: row.tone,
        title: row.task.title,
        subtitle: `${row.note} · ${row.focus}`,
        timestamp: row.lastTouchedAt,
        taskRow: row,
      })),
    ...dispatchRows
      .filter(row => row.state === 'drift' || row.tone === 'bad')
      .map(row => ({
        kind: 'agent' as const,
        key: `agent-${row.agent.name}`,
        tone: row.tone,
        title: row.agent.name,
        subtitle: `${row.note} · ${row.focus}`,
        timestamp: row.lastSignalAt,
        agentRow: row,
      })),
  ]
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.timestamp) - toEpoch(a.timestamp)
    })
    .slice(0, 8)

  const dispatchableAgents = dispatchRows.filter(row => row.state === 'dispatchable')
  const ownershipGaps = [...activeRows, ...readyRows].filter(row => row.ownerGap)
  const quietExecution = activeRows.filter(row => row.quiet)

  return html`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${ExecutionStat} label="Active work" value=${activeRows.length} color="#fbbf24" caption="claimed + in progress" />
        <${ExecutionStat} label="Needs intervention" value=${interventionItems.length} color=${interventionItems.length > 0 ? '#fb7185' : '#4ade80'} caption="stalled or drifting now" />
        <${ExecutionStat} label="Ownership gaps" value=${ownershipGaps.length} color=${ownershipGaps.length > 0 ? '#fb7185' : '#4ade80'} caption="missing or unavailable owners" />
        <${ExecutionStat} label="Dispatchable agents" value=${dispatchableAgents.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${ExecutionStat} label="Quiet execution" value=${quietExecution.length} color=${quietExecution.length > 0 ? '#fbbf24' : '#4ade80'} caption="active tasks with aging signals" />
      </div>

      <${Card} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${interventionItems.length === 0
            ? html`<div class="empty-state">No active execution risks right now</div>`
            : interventionItems.map(item => html`<${InterventionRow} key=${item.key} item=${item} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${Card} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${readyRows.length === 0
              ? html`<div class="empty-state">No ready tasks in the queue</div>`
              : readyRows.slice(0, 10).map(row => html`<${TaskWatchRow} key=${row.task.id} row=${row} />`)}
          </div>
        <//>

        <${Card} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${dispatchRows.length === 0
              ? html`<div class="empty-state">No agent capacity or drift signals right now</div>`
              : dispatchRows.map(row => html`<${DispatchAgentRow} key=${row.agent.name} row=${row} />`)}
          </div>
        <//>
      </div>

      <${Card} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${activeRows.length === 0
            ? html`<div class="empty-state">No active execution tasks</div>`
            : activeRows.map(row => html`<${TaskWatchRow} key=${row.task.id} row=${row} />`)}
        </div>
      <//>
    </div>
  `
}
