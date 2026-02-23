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
  keeperLifecycles,
  staleKeepers,
} from '../store'
import type { Agent, Keeper } from '../types'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'

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
    <div class="agent-row" onClick=${() => openAgentDetail(agent.name)} style="cursor: pointer">
      <span class="agent-emoji">${agent.emoji ?? ''}</span>
      <span class="agent-name">${agent.name}</span>
      <${StatusBadge} status=${agent.status} />
      ${agent.current_task
        ? html`<span class="agent-task" style="margin-left: auto; font-size: 12px; color: var(--text-muted);">${agent.current_task}</span>`
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
  if (ratio > 0.8) return 'bad'
  if (ratio > 0.6) return 'warn'
  return 'ok'
}

function KeeperRow({ keeper }: { keeper: Keeper }) {
  const ratio = keeper.context_ratio
  const pct = ratio != null ? Math.round(ratio * 100) : null
  const lifecycle = keeperLifecycles.value.get(keeper.name)
  const isStale = staleKeepers.value.has(keeper.name)

  return html`
    <div class="live-agent keeper-card ${isStale ? 'stale' : ''}" onClick=${() => openKeeperDetail(keeper)}>
      <!-- Row 1: Identity -->
      <div style="display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 8px;">
        <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
          <span style="font-size: 18px;">${keeper.emoji ?? ''}</span>
          <span style="font-weight: 600; color: var(--text-strong); font-size: 15px;">${keeper.name}</span>
          <${StatusBadge} status=${keeper.status} />
          ${lifecycle ? html`<span class="pill">${lifecycle}</span>` : null}
          ${isStale ? html`<span class="pill" style="color: var(--bad); border-color: rgba(239, 68, 68, 0.3);">stale</span>` : null}
        </div>
        ${keeper.model ? html`<span class="pill" style="font-family: monospace;">${keeper.model}</span>` : null}
      </div>

      <!-- Row 2: Context bar (Full Width) -->
      ${ratio != null ? html`
        <div style="margin-bottom: 12px;">
          <div style="display: flex; justify-content: space-between; font-size: 11px; color: var(--text-muted); margin-bottom: 4px;">
            <span>Context Usage</span>
            <span class=${pct && pct > 80 ? 'warn-metric' : ''}>
              ${pct}% ${keeper.context_tokens != null ? `(${formatTokens(keeper.context_tokens)})` : ''}
            </span>
          </div>
          <div class="ctx-bar">
            <div class="ctx-fill ${ctxBarClass(ratio)}" style="width: ${pct}%"></div>
          </div>
        </div>
      ` : null}

      <!-- Row 3: Operational metrics (Grid) -->
      ${keeper.generation != null ? html`
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-bottom: 12px; font-size: 12px; color: var(--text-muted); background: var(--bg-0); padding: 8px; border-radius: 6px; border: 1px solid var(--card-border);">
          <div style="display: flex; flex-direction: column;">
            <span style="font-size: 10px; text-transform: uppercase;">Gen</span>
            <strong style="color: var(--text-strong);">${keeper.generation}</strong>
          </div>
          <div style="display: flex; flex-direction: column;">
            <span style="font-size: 10px; text-transform: uppercase;">Turns</span>
            <strong style="color: var(--text-strong);">${keeper.turn_count ?? 0}</strong>
          </div>
          <div style="display: flex; flex-direction: column;">
            <span style="font-size: 10px; text-transform: uppercase;">Handoffs</span>
            <strong style="color: ${(keeper.handoff_count_total ?? 0) > 0 ? 'var(--warn)' : 'var(--text-strong)'};">${keeper.handoff_count_total ?? 0}</strong>
          </div>
          <div style="display: flex; flex-direction: column;">
            <span style="font-size: 10px; text-transform: uppercase;">K2K</span>
            <strong style="color: var(--accent);">${keeper.k2k_count ?? 0}</strong>
          </div>
        </div>
      ` : null}

      <!-- Row 4: Heartbeat freshness & Meta -->
      <div style="display: flex; justify-content: space-between; align-items: center; font-size: 11px; color: var(--text-muted);">
        ${keeper.last_heartbeat ? html`
          <div style="display: flex; align-items: center; gap: 6px;">
            <span class="status-dot-inline ${keeper.status === 'active' ? 'active' : ''}"></span>
            <${TimeAgo} timestamp=${keeper.last_heartbeat} />
          </div>
        ` : html`<span>No heartbeat</span>`}
        
        ${keeper.skill_primary ? html`<span class="pill" style="color: #a78bfa; border-color: rgba(167, 139, 250, 0.3); background: rgba(167, 139, 250, 0.1);">${keeper.skill_primary}</span>` : null}
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
    <!-- High-level Full Width System Health -->
    <div class="stats-grid" style="grid-template-columns: repeat(6, 1fr);">
      <${StatCard} label="Total Agents" value=${agentList.length} />
      <${StatCard} label="Active Agents" value=${activeAgents.value.length} color="var(--ok)" />
      <${StatCard} label="Keepers" value=${keeperList.length} color="var(--accent)" />
      <${StatCard} label="Total Tasks" value=${tasks.value.length} />
      <${StatCard} label="In Progress" value=${byStatus.inProgress.length} color="var(--warn)" />
      <${StatCard} label="Completed" value=${byStatus.done.length} color="var(--ok)" />
    </div>

    <!-- System Status & Perpetual Runtime Full Width Banner -->
    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px;">
      ${status?.room ? html`
        <div class="section" style="margin-bottom: 0;">
          <h2>MASC Room Status</h2>
          <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 12px; font-size: 13px;">
            <div style="display: flex; flex-direction: column; gap: 4px;">
              <span style="color: var(--text-muted);">Room / Cluster</span>
              <strong style="color: var(--text-strong);">${status.room} / ${status.cluster || 'N/A'}</strong>
            </div>
            <div style="display: flex; flex-direction: column; gap: 4px;">
              <span style="color: var(--text-muted);">Uptime</span>
              <strong style="color: var(--text-strong);">${formatUptime(status.uptime_seconds ?? 0)}</strong>
            </div>
            <div style="display: flex; flex-direction: column; gap: 4px;">
              <span style="color: var(--text-muted);">State</span>
              ${status.paused ? html`<span class="pill" style="color: var(--bad); width: fit-content;">Paused</span>` : html`<span class="pill" style="color: var(--ok); width: fit-content;">Active</span>`}
            </div>
          </div>
        </div>
      ` : null}

      ${perpetualStatus.value ? html`
        <div class="section" style="margin-bottom: 0;">
          <h2>Perpetual Runtime</h2>
          <div style="display: flex; flex-direction: column; gap: 8px; font-size: 13px;">
            <div style="display: flex; justify-content: space-between; align-items: center;">
              <span style="color: var(--text-muted);">Engine Status</span>
              <span style="color: ${perpetualStatus.value.running ? 'var(--ok)' : 'var(--text-muted)'}; font-weight: 500;">
                ${perpetualStatus.value.running ? 'Running' : 'Stopped'}
              </span>
            </div>
            <div style="display: flex; flex-direction: column; gap: 4px; padding-top: 8px; border-top: 1px solid var(--card-border);">
              <span style="color: var(--text-muted);">Current Goal</span>
              <strong style="color: var(--text-strong); font-size: 14px;">${perpetualStatus.value.goal || 'No active goal'}</strong>
            </div>
          </div>
        </div>
      ` : null}
    </div>

    <!-- Main Content Area -->
    <div style="display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 24px;">
      <div class="section" style="margin-bottom: 0;">
        <h2>Keepers Health & Context</h2>
        <div class="live-agent-list" style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px;">
          ${keeperList.length === 0
            ? html`<div class="empty-state" style="grid-column: 1 / -1;">No keepers active</div>`
            : keeperList.map(k => html`<${KeeperRow} key=${k.name} keeper=${k} />`)}
        </div>
      </div>

      <div class="section" style="margin-bottom: 0;">
        <h2>Connected Agents</h2>
        <div class="agent-list">
          ${agentList.length === 0
            ? html`<div class="empty-state">No agents connected</div>`
            : agentList.map(a => html`<${AgentRow} key=${a.name} agent=${a} />`)}
        </div>
      </div>
    </div>
  `
}

function formatUptime(seconds: number): string {
  if (!seconds) return 'N/A'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}
