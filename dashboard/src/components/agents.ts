// Agents tab — Agent card grid with status indicators

import { html } from 'htm/preact'
import { StatusBadge } from './common/status-badge'
import { MitosisRing } from "./common/mitosis-ring"
import { MetricTooltip } from './common/metric-tooltip'
import { TimeAgo } from './common/time-ago'
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
        <${MitosisRing} ratio=${(agent as any).context_ratio} />
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

function formatChangePct(value: unknown): string | null {
  if (typeof value !== 'number' || Number.isNaN(value)) return null
  return `${Math.round(value * 100)}%`
}

function keeperRecent(keeper: Keeper): string {
  const drift = keeper.last_drift_reason?.trim()
  if (drift) return drift
  const proactive = keeper.last_proactive_reason?.trim()
  if (proactive) return proactive
  const memory = keeper.memory_recent_note?.trim()
  if (memory) return memory
  return '—'
}

function keeperRelations(keeper: Keeper): string {
  const count = keeper.k2k_count ?? 0
  const top = keeper.k2k_mentions?.[0]
  if (!top) return String(count)
  return `${count} · ${top.keeper}(${top.count})`
}

function keeperPersonalityChange(keeper: Keeper): string {
  const driftCount = keeper.drift_count_total ?? 0
  const goalDrift = formatChangePct(keeper.metrics_window?.goal_drift_avg)
  if (driftCount === 0 && !goalDrift) return 'Stable'
  if (goalDrift) return `Drift ${driftCount} · Δ${goalDrift}`
  return `Drift ${driftCount}`
}

function KeeperCard({ keeper }: { keeper: Keeper }) {
  const recent = keeperRecent(keeper)
  const relations = keeperRelations(keeper)
  const personality = keeperPersonalityChange(keeper)

  return html`
    <div class="live-agent keeper-card" onClick=${() => openKeeperDetail(keeper)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${keeper.emoji ?? ''} ${keeper.name}</span>
          <${MitosisRing} ratio=${(keeper as any).context_ratio} />
        <${StatusBadge} status=${keeper.status} />
          ${keeper.model ? html`<span class="pill">${keeper.model}</span>` : null}
        </div>
        ${keeper.koreanName
          ? html`<div class="live-agent-sub">${keeper.koreanName}</div>`
          : null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${MetricTooltip} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${keeper.created_at ? html`<${TimeAgo} timestamp=${keeper.created_at} />` : '—'}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${MetricTooltip} metric="generation" /></span>
            <strong class="keeper-core-value">${keeper.generation ?? '—'}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${MetricTooltip} metric="status" /></span>
            <strong class="keeper-core-value">${keeper.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${MetricTooltip} metric="relations" /></span>
            <strong class="keeper-core-value">${relations}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${MetricTooltip} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${recent}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${MetricTooltip} metric="personality_change" /></span>
            <strong class="keeper-core-value">${personality}</strong>
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
