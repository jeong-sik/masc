// Agents tab — Agent card grid with status indicators

import { html } from 'htm/preact'
import { StatusBadge } from './common/status-badge'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import { agents, keepers } from '../store'
import type { Agent, Keeper } from '../types'

function AgentCard({ agent }: { agent: Agent }) {
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
        <${StatusBadge} status=${agent.status} />
      </div>
      ${agent.current_task
        ? html`<div class="agent-task">${agent.current_task}</div>`
        : null}
      ${agent.model
        ? html`<div class="agent-model"><span class="pill">${agent.model}</span></div>`
        : null}
    </button>
  `
}

function KeeperCard({ keeper }: { keeper: Keeper }) {
  const ctxPct = keeper.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null
  const ctxClass = ctxPct != null ? (ctxPct > 80 ? 'bad' : ctxPct > 60 ? 'warn' : '') : ''

  return html`
    <div class="live-agent keeper-card" onClick=${() => openKeeperDetail(keeper)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${keeper.emoji ?? ''} ${keeper.name}</span>
          <${StatusBadge} status=${keeper.status} />
          ${keeper.model ? html`<span class="pill">${keeper.model}</span>` : null}
        </div>
        ${keeper.koreanName
          ? html`<div class="live-agent-sub">${keeper.koreanName}</div>`
          : null}
        <div class="live-agent-meta">
          ${keeper.generation != null ? html`<span>Gen ${keeper.generation}</span>` : null}
          ${keeper.turn_count != null ? html`<span>Turn ${keeper.turn_count}</span>` : null}
          ${ctxPct != null
            ? html`<span class=${ctxClass ? `${ctxClass}-metric` : ''}>Ctx ${ctxPct}%</span>`
            : null}
        </div>
        ${ctxPct != null
          ? html`<div class="ctx-bar"><div class="ctx-fill ${ctxClass}" style="width: ${ctxPct}%"></div></div>`
          : null}
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
