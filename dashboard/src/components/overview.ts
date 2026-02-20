// Overview tab — Room status, agent list, task summary

import { html } from 'htm/preact'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
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

function formatTokens(n: number | undefined | null): string {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + '…' : s
}

function ctxBarClass(ratio: number): string {
  if (ratio > 0.8) return 'ctx-bar-bad'
  if (ratio > 0.6) return 'ctx-bar-warn'
  return 'ctx-bar-ok'
}

function KeeperRow({ keeper }: { keeper: Keeper }) {
  const ratio = keeper.context_ratio
  const pct = ratio != null ? Math.round(ratio * 100) : null

  return html`
    <div class="live-agent keeper-card" onClick=${() => openKeeperDetail(keeper)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${keeper.emoji ?? ''} ${keeper.name}</span>
          <${StatusBadge} status=${keeper.status} />
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
            ${(keeper.k2k_count ?? 0) > 0
              ? html`<span>K2K:${keeper.k2k_count}</span>` : null}
            ${(keeper.conversation_tail_count ?? 0) > 0
              ? html`<span>💬${keeper.conversation_tail_count}</span>` : null}
          </div>
        ` : null}

        <!-- Row 4: Heartbeat freshness -->
        ${keeper.last_heartbeat ? html`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${keeper.status === 'active' ? 'pulse' : ''}"></span>
            <${TimeAgo} timestamp=${keeper.last_heartbeat} />
          </div>
        ` : null}

        <!-- Row 5: Trait chips -->
        ${keeper.traits && keeper.traits.length > 0 ? html`
          <div class="keeper-trait-row">
            ${keeper.traits.slice(0, 3).map(t => html`<span class="keeper-trait-chip">${t}</span>`)}
            ${keeper.traits.length > 3 ? html`<span class="keeper-trait-more">+${keeper.traits.length - 3}</span>` : null}
          </div>
        ` : null}

        <!-- Row 6: Memory note preview -->
        ${keeper.memory_recent_note ? html`
          <div class="keeper-note-preview">${truncate(keeper.memory_recent_note, 80)}</div>
        ` : null}
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
