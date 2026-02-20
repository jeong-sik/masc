// Overview tab — Room status, agent list, task summary

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import {
  agents,
  tasks,
  keepers,
  serverStatus,
  perpetualStatus,
  activeAgents,
  tasksByStatus,
} from '../store'
import type { Agent, Keeper } from '../types'

function StatCard({ label, value, color }: { label: string; value: string | number; color?: string }) {
  return html`
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value" style=${color ? `color: ${color}` : ''}>${value}</div>
    </div>
  `
}

function AgentRow({ agent }: { agent: Agent }) {
  return html`
    <button class="agent" onClick=${() => openAgentDetail(agent.name)}>
      <span class="agent-emoji">${agent.emoji ?? ''}</span>
      <span class="agent-status ${agent.status}"></span>
      <span class="agent-name">${agent.name}</span>
      <${StatusBadge} status=${agent.status} />
      ${agent.current_task
        ? html`<span class="agent-task">${agent.current_task}</span>`
        : null}
    </button>
  `
}

function KeeperRow({ keeper }: { keeper: Keeper }) {
  const contextRatio = keeper.context_ratio ?? keeper.context?.context_ratio
  return html`
    <button class="live-agent keeper-card" onClick=${() => openKeeperDetail(keeper)}>
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${keeper.emoji ?? ''} ${keeper.name}</span>
          <${StatusBadge} status=${keeper.status} />
          ${keeper.model ? html`<span class="pill">${keeper.model}</span>` : null}
        </div>
        <div class="live-agent-sub">${keeper.koreanName ?? ''}</div>
        ${keeper.generation != null
          ? html`<div class="live-agent-meta">
              <span>Gen ${keeper.generation}</span>
              <span>Turn ${keeper.turn_count ?? 0}</span>
              ${contextRatio != null
                ? html`<span class=${contextRatio > 0.7 ? 'warn-metric' : ''}>
                    Ctx ${Math.round(contextRatio * 100)}%
                  </span>`
                : null}
            </div>`
          : null}
      </div>
    </button>
  `
}

export function Overview() {
  const status = serverStatus.value
  const agentList = agents.value
  const keeperList = keepers.value
  const byStatus = tasksByStatus.value

  return html`
    <div class="stats-grid">
      <${StatCard} label="Agents" value=${agentList.length} />
      <${StatCard} label="Active" value=${activeAgents.value.length} color="#4ade80" />
      <${StatCard} label="Keepers" value=${keeperList.length} color="#22d3ee" />
      <${StatCard} label="Tasks" value=${tasks.value.length} />
      <${StatCard} label="In Progress" value=${byStatus.inProgress.length} color="#fbbf24" />
      <${StatCard} label="Done" value=${byStatus.done.length} color="#4ade80" />
    </div>

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
            <span>Uptime: ${formatUptime(status.uptime_seconds ?? 0)}</span>
          </div>
        <//>
      `
      : null}

    ${status
      ? html`
        <${Card} title="Runtime Health" class="section">
          <div class="live-agent-meta">
            ${status.cluster ? html`<span>Cluster: ${status.cluster}</span>` : null}
            ${status.project ? html`<span>Project: ${status.project}</span>` : null}
            ${status.tempo_interval_s != null ? html`<span>Tempo: ${status.tempo_interval_s}s</span>` : null}
            ${status.paused != null ? html`<span>Paused: ${status.paused ? 'Yes' : 'No'}</span>` : null}
          </div>
          ${status.tool_call_health
            ? html`
              <div class="live-agent-meta" style="margin-top:8px;">
                <span>Tool timeouts: ${status.tool_call_health.timeouts}</span>
                <span>
                  Tool p95:
                  ${status.tool_call_health.p95_duration_ms != null
                    ? `${Math.round(status.tool_call_health.p95_duration_ms)}ms`
                    : 'N/A'}
                </span>
                <span>Window: ${status.tool_call_health.window_hours}h</span>
              </div>
            `
            : null}
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
