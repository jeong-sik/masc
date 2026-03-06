// Agents tab — Agent card grid with status indicators

import { html } from 'htm/preact'
import { StatusBadge } from './common/status-badge'
import { MitosisRing } from "./common/mitosis-ring"
import { TimeAgo } from './common/time-ago'
import { buildAgentMotion } from './common/agent-motion'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import { agents, keepers, tasks, messages, boardPosts } from '../store'
import type { Agent, Keeper } from '../types'
import { journal } from '../sse'

function AgentCard({ agent }: { agent: Agent }) {
  const motion = buildAgentMotion(agent.name, tasks.value, messages.value, journal.value, {
    boardPosts: boardPosts.value,
    keepers: keepers.value,
  })

  return html`
    <button class="agent-card ${agent.status}" onClick=${() => openAgentDetail(agent.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${agent.emoji ?? ''}</span>
        <div class="agent-card-info">
          <span class="agent-name">${agent.name}</span>
          ${agent.koreanName
            ? html`<span class="agent-korean">${agent.koreanName}</span>`
            : null}
        </div>
        <${MitosisRing} ratio=${agent.context_ratio} />
        <${StatusBadge} status=${agent.status} />
      </div>
      ${agent.current_task
        ? html`<div class="agent-task">${agent.current_task}</div>`
        : motion.activeAssignedCount > 0
          ? html`<div class="agent-task">${motion.activeAssignedCount} claimed tasks</div>`
          : null}
      ${agent.model
        ? html`<div class="agent-model"><span class="pill">${agent.model}</span></div>`
        : null}
      ${motion.lastActivityText
        ? html`
            <div class="agent-activity-meta">
              ${motion.lastActivityAt ? html`<${TimeAgo} timestamp=${motion.lastActivityAt} /> · ` : null}
              ${motion.lastActivityText}
            </div>
          `
        : null}
    </button>
  `
}

function formatContext(keeper: Keeper): string {
  if (typeof keeper.context_ratio !== 'number' || Number.isNaN(keeper.context_ratio)) return '—'
  return `${Math.round(keeper.context_ratio * 100)}%`
}

function keeperFocus(keeper: Keeper): string {
  return keeper.agent?.current_task
    ?? keeper.skill_primary
    ?? keeper.last_proactive_reason
    ?? 'No active focus'
}

function keeperContinuity(keeper: Keeper): string {
  const parts = [
    `Turns ${keeper.turn_count ?? 0}`,
    `Handoffs ${keeper.handoff_count_total ?? 0}`,
    `Compactions ${keeper.compaction_count ?? 0}`,
  ]
  return parts.join(' · ')
}

function KeeperCard({ keeper }: { keeper: Keeper }) {
  return html`
    <div class="live-agent keeper-card" onClick=${() => openKeeperDetail(keeper)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${keeper.emoji ?? ''} ${keeper.name}</span>
          <${MitosisRing} ratio=${keeper.context_ratio} />
        <${StatusBadge} status=${keeper.status} />
          ${keeper.model ? html`<span class="pill">${keeper.model}</span>` : null}
        </div>
        ${keeper.koreanName
          ? html`<div class="live-agent-sub">${keeper.koreanName}</div>`
          : null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Context</span>
            <strong class="keeper-core-value">${formatContext(keeper)}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Generation</span>
            <strong class="keeper-core-value">${keeper.generation ?? '—'}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Heartbeat</span>
            <strong class="keeper-core-value">
              ${keeper.last_heartbeat ? html`<${TimeAgo} timestamp=${keeper.last_heartbeat} />` : '—'}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Model</span>
            <strong class="keeper-core-value">${keeper.model ?? '—'}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Focus</span>
            <strong class="keeper-core-value keeper-core-text">${keeperFocus(keeper)}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Continuity</span>
            <strong class="keeper-core-value">${keeperContinuity(keeper)}</strong>
          </div>
        </div>
      </div>
    </div>
  `
}

export function Agents() {
  const agentList = agents.value
  const keeperList = keepers.value

  return html`
    <div>
      ${keeperList.length > 0
        ? html`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${keeperList.map(k => html`<${KeeperCard} key=${k.name} keeper=${k} />`)}
            </div>
          </div>
        `
        : null}

      <div class="section">
        <h2>All Agents</h2>
        ${agentList.length === 0
          ? html`<div class="empty-state">No agents registered</div>`
          : html`
            <div class="agent-grid">
              ${agentList.map(a => html`<${AgentCard} key=${a.name} agent=${a} />`)}
            </div>
          `}
      </div>
    </div>
  `
}
