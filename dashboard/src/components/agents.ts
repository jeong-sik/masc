// Agents tab — live monitoring surface for agent and keeper health

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { MitosisRing } from './common/mitosis-ring'
import { TimeAgo } from './common/time-ago'
import { buildAgentMotion, type AgentMotionSnapshot } from './common/agent-motion'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import {
  agents,
  keepers,
  boardPosts,
  tasks,
  messages,
  keeperLifecycles,
  staleKeepers,
} from '../store'
import type { Agent, Keeper, KeeperLifecycleState } from '../types'
import { journal } from '../sse'

const QUIET_AGENT_MS = 10 * 60 * 1000
const STALE_AGENT_MS = 20 * 60 * 1000
const HOT_KEEPER_RATIO = 0.8

type MonitorTone = 'ok' | 'warn' | 'bad'
type AgentMonitorState = 'working' | 'watching' | 'quiet' | 'offline'
type KeeperMonitorState = 'healthy' | 'warning' | 'critical'

interface AgentMonitorRow {
  agent: Agent
  motion: AgentMotionSnapshot
  lastSignalAt: string | null
  activeTaskCount: number
  state: AgentMonitorState
  tone: MonitorTone
  focus: string
  note: string
}

interface KeeperMonitorRow {
  keeper: Keeper
  lifecycle: KeeperLifecycleState | 'idle'
  state: KeeperMonitorState
  tone: MonitorTone
  focus: string
  note: string
}

type AttentionItem =
  | {
      kind: 'agent'
      key: string
      tone: MonitorTone
      title: string
      subtitle: string
      timestamp: string | null
      agent: Agent
    }
  | {
      kind: 'keeper'
      key: string
      tone: MonitorTone
      title: string
      subtitle: string
      timestamp: string | null
      keeper: Keeper
    }

function toEpoch(value: string | number | null | undefined): number {
  if (value == null) return 0
  const parsed = typeof value === 'number' ? value : Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function toneRank(tone: MonitorTone): number {
  switch (tone) {
    case 'bad': return 2
    case 'warn': return 1
    default: return 0
  }
}

function agentStateLabel(state: AgentMonitorState): string {
  switch (state) {
    case 'working': return 'Working'
    case 'watching': return 'Watching'
    case 'quiet': return 'Quiet'
    case 'offline': return 'Offline'
  }
}

function keeperStateLabel(state: KeeperMonitorState): string {
  switch (state) {
    case 'critical': return 'Critical'
    case 'warning': return 'Watch'
    default: return 'Healthy'
  }
}

function formatContext(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '—'
  return `${Math.round(value * 100)}%`
}

function keeperFocus(keeper: Keeper): string {
  return keeper.agent?.current_task
    ?? keeper.skill_primary
    ?? keeper.last_proactive_reason
    ?? keeper.memory_recent_note
    ?? 'No active focus'
}

function keeperContinuity(keeper: Keeper): string {
  const pieces = [
    `Gen ${keeper.generation ?? '—'}`,
    `Turns ${keeper.turn_count ?? 0}`,
    `Handoffs ${keeper.handoff_count_total ?? 0}`,
  ]
  if ((keeper.compaction_count ?? 0) > 0) {
    pieces.push(`Compactions ${keeper.compaction_count}`)
  }
  return pieces.join(' · ')
}

function buildAgentRow(agent: Agent): AgentMonitorRow {
  const motion = buildAgentMotion(agent.name, tasks.value, messages.value, journal.value, {
    currentTask: agent.current_task,
    lastSeen: agent.last_seen,
    boardPosts: boardPosts.value,
    keepers: keepers.value,
  })
  const lastSignalAt = motion.lastActivityAt ?? agent.last_seen ?? null
  const signalAgeMs = lastSignalAt ? Math.max(0, Date.now() - toEpoch(lastSignalAt)) : Number.POSITIVE_INFINITY
  const hasWork = Boolean(agent.current_task?.trim()) || motion.activeAssignedCount > 0

  let state: AgentMonitorState = 'watching'
  let tone: MonitorTone = 'ok'
  let note = 'Healthy live signal'

  if (agent.status === 'offline' || agent.status === 'inactive') {
    state = 'offline'
    tone = 'bad'
    note = lastSignalAt ? 'Offline or inactive' : 'No recent presence'
  } else if (signalAgeMs > STALE_AGENT_MS) {
    state = 'quiet'
    tone = 'bad'
    note = hasWork ? 'Working without a fresh signal' : 'No fresh agent signal'
  } else if (hasWork) {
    state = 'working'
    tone = signalAgeMs > QUIET_AGENT_MS ? 'warn' : 'ok'
    note = signalAgeMs > QUIET_AGENT_MS ? 'Execution looks quiet for too long' : 'Task and live signal aligned'
  } else if (signalAgeMs > QUIET_AGENT_MS) {
    state = 'quiet'
    tone = 'warn'
    note = 'Quiet but still reachable'
  } else if (agent.status === 'idle') {
    state = 'watching'
    tone = 'ok'
    note = 'Standing by for the next task'
  }

  return {
    agent,
    motion,
    lastSignalAt,
    activeTaskCount: motion.activeAssignedCount,
    state,
    tone,
    focus:
      agent.current_task?.trim()
      || (motion.activeAssignedCount > 0
        ? `${motion.activeAssignedCount} claimed tasks waiting for explicit current_task`
        : motion.lastActivityText
          ?? 'Idle / waiting for assignment'),
    note,
  }
}

function buildKeeperRow(keeper: Keeper): KeeperMonitorRow {
  const lifecycle = keeperLifecycles.value.get(keeper.name) ?? 'idle'
  const isStale = staleKeepers.value.has(keeper.name)
  const ratio = keeper.context_ratio ?? 0

  let state: KeeperMonitorState = 'healthy'
  let tone: MonitorTone = 'ok'
  let note = 'Heartbeat and context look healthy'

  if (keeper.status === 'offline' || isStale || lifecycle === 'handoff-imminent') {
    state = 'critical'
    tone = 'bad'
    note = isStale
      ? 'Heartbeat stale'
      : lifecycle === 'handoff-imminent'
        ? 'Handoff imminent'
        : 'Keeper offline'
  } else if (
    lifecycle === 'preparing'
    || lifecycle === 'compacting'
    || ratio >= HOT_KEEPER_RATIO
  ) {
    state = 'warning'
    tone = 'warn'
    note = ratio >= HOT_KEEPER_RATIO
      ? 'High context pressure'
      : lifecycle === 'compacting'
        ? 'Compaction in progress'
        : 'Preparing for handoff'
  }

  return {
    keeper,
    lifecycle,
    state,
    tone,
    focus: keeperFocus(keeper),
    note,
  }
}

function MonitorStat({
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

function AttentionRow({ item }: { item: AttentionItem }) {
  const onClick =
    item.kind === 'agent'
      ? () => openAgentDetail(item.agent.name)
      : () => openKeeperDetail(item.keeper)

  return html`
    <button class="monitor-alert ${item.tone}" onClick=${onClick}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${item.title}</div>
        <div class="monitor-alert-subtitle">${item.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${item.tone}">
          ${item.kind === 'agent' ? 'Agent' : 'Keeper'}
        </span>
        ${item.timestamp ? html`<span><${TimeAgo} timestamp=${item.timestamp} /></span>` : html`<span>No signal</span>`}
      </div>
    </button>
  `
}

function AgentWatchRow({ row }: { row: AgentMonitorRow }) {
  const { agent, motion } = row

  return html`
    <button class="monitor-row ${row.tone} state-${row.state}" onClick=${() => openAgentDetail(agent.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${agent.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${agent.name}</span>
            ${agent.koreanName ? html`<span class="monitor-sub">${agent.koreanName}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${MitosisRing} ratio=${agent.context_ratio} size=${34} stroke=${4} />
        <${StatusBadge} status=${agent.status} />
        <span class="monitor-pill ${row.tone} state-${row.state}">${agentStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${row.lastSignalAt ? html`<span>Signal <${TimeAgo} timestamp=${row.lastSignalAt} /></span>` : html`<span>No recent signal</span>`}
        <span>${row.activeTaskCount > 0 ? `${row.activeTaskCount} active tasks` : 'No active tasks'}</span>
        ${agent.model ? html`<span>${agent.model}</span>` : null}
        ${agent.last_seen ? html`<span>Seen <${TimeAgo} timestamp=${agent.last_seen} /></span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${motion.lastActivityText && motion.lastActivityText !== row.focus
        ? html`<div class="monitor-footnote">Latest detail: ${motion.lastActivityText}</div>`
        : null}
    </button>
  `
}

function KeeperWatchRow({ row }: { row: KeeperMonitorRow }) {
  const { keeper } = row

  return html`
    <button class="monitor-row ${row.tone} state-${row.state}" onClick=${() => openKeeperDetail(keeper)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${keeper.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${keeper.name}</span>
            ${keeper.koreanName ? html`<span class="monitor-sub">${keeper.koreanName}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${MitosisRing} ratio=${keeper.context_ratio} size=${34} stroke=${4} />
        <${StatusBadge} status=${keeper.status} />
        <span class="monitor-pill ${row.tone}">${keeperStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${keeper.last_heartbeat ? html`<span>Heartbeat <${TimeAgo} timestamp=${keeper.last_heartbeat} /></span>` : html`<span>No heartbeat</span>`}
        <span>${keeperContinuity(keeper)}</span>
        <span>Lifecycle ${row.lifecycle}</span>
        <span>Context ${formatContext(keeper.context_ratio)}</span>
        ${keeper.model ? html`<span>${keeper.model}</span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${keeper.skill_reason ? html`<div class="monitor-footnote">Skill route: ${keeper.skill_reason}</div>` : null}
    </button>
  `
}

export function Agents() {
  const agentRows = [...agents.value]
    .map(buildAgentRow)
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      const taskDiff = b.activeTaskCount - a.activeTaskCount
      if (taskDiff !== 0) return taskDiff
      return toEpoch(b.lastSignalAt) - toEpoch(a.lastSignalAt)
    })

  const keeperRows = [...keepers.value]
    .map(buildKeeperRow)
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      const ratioDiff = (b.keeper.context_ratio ?? 0) - (a.keeper.context_ratio ?? 0)
      if (ratioDiff !== 0) return ratioDiff
      return toEpoch(b.keeper.last_heartbeat) - toEpoch(a.keeper.last_heartbeat)
    })

  const aliveRows = agentRows.filter(r => r.state !== 'offline')
  const offlineRows = agentRows.filter(r => r.state === 'offline')

  const onlineAgents = aliveRows.length
  const workingAgents = agentRows.filter(row => row.state === 'working').length
  const freshSignals = agentRows.filter(row => row.lastSignalAt && (Date.now() - toEpoch(row.lastSignalAt)) <= 120_000).length
  const agentAlerts = agentRows.filter(row => row.tone !== 'ok')
  const keeperAlerts = keeperRows.filter(row => row.tone !== 'ok')

  const attentionItems: AttentionItem[] = [
    ...keeperAlerts.map(row => ({
      kind: 'keeper' as const,
      key: `keeper-${row.keeper.name}`,
      tone: row.tone,
      title: row.keeper.name,
      subtitle: `${row.note} · ${row.focus}`,
      timestamp: row.keeper.last_heartbeat ?? null,
      keeper: row.keeper,
    })),
    ...agentAlerts.map(row => ({
      kind: 'agent' as const,
      key: `agent-${row.agent.name}`,
      tone: row.tone,
      title: row.agent.name,
      subtitle: `${row.note} · ${row.focus}`,
      timestamp: row.lastSignalAt,
      agent: row.agent,
    })),
  ]
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.timestamp) - toEpoch(a.timestamp)
    })
    .slice(0, 8)

  return html`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${MonitorStat} label="Agents online" value=${onlineAgents} color="#4ade80" caption="active + idle" />
        <${MonitorStat} label="Working now" value=${workingAgents} color="#fbbf24" caption="task or claimed load" />
        <${MonitorStat} label="Fresh signals" value=${freshSignals} color="#22d3ee" caption="within last 2 minutes" />
        <${MonitorStat} label="Agent alerts" value=${agentAlerts.length} color=${agentAlerts.length > 0 ? '#fb7185' : '#4ade80'} caption="quiet or offline" />
        <${MonitorStat} label="Keeper alerts" value=${keeperAlerts.length} color=${keeperAlerts.length > 0 ? '#fb7185' : '#4ade80'} caption="stale or high pressure" />
      </div>

      <${Card} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${attentionItems.length === 0
            ? html`<div class="empty-state">No agent or keeper alerts right now</div>`
            : attentionItems.map(item => html`<${AttentionRow} key=${item.key} item=${item} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${Card} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${keeperRows.length === 0
              ? html`<div class="empty-state">No keepers active</div>`
              : keeperRows.map(row => html`<${KeeperWatchRow} key=${row.keeper.name} row=${row} />`)}
          </div>
        <//>

        <${Card} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${agentRows.length === 0
              ? html`<div class="empty-state">No agents registered</div>`
              : html`
                ${aliveRows.length > 0 ? html`
                  <div class="agent-group-header">
                    Active <span class="group-count">${aliveRows.length}</span>
                  </div>
                  ${aliveRows.map(row => html`<${AgentWatchRow} key=${row.agent.name} row=${row} />`)}
                ` : null}
                ${offlineRows.length > 0 ? html`
                  <div class="agent-group-header">
                    Offline <span class="group-count">${offlineRows.length}</span>
                  </div>
                  ${offlineRows.map(row => html`<${AgentWatchRow} key=${row.agent.name} row=${row} />`)}
                ` : null}
              `}
          </div>
        <//>
      </div>
    </div>
  `
}
