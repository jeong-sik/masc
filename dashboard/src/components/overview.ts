// Overview tab — Room status, agent list, task summary

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { buildAgentMotion } from './common/agent-motion'
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
  messages,
  boardPosts,
} from '../store'
import type { Agent, Keeper, LodgeRuntimeStatus } from '../types'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import { journal } from '../sse'

function StatCard({ label, value, color }: { label: string; value: string | number; color?: string }) {
  return html`
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value" style=${color ? `color: ${color}` : ''}>${value}</div>
    </div>
  `
}

function AgentRow({ agent }: { agent: Agent }) {
  const motion = buildAgentMotion(agent.name, tasks.value, messages.value, journal.value, {
    currentTask: agent.current_task,
    lastSeen: agent.last_seen,
    boardPosts: boardPosts.value,
    keepers: keepers.value,
  })

  return html`
    <div class="agent" onClick=${() => openAgentDetail(agent.name)} style="cursor: pointer">
      <span class="agent-emoji">${agent.emoji ?? ''}</span>
      <span class="agent-status ${agent.status}"></span>
      <span class="agent-name">${agent.name}</span>
      <${StatusBadge} status=${agent.status} />
      ${agent.current_task
        ? html`<span class="agent-task">${agent.current_task}</span>`
        : null}
      ${!agent.current_task && motion.activeAssignedCount > 0
        ? html`<span class="agent-task">${motion.activeAssignedCount} claimed</span>`
        : null}
      ${motion.lastActivityText
        ? html`
            <span class="agent-activity-meta">
              ${motion.lastActivityAt ? html`<${TimeAgo} timestamp=${motion.lastActivityAt} /> · ` : null}
              ${motion.lastActivityText}
            </span>
          `
        : null}
    </div>
  `
}

function formatTokens(n: number | undefined | null): string {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

function ctxBarClass(ratio: number): string {
  if (ratio > 0.8) return 'ctx-bar-bad'
  if (ratio > 0.6) return 'ctx-bar-warn'
  return 'ctx-bar-ok'
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

function KeeperRow({ keeper }: { keeper: Keeper }) {
  const ratio = keeper.context_ratio
  const pct = ratio != null ? Math.round(ratio * 100) : null
  const lifecycle = keeperLifecycles.value.get(keeper.name)
  const isStale = staleKeepers.value.has(keeper.name)
  const currentTask = keeper.agent?.current_task ?? 'No current task'
  const diagnostic = keeper.diagnostic ?? null

  return html`
    <div class="live-agent keeper-card ${isStale ? 'stale' : ''}" onClick=${() => openKeeperDetail(keeper)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${keeper.emoji ?? ''} ${keeper.name}</span>
          <${StatusBadge} status=${keeper.status} />
          ${lifecycle ? html`<span class="pill pill-lifecycle pill-lifecycle-${lifecycle}">${lifecycle}</span>` : null}
          ${isStale ? html`<span class="pill pill-stale">stale</span>` : null}
          ${keeper.model ? html`<span class="pill">${keeper.model}</span>` : null}
          ${keeper.skill_primary ? html`<span class="pill pill-skill">${keeper.skill_primary}</span>` : null}
        </div>
        <div class="live-agent-sub">${keeper.koreanName ?? ''}</div>

        <!-- Row 2: Context bar -->
        ${ratio != null ? html`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${ctxBarClass(ratio)}" style="width: ${pct}%"></div>
            </div>
            <span class="keeper-ctx-label ${ctxBarClass(ratio)}">
              ${pct}%
              ${keeper.context_tokens != null ? html` (${formatTokens(keeper.context_tokens)})` : null}
            </span>
          </div>
        ` : null}

        <!-- Row 3: Operational metrics -->
        ${keeper.generation != null ? html`
          <div class="keeper-metrics-row">
            <span>Gen ${keeper.generation}</span>
            <span>T${keeper.turn_count ?? 0}</span>
            ${(keeper.handoff_count_total ?? 0) > 0
              ? html`<span class="keeper-metric-hl">↻${keeper.handoff_count_total}</span>` : null}
            ${(keeper.compaction_count ?? 0) > 0
              ? html`<span class="keeper-metric-compact">◆${keeper.compaction_count}</span>` : null}
          </div>
        ` : null}

        <div class="keeper-focus-row">${currentTask}</div>
        ${diagnostic
          ? html`
              <div class="keeper-diagnostic-row">
                <span class="pill">${diagnostic.health_state}</span>
                <span class="pill">${quietReasonLabel(diagnostic.quiet_reason)}</span>
                <span class="pill">next ${nextActionLabel(diagnostic.next_action_path)}</span>
                <span class="keeper-diagnostic-copy">reply ${diagnostic.last_reply_status}</span>
              </div>
            `
          : null}

        <!-- Row 4: Heartbeat freshness -->
        ${keeper.last_heartbeat ? html`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${keeper.status === 'active' ? 'pulse' : ''}"></span>
            <${TimeAgo} timestamp=${keeper.last_heartbeat} />
          </div>
        ` : null}
      </div>
    </div>
  `
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

function lodgeSummary(lodge: LodgeRuntimeStatus | null | undefined): string {
  if (!lodge) return 'Lodge runtime status is unavailable in the current dashboard payload.'
  if (!lodge.enabled) return 'Lodge automation is disabled.'
  if (lodge.quiet_active) {
    return `Quiet hours ${formatHour(lodge.quiet_start)}-${formatHour(lodge.quiet_end)} KST are active. Scheduled ticks may appear asleep until the window ends.`
  }
  if (lodge.last_tick_ago_s == null) {
    return `Lodge is enabled and scheduled every ${formatInterval(lodge.interval_s)}, but no tick has run yet.`
  }
  return `Lodge ticks every ${formatInterval(lodge.interval_s)}. Planner is ${lodge.use_planner ? 'on' : 'off'} and delegated LLM is ${lodge.delegate_llm ? 'on' : 'off'}.`
}

function LodgeBanner({ lodge }: { lodge: LodgeRuntimeStatus | null | undefined }) {
  const actedNames = lodge?.last_tick_result?.acted_names?.join(', ') || 'none'
  const heartbeatCount = lodge?.active_self_heartbeats?.length ?? 0

  return html`
    <${Card} title="Lodge Runtime" class="section">
      <div class=${`lodge-banner ${lodge?.enabled ? 'is-enabled' : 'is-disabled'}`}>
        <div class="lodge-banner-meta">
          <span class=${`pill lodge-banner-pill ${lodge?.enabled ? 'is-on' : 'is-off'}`}>
            ${lodge?.enabled ? 'enabled' : 'disabled'}
          </span>
          <span class="pill">every ${formatInterval(lodge?.interval_s)}</span>
          <span class="pill">quiet ${formatHour(lodge?.quiet_start)}-${formatHour(lodge?.quiet_end)} KST</span>
          <span class="pill">${lodge?.quiet_active ? 'quiet active' : 'quiet inactive'}</span>
          <span class="pill">${lodge?.use_planner ? 'planner on' : 'planner off'}</span>
          <span class="pill">${lodge?.delegate_llm ? 'delegate llm on' : 'delegate llm off'}</span>
        </div>
        <div class="lodge-banner-copy">${lodgeSummary(lodge)}</div>
        <div class="lodge-banner-copy">
          Last tick: ${lodge?.last_tick_ago ?? 'never'} · Last acted: ${actedNames} · Self-heartbeats: ${heartbeatCount}
        </div>
        ${lodge?.last_skip_reason
          ? html`<div class="lodge-banner-copy">Last skip reason: ${lodge.last_skip_reason}</div>`
          : null}
      </div>
    <//>
  `
}

export function Overview() {
  const status = serverStatus.value
  const agentList = agents.value
  const keeperList = keepers.value
  const byStatus = tasksByStatus.value
  const boardMonitor = status?.monitoring?.board
  const councilMonitor = status?.monitoring?.council

  return html`
    <div class="stats-grid">
      <${StatCard} label="Agents" value=${agentList.length} />
      <${StatCard} label="Active" value=${activeAgents.value.length} color="#4ade80" />
      <${StatCard} label="Keepers" value=${keeperList.length} color="#22d3ee" />
      <${StatCard} label="Tasks" value=${tasks.value.length} />
      <${StatCard} label="In Progress" value=${byStatus.inProgress.length} color="#fbbf24" />
      <${StatCard} label="Done" value=${byStatus.done.length} color="#4ade80" />
    </div>

    <${LodgeBanner} lodge=${status?.lodge} />

    ${boardMonitor || councilMonitor
      ? html`
        <${Card} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${monitorLevelColor(boardMonitor?.alert_level)}`}>
                ${monitorLevelLabel(boardMonitor?.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${formatDuration(boardMonitor?.last_activity_age_s)}</span>
                <span>SLO: ≤ ${formatDuration(boardMonitor?.slo_target_age_s)}</span>
                <span>SLO Breach: ${boardMonitor?.slo_breached ? 'Yes' : 'No'}</span>
                <span>Posts (24h): ${boardMonitor?.new_posts_24h ?? 0}</span>
                <span>Unanswered: ${boardMonitor?.unanswered_posts ?? 0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${monitorLevelColor(councilMonitor?.alert_level)}`}>
                ${monitorLevelLabel(councilMonitor?.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${formatDuration(councilMonitor?.last_activity_age_s)}</span>
                <span>Open Debates: ${councilMonitor?.debates_open ?? 0}</span>
                <span>Pending Debates: ${councilMonitor?.debates_pending ?? 0}</span>
                <span>Quorum Risk: ${councilMonitor?.sessions_without_quorum ?? 0}</span>
                <span>SLO: ≤ ${formatDuration(councilMonitor?.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${councilMonitor?.slo_breached ? 'Yes' : 'No'}</span>
              </div>
            </div>
          </div>
        <//>
      `
      : null}

    <div class="grid-2col">
      <${Card} title="Agents" class="section">
        <div class="agent-list">
          ${agentList.length === 0
            ? html`<div class="empty-state">No agents connected</div>`
            : agentList.map(a => html`<${AgentRow} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${Card} title="Keepers" class="section">
        <div class="live-agent-list">
          ${keeperList.length === 0
            ? html`<div class="empty-state">No keepers active</div>`
            : keeperList.map(k => html`<${KeeperRow} key=${k.name} keeper=${k} />`)}
        </div>
      <//>
    </div>

    ${perpetualStatus.value
      ? html`
        <${Card} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${perpetualStatus.value.running ? 'Running' : 'Stopped'}</span>
            ${perpetualStatus.value.goal
              ? html`<span>Goal: ${perpetualStatus.value.goal}</span>`
              : null}
          </div>
        <//>
      `
      : null}

    ${status?.room
      ? html`
        <${Card} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${status.room}</span>
            ${status.cluster ? html`<span>Cluster: ${status.cluster}</span>` : null}
            ${status.project ? html`<span>Project: ${status.project}</span>` : null}
            ${status.version ? html`<span>Version: ${status.version}</span>` : null}
            <span>Uptime: ${formatUptime(status.uptime_seconds ?? 0)}</span>
            ${status.paused ? html`<span class="pill pill-stale">Paused</span>` : null}
            ${status.tempo ? html`<span>Tempo: ${status.tempo}</span>` : null}
            ${status.tempo_interval_s != null ? html`<span>Interval: ${status.tempo_interval_s}s</span>` : null}
            ${status.data_quality?.board_contract_ok === false ? html`<span class="pill pill-stale">Board Contract: Degraded</span>` : null}
            ${status.data_quality?.council_feed_ok === false ? html`<span class="pill pill-stale">Council Feed: Degraded</span>` : null}
            ${status.data_quality?.last_sync_at ? html`<span>Data Sync: <${TimeAgo} timestamp=${status.data_quality.last_sync_at} /></span>` : null}
          </div>
        <//>
      `
      : null}
  `
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

function monitorLevelLabel(level?: string): string {
  const v = (level ?? '').toLowerCase()
  if (v === 'ok') return 'Healthy'
  if (v === 'warn') return 'Warning'
  if (v === 'bad') return 'Degraded'
  return 'Unknown'
}

function monitorLevelColor(level?: string): string {
  const v = (level ?? '').toLowerCase()
  if (v === 'ok') return '#4ade80'
  if (v === 'warn') return '#fbbf24'
  if (v === 'bad') return '#fb7185'
  return '#94a3b8'
}
