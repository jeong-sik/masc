// Overview tab — triage-first room health, intervention queue, and dispatch surface

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { type MonitorTone, toEpoch, toneRank, normalizeKey, limitText, taskPriorityValue, taskPriorityLabel } from './common/monitor'
import { Execution } from './execution'
import {
  agents,
  tasks,
  keepers,
  serverStatus,
  perpetualStatus,
  activeAgents,
  tasksByStatus,
  keeperLifecycles,
  staleKeepers,
  agentMotionMap,
} from '../store'
import type { Agent, Keeper, LodgeRuntimeStatus, Task } from '../types'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import { navigate } from '../router'
import { connected, eventCount } from '../sse'
import { openActivityPanel } from '../activity-panel'

const QUIET_AGENT_MS = 10 * 60 * 1000
const STALE_AGENT_MS = 20 * 60 * 1000
const HOT_KEEPER_RATIO = 0.8

type OverviewSubView = 'triage' | 'dispatch'
const overviewSubView = signal<OverviewSubView>('triage')

interface OverviewAlertItem {
  key: string
  tone: MonitorTone
  title: string
  detail: string
  timestamp: string | null
  action: () => void
}

interface AgentPulse {
  agent: Agent
  lastSignalAt: string | null
  activeTaskCount: number
  tone: MonitorTone
  note: string
  focus: string
  dispatchable: boolean
  drift: boolean
}

interface KeeperPulse {
  keeper: Keeper
  tone: MonitorTone
  note: string
  focus: string
  timestamp: string | null
}

interface TaskPulse {
  task: Task
  owner: Agent | null
  lastSignalAt: string | null
  tone: MonitorTone
  note: string
  focus: string
  ownerGap: boolean
}

function monitorTone(level?: string): MonitorTone {
  const normalized = (level ?? '').toLowerCase()
  if (normalized === 'bad') return 'bad'
  if (normalized === 'warn') return 'warn'
  return 'ok'
}

function toneColor(tone: MonitorTone): string {
  switch (tone) {
    case 'bad': return '#fb7185'
    case 'warn': return '#fbbf24'
    default: return '#4ade80'
  }
}

function formatHour(hour?: number | null): string {
  if (typeof hour !== 'number' || !Number.isFinite(hour)) return '??:00'
  return `${String(Math.max(0, hour)).padStart(2, '0')}:00`
}

function formatInterval(seconds?: number | null): string {
  if (seconds == null || !Number.isFinite(seconds)) return 'unknown'
  if (seconds < 60) return `${Math.round(seconds)}s`
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  const rem = minutes % 60
  return rem > 0 ? `${hours}h ${rem}m` : `${hours}h`
}

function formatUptime(seconds: number): string {
  if (!seconds) return 'N/A'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

function formatDuration(seconds?: number | null): string {
  if (seconds == null || !Number.isFinite(seconds)) return 'No data'
  if (seconds < 60) return `${Math.max(0, Math.round(seconds))}s`
  const m = Math.floor(seconds / 60)
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  const remM = m % 60
  return remM > 0 ? `${h}h ${remM}m` : `${h}h`
}

function formatTokens(n: number | undefined | null): string {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

function quietReasonLabel(reason?: string | null): string {
  switch (reason) {
    case 'quiet_hours':
      return 'quiet hours'
    case 'min_gap':
      return 'cooldown gate'
    case 'no_recent_activity':
      return 'waiting for activity'
    case 'disabled':
      return 'runtime disabled'
    case 'startup':
      return 'warming up'
    case 'llm_error':
      return 'llm error'
    case 'graphql_error':
      return 'graphql error'
    case 'never_started':
      return 'never started'
    default:
      return 'unknown'
  }
}

function nextActionLabel(path?: string | null): string {
  switch (path) {
    case 'manual_lodge_poke':
      return 'Poke Lodge'
    case 'probe':
      return 'Probe'
    case 'recover':
      return 'Recover'
    default:
      return 'Message'
  }
}

function lodgeSummary(lodge: LodgeRuntimeStatus | null | undefined): string {
  if (!lodge) return 'Lodge runtime status is unavailable in the current dashboard payload.'
  if (!lodge.enabled) return 'Lodge automation is disabled.'
  if (lodge.quiet_active) {
    return `Quiet hours ${formatHour(lodge.quiet_start)}-${formatHour(lodge.quiet_end)} KST are active.`
  }
  if (lodge.last_tick_ago_s == null) {
    return `Lodge is enabled and scheduled every ${formatInterval(lodge.interval_s)}, but no tick has run yet.`
  }
  return `Lodge ticks every ${formatInterval(lodge.interval_s)} with planner ${lodge.use_planner ? 'on' : 'off'} and delegated LLM ${lodge.delegate_llm ? 'on' : 'off'}.`
}

function monitorLevelLabel(level?: string): string {
  const v = (level ?? '').toLowerCase()
  if (v === 'ok') return 'Healthy'
  if (v === 'warn') return 'Warning'
  if (v === 'bad') return 'Degraded'
  return 'Unknown'
}

function StatCard({
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
      <div class="stat-value" style=${color ? `color: ${color}` : ''}>${value}</div>
      ${caption ? html`<div class="monitor-stat-caption">${caption}</div>` : null}
    </div>
  `
}

function AlertRow({ item }: { item: OverviewAlertItem }) {
  return html`
    <button class="monitor-alert ${item.tone}" onClick=${item.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${item.title}</div>
        <div class="monitor-alert-subtitle">${item.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${item.tone}">${item.tone === 'bad' ? 'Act now' : item.tone === 'warn' ? 'Watch' : 'Stable'}</span>
        ${item.timestamp ? html`<span><${TimeAgo} timestamp=${item.timestamp} /></span>` : null}
      </div>
    </button>
  `
}

function WatchRow({
  tone,
  title,
  subtitle,
  meta,
  focus,
  onClick,
}: {
  tone: MonitorTone
  title: string
  subtitle: string
  meta: string[]
  focus: string
  onClick: () => void
}) {
  return html`
    <button class="monitor-row ${tone}" onClick=${onClick}>
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${title}</span>
            <span class="monitor-sub">${subtitle}</span>
          </div>
        </div>
        <span class="monitor-pill ${tone}">${tone === 'bad' ? 'Alert' : tone === 'warn' ? 'Watch' : 'Ready'}</span>
      </div>
      <div class="monitor-meta">
        ${meta.map(value => html`<span>${value}</span>`)}
      </div>
      <div class="monitor-focus">${focus}</div>
    </button>
  `
}

export function Overview() {
  const status = serverStatus.value
  const agentList = agents.value
  const taskList = tasks.value
  const keeperList = keepers.value
  const byStatus = tasksByStatus.value
  const boardMonitor = status?.monitoring?.board
  const councilMonitor = status?.monitoring?.council
  const isLive = connected.value
  const agentsByName = new Map<string, Agent>(
    agentList.map(agent => [normalizeKey(agent.name), agent] as [string, Agent]),
  )

  const motionMap = agentMotionMap.value
  const agentPulses: AgentPulse[] = agentList
    .map(agent => {
      const motion = motionMap.get(normalizeKey(agent.name)) ?? { activeAssignedCount: 0, lastActivityAt: null, lastActivityText: null }
      const lastSignalAt = motion.lastActivityAt ?? agent.last_seen ?? null
      const signalAgeMs = lastSignalAt ? Math.max(0, Date.now() - toEpoch(lastSignalAt)) : Number.POSITIVE_INFINITY
      const activeTaskCount = motion.activeAssignedCount
      const hasCurrentTask = Boolean(agent.current_task?.trim())
      const hasLoad = hasCurrentTask || activeTaskCount > 0

      let tone: MonitorTone = 'ok'
      let note = 'Fresh and ready'
      let dispatchable = false
      let drift = false

      if (agent.status === 'offline' || agent.status === 'inactive') {
        tone = hasLoad ? 'bad' : 'warn'
        note = hasLoad ? 'Load without an available owner' : 'Offline'
      } else if (hasLoad && signalAgeMs > STALE_AGENT_MS) {
        tone = 'bad'
        note = 'Execution is stale'
      } else if (activeTaskCount > 0 && !hasCurrentTask) {
        tone = 'warn'
        note = 'Claimed work has no current_task'
        drift = true
      } else if (hasCurrentTask && activeTaskCount === 0) {
        tone = 'warn'
        note = 'current_task has no claimed work'
        drift = true
      } else if (!hasLoad && signalAgeMs <= QUIET_AGENT_MS) {
        tone = 'ok'
        note = 'Dispatchable now'
        dispatchable = true
      } else if (!hasLoad && signalAgeMs > STALE_AGENT_MS) {
        tone = 'warn'
        note = 'Idle but not freshly active'
      } else if (hasLoad && signalAgeMs > QUIET_AGENT_MS) {
        tone = 'warn'
        note = 'Execution is getting quiet'
      }

      return {
        agent,
        lastSignalAt,
        activeTaskCount,
        tone,
        note,
        focus:
          limitText(agent.current_task)
          ?? motion.lastActivityText
          ?? (dispatchable ? 'Ready for assignment.' : 'Waiting for a clearer signal.'),
        dispatchable,
        drift,
      }
    })
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.lastSignalAt) - toEpoch(a.lastSignalAt)
    })

  const keeperPulses: KeeperPulse[] = keeperList
    .map(keeper => {
      const lifecycle = keeperLifecycles.value.get(keeper.name) ?? 'idle'
      const isStale = staleKeepers.value.has(keeper.name)
      const ratio = keeper.context_ratio ?? 0
      const diagnostic = keeper.diagnostic ?? null

      let tone: MonitorTone = 'ok'
      let note = 'Healthy keeper'
      if (
        isStale
        || keeper.status === 'offline'
        || lifecycle === 'handoff-imminent'
        || diagnostic?.health_state === 'offline'
        || diagnostic?.health_state === 'degraded'
      ) {
        tone = 'bad'
        note =
          limitText(diagnostic?.summary, 56)
          ?? (isStale
            ? 'Heartbeat stale'
            : lifecycle === 'handoff-imminent'
              ? 'Handoff imminent'
              : diagnostic?.health_state === 'degraded'
                ? 'Keeper degraded'
                : 'Keeper offline')
      } else if (
        diagnostic?.health_state === 'stale'
        || ratio >= HOT_KEEPER_RATIO
        || lifecycle === 'preparing'
        || lifecycle === 'compacting'
      ) {
        tone = 'warn'
        note =
          limitText(diagnostic?.summary, 56)
          ?? (ratio >= HOT_KEEPER_RATIO ? 'High context pressure' : `Lifecycle ${lifecycle}`)
      }

      return {
        keeper,
        tone,
        note,
        focus:
          limitText(diagnostic?.summary, 120)
          ?? limitText(keeper.agent?.current_task)
          ?? keeper.skill_primary
          ?? keeper.last_proactive_reason
          ?? keeper.memory_recent_note
          ?? 'No active focus',
        timestamp: keeper.last_heartbeat ?? null,
      }
    })
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.timestamp) - toEpoch(a.timestamp)
    })

  const taskPulses: TaskPulse[] = taskList
    .filter(task => task.status === 'todo' || task.status === 'claimed' || task.status === 'in_progress')
    .map(task => {
      const owner = task.assignee ? (agentsByName.get(normalizeKey(task.assignee)) ?? null) : null
      const ownerMotion = owner
        ? (motionMap.get(normalizeKey(owner.name)) ?? null)
        : null
      const lastSignalAt = ownerMotion?.lastActivityAt ?? owner?.last_seen ?? null
      const signalAgeMs = lastSignalAt ? Math.max(0, Date.now() - toEpoch(lastSignalAt)) : Number.POSITIVE_INFINITY
      const active = task.status === 'claimed' || task.status === 'in_progress'

      let tone: MonitorTone = 'ok'
      let note = 'Covered'
      let ownerGap = false

      if (!task.assignee) {
        tone = taskPriorityValue(task.priority) <= 2 ? 'bad' : 'warn'
        note = active ? 'Active work has no owner' : 'Ready work has no owner'
        ownerGap = true
      } else if (!owner || owner.status === 'offline' || owner.status === 'inactive') {
        tone = 'bad'
        note = 'Assigned owner is unavailable'
        ownerGap = true
      } else if (active && signalAgeMs > STALE_AGENT_MS) {
        tone = 'bad'
        note = 'Execution has lost a fresh signal'
      } else if (active && signalAgeMs > QUIET_AGENT_MS) {
        tone = 'warn'
        note = 'Execution is drifting quiet'
      } else if (task.status === 'todo' && taskPriorityValue(task.priority) <= 2 && !owner.current_task?.trim() && (ownerMotion?.activeAssignedCount ?? 0) === 0) {
        tone = 'ok'
        note = 'Ready for dispatch'
      } else if (active && !owner.current_task?.trim()) {
        tone = 'warn'
        note = 'Owner focus is not explicit'
      }

      return {
        task,
        owner,
        lastSignalAt,
        tone,
        note,
        focus:
          limitText(owner?.current_task)
          ?? ownerMotion?.lastActivityText
          ?? limitText(task.description)
          ?? 'Needs operator attention.',
        ownerGap,
      }
    })
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      const priorityDiff = taskPriorityValue(a.task.priority) - taskPriorityValue(b.task.priority)
      if (priorityDiff !== 0) return priorityDiff
      return toEpoch(b.lastSignalAt ?? b.task.updated_at ?? b.task.created_at) - toEpoch(a.lastSignalAt ?? a.task.updated_at ?? a.task.created_at)
    })

  const urgentReady = taskPulses.filter(row => row.task.status === 'todo' && taskPriorityValue(row.task.priority) <= 2)
  const ownerGapCount = taskPulses.filter(row => row.ownerGap).length
  const dispatchableAgents = agentPulses.filter(row => row.dispatchable)
  const agentDrift = agentPulses.filter(row => row.drift || row.tone !== 'ok')
  const keeperAlerts = keeperPulses.filter(row => row.tone !== 'ok')

  const roomTone: MonitorTone =
    status?.paused
      ? 'bad'
      : status?.data_quality?.board_contract_ok === false || status?.data_quality?.council_feed_ok === false
        ? 'warn'
        : isLive
          ? 'ok'
          : 'warn'

  const healthAlerts: OverviewAlertItem[] = []
  if (status?.paused) {
    healthAlerts.push({
      key: 'paused',
      tone: 'bad',
      title: 'Room is paused',
      detail: status.tempo ? `Tempo is ${status.tempo}. Resume from Ops when ready.` : 'Resume from Ops when ready.',
      timestamp: status.data_quality?.last_sync_at ?? null,
      action: () => navigate('ops'),
    })
  }
  if (!isLive) {
    healthAlerts.push({
      key: 'live-connection',
      tone: 'warn',
      title: 'Live feed is reconnecting',
      detail: 'Dashboard telemetry is stale until the SSE stream recovers.',
      timestamp: null,
      action: openActivityPanel,
    })
  }
  if (monitorTone(boardMonitor?.alert_level) !== 'ok') {
    healthAlerts.push({
      key: 'board-monitor',
      tone: monitorTone(boardMonitor?.alert_level),
      title: 'Board feed needs attention',
      detail: `Freshness ${formatDuration(boardMonitor?.last_activity_age_s)} · ${boardMonitor?.unanswered_posts ?? 0} unanswered posts.`,
      timestamp: null,
      action: () => navigate('board'),
    })
  }
  if (monitorTone(councilMonitor?.alert_level) !== 'ok') {
    healthAlerts.push({
      key: 'council-monitor',
      tone: monitorTone(councilMonitor?.alert_level),
      title: 'Council quorum risk is elevated',
      detail: `${councilMonitor?.sessions_without_quorum ?? 0} sessions without quorum · freshness ${formatDuration(councilMonitor?.last_activity_age_s)}.`,
      timestamp: null,
      action: () => navigate('board'),
    })
  }
  if (status?.data_quality?.board_contract_ok === false || status?.data_quality?.council_feed_ok === false) {
    healthAlerts.push({
      key: 'data-quality',
      tone: 'warn',
      title: 'Dashboard data quality is degraded',
      detail: `${status.data_quality?.board_contract_ok === false ? 'Board contract' : 'Board contract ok'} · ${status.data_quality?.council_feed_ok === false ? 'Council feed degraded' : 'Council feed ok'}.`,
      timestamp: status.data_quality?.last_sync_at ?? null,
      action: () => navigate('ops'),
    })
  }

  const interventionQueue: OverviewAlertItem[] = [
    ...healthAlerts,
    ...taskPulses
      .filter(row => row.tone !== 'ok')
      .slice(0, 3)
      .map(row => ({
        key: `task-${row.task.id}`,
        tone: row.tone,
        title: row.task.title,
        detail: `${row.note} · ${row.focus}`,
        timestamp: row.lastSignalAt ?? row.task.updated_at ?? row.task.created_at ?? null,
        action: () => navigate('overview'),
      })),
    ...keeperAlerts.slice(0, 2).map(row => ({
      key: `keeper-${row.keeper.name}`,
      tone: row.tone,
      title: row.keeper.name,
      detail: `${row.note} · ${row.focus}`,
      timestamp: row.timestamp,
      action: () => openKeeperDetail(row.keeper),
    })),
    ...agentDrift.slice(0, 2).map(row => ({
      key: `agent-${row.agent.name}`,
      tone: row.tone,
      title: row.agent.name,
      detail: `${row.note} · ${row.focus}`,
      timestamp: row.lastSignalAt,
      action: () => openAgentDetail(row.agent.name),
    })),
  ]
    .sort((a, b) => {
      const toneDiff = toneRank(b.tone) - toneRank(a.tone)
      if (toneDiff !== 0) return toneDiff
      return toEpoch(b.timestamp) - toEpoch(a.timestamp)
    })
    .slice(0, 8)

  const subView = overviewSubView.value

  return html`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${subView === 'triage' ? 'active' : ''}"
        onClick=${() => { overviewSubView.value = 'triage' }}
      >Triage</button>
      <button
        class="sub-tab-btn ${subView === 'dispatch' ? 'active' : ''}"
        onClick=${() => { overviewSubView.value = 'dispatch' }}
      >Dispatch</button>
    </div>

    ${subView === 'dispatch'
      ? html`<${Execution} />`
      : html`<div class="stats-grid">
      <${StatCard}
        label="Room State"
        value=${status?.paused ? 'Paused' : 'Running'}
        color=${toneColor(roomTone)}
        caption=${status?.room ?? status?.project ?? 'default room'}
      />
      <${StatCard}
        label="Urgent Queue"
        value=${urgentReady.length}
        color=${urgentReady.length > 0 ? '#fb7185' : '#4ade80'}
        caption="todo tasks at P1/P2"
      />
      <${StatCard}
        label="Active Work"
        value=${byStatus.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${StatCard}
        label="Dispatchable"
        value=${dispatchableAgents.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${StatCard}
        label="Keeper Pressure"
        value=${keeperAlerts.length}
        color=${keeperAlerts.length > 0 ? '#fbbf24' : '#4ade80'}
        caption="stale or high-context keepers"
      />
      <${StatCard}
        label="Owner Gaps"
        value=${ownerGapCount}
        color=${ownerGapCount > 0 ? '#fb7185' : '#4ade80'}
        caption="tasks missing a live owner"
      />
    </div>

    <${Card} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${isLive ? '#4ade80' : '#fbbf24'}`}>${isLive ? 'Online' : 'Retrying'}</div>
          <div class="monitor-stat-caption">${eventCount.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${toneColor(monitorTone(boardMonitor?.alert_level))}`}>${monitorLevelLabel(boardMonitor?.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${formatDuration(boardMonitor?.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${toneColor(monitorTone(councilMonitor?.alert_level))}`}>${monitorLevelLabel(councilMonitor?.alert_level)}</div>
          <div class="monitor-stat-caption">${councilMonitor?.sessions_without_quorum ?? 0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${toneColor(roomTone)}`}>${status?.paused ? 'Paused' : 'Stable'}</div>
          <div class="monitor-stat-caption">Uptime ${formatUptime(status?.uptime_seconds ?? 0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${status?.data_quality?.last_sync_at
            ? html`Last sync <${TimeAgo} timestamp=${status.data_quality.last_sync_at} />`
            : html`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${status?.tempo ? `Tempo ${status.tempo}` : 'Tempo unavailable'}${status?.tempo_interval_s != null ? ` · ${status.tempo_interval_s}s interval` : ''}
        </div>
        <div class="overview-inline-note">${lodgeSummary(status?.lodge)}</div>
        ${status?.lodge?.last_skip_reason
          ? html`<div class="overview-inline-note">Last Lodge skip: ${status.lodge.last_skip_reason}</div>`
          : null}
      </div>
    <//>

    <div class="overview-workbench">
      <div class="overview-column">
        <${Card} title="Intervention Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">What needs intervention right now</h2>
            <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
          </div>
          <div class="monitor-alert-list">
            ${interventionQueue.length === 0
              ? html`<div class="empty-state">No immediate intervention required</div>`
              : interventionQueue.map(item => html`<${AlertRow} key=${item.key} item=${item} />`)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${Card} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
          </div>
          <div class="monitor-list">
            ${dispatchableAgents.length === 0
              ? html`<div class="empty-state">No fully dispatchable agents right now</div>`
              : dispatchableAgents.slice(0, 5).map(row => html`
                  <${WatchRow}
                    key=${row.agent.name}
                    tone=${row.tone}
                    title=${row.agent.name}
                    subtitle=${row.note}
                    meta=${[
                      row.lastSignalAt ? `Signal ${new Date(row.lastSignalAt).toLocaleTimeString()}` : 'No recent signal',
                      row.agent.model ?? 'model n/a',
                      row.agent.koreanName ?? 'room agent',
                    ]}
                    focus=${row.focus}
                    onClick=${() => openAgentDetail(row.agent.name)}
                  />
                `)}
          </div>
        <//>

        <${Card} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Agents with drift or aging load</h2>
            <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
          </div>
          <div class="monitor-list">
            ${agentDrift.length === 0
              ? html`<div class="empty-state">No agent drift or stale load right now</div>`
              : agentDrift.slice(0, 4).map(row => html`
                  <button class="monitor-row ${row.tone}" onClick=${() => openAgentDetail(row.agent.name)}>
                    <div class="monitor-row-header">
                      <div class="monitor-row-title">
                        <div class="monitor-name-line">
                          <span class="monitor-title">${row.agent.name}</span>
                          ${row.agent.koreanName ? html`<span class="monitor-sub">${row.agent.koreanName}</span>` : null}
                        </div>
                        <div class="monitor-note">${row.note}</div>
                      </div>
                      <${StatusBadge} status=${row.agent.status} />
                      <span class="monitor-pill ${row.tone}">${row.dispatchable ? 'Ready' : row.drift ? 'Drift' : 'Watch'}</span>
                    </div>
                    <div class="monitor-meta">
                      ${row.lastSignalAt ? html`<span>Signal <${TimeAgo} timestamp=${row.lastSignalAt} /></span>` : html`<span>No recent signal</span>`}
                      <span>${row.activeTaskCount > 0 ? `${row.activeTaskCount} active tasks` : 'No active tasks'}</span>
                      ${row.agent.model ? html`<span>${row.agent.model}</span>` : null}
                    </div>
                    <div class="monitor-focus">${row.focus}</div>
                  </button>
                `)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${Card} title="Keeper Pressure" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keepers under pressure</h2>
            <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
          </div>
          <div class="monitor-list">
            ${keeperAlerts.length === 0
              ? html`<div class="empty-state">No keeper pressure signals right now</div>`
              : keeperAlerts.slice(0, 4).map(row => html`
                  <${WatchRow}
                    key=${row.keeper.name}
                    tone=${row.tone}
                    title=${row.keeper.name}
                    subtitle=${row.keeper.diagnostic?.health_state
                      ? `${row.note} · ${row.keeper.diagnostic.health_state}`
                      : row.note}
                    meta=${[
                      row.timestamp ? `Heartbeat ${new Date(row.timestamp).toLocaleTimeString()}` : 'No heartbeat',
                      `Context ${typeof row.keeper.context_ratio === 'number' ? Math.round(row.keeper.context_ratio * 100) : 0}%`,
                      row.keeper.model ? `Model ${row.keeper.model}` : 'model n/a',
                      row.keeper.diagnostic
                        ? `${quietReasonLabel(row.keeper.diagnostic.quiet_reason)} · next ${nextActionLabel(row.keeper.diagnostic.next_action_path)} · reply ${row.keeper.diagnostic.last_reply_status}`
                        : 'Diagnostic unavailable',
                    ]}
                    focus=${row.focus}
                    onClick=${() => openKeeperDetail(row.keeper)}
                  />
                `)}
          </div>
        <//>

        <${Card} title="Runtime Notes" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Secondary runtime context</h2>
            <p class="monitor-subheadline">This column stays compact so operators can scan triage first and drill later.</p>
          </div>
          <div class="overview-note-stack">
            <div class="overview-inline-note">
              Room ${status?.room ?? 'default'}${status?.cluster ? ` · Cluster ${status.cluster}` : ''}${status?.project ? ` · Project ${status.project}` : ''}
            </div>
            <div class="overview-inline-note">
              ${status?.version ? `Version ${status.version}` : 'Version unavailable'} · Active agents ${activeAgents.value.length} · Total tasks ${taskList.length}
            </div>
            <div class="overview-inline-note">
              ${perpetualStatus.value
                ? `Perpetual runtime ${perpetualStatus.value.running ? 'running' : 'stopped'}${perpetualStatus.value.goal ? ` · ${limitText(perpetualStatus.value.goal, 120)}` : ''}`
                : 'Perpetual runtime unavailable'}
            </div>
            <div class="overview-inline-note">
              Lodge ${status?.lodge?.enabled ? 'enabled' : 'disabled'} · Last tick ${status?.lodge?.last_tick_ago ?? 'never'} · Self heartbeats ${status?.lodge?.active_self_heartbeats?.length ?? 0}${status?.lodge?.last_skip_reason ? ` · Skip ${status.lodge.last_skip_reason}` : ''}
            </div>
            <div class="overview-inline-note">
              ${keeperList.length > 0
                ? `Hot keepers: ${keeperAlerts.length} · Highest context ${formatTokens(Math.max(...keeperList.map(keeper => keeper.context_tokens ?? 0)))}`
                : 'No keepers registered'}
            </div>
          </div>
        <//>
      </div>
    </div>

    <${Card} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${taskPulses.length === 0
            ? html`<div class="empty-state">No active or ready tasks</div>`
            : taskPulses.slice(0, 6).map(row => html`
                <${WatchRow}
                  key=${row.task.id}
                  tone=${row.tone}
                  title=${row.task.title}
                  subtitle=${`${taskPriorityLabel(row.task.priority)} · ${row.note}`}
                  meta=${[
                    row.task.assignee ? `Owner ${row.task.assignee}` : 'Unassigned',
                    row.lastSignalAt ? `Signal ${new Date(row.lastSignalAt).toLocaleTimeString()}` : 'No live signal',
                    row.task.updated_at ? `Touched ${new Date(row.task.updated_at).toLocaleTimeString()}` : 'No task timestamp',
                  ]}
                  focus=${row.focus}
                  onClick=${() => navigate('overview')}
                />
              `)}
        </div>
    <//>`}
  `
}
