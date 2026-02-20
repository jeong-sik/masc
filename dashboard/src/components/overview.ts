// Overview tab — Room status, agent list, task summary

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
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
import { openKeeperDetail } from './keeper-detail'

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
    <div class="agent" onClick=${() => openKeeperDetail(agent as unknown as Keeper)} style="cursor: pointer">
      <span class="agent-emoji">${agent.emoji ?? ''}</span>
      <span class="agent-status ${agent.status}"></span>
      <span class="agent-name">${agent.name}</span>
      <${StatusBadge} status=${agent.status} />
      ${agent.current_task
        ? html`<span class="agent-task">${agent.current_task}</span>`
        : null}
    </div>
  `
}

function KeeperRow({ keeper }: { keeper: Keeper }) {
  return html`
    <div class="live-agent keeper-card" onClick=${() => openKeeperDetail(keeper)} style="cursor: pointer">
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
              ${keeper.context_ratio != null
                ? html`<span class=${keeper.context_ratio > 0.7 ? 'warn-metric' : ''}>
                    Ctx ${Math.round(keeper.context_ratio * 100)}%
                  </span>`
                : null}
            </div>`
          : null}
      </div>
    </div>
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
  `
}

function formatUptime(seconds: number): string {
  if (!seconds) return 'N/A'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}
