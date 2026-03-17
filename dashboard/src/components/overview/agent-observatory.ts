// Agent Observatory — session-grouped agent view
// Groups agents by team session, showing each agent's state, focus, tools, and signal age.
// Stale agents are visually dimmed; all-stale state shows an honest summary.

import { html } from 'htm/preact'
import { AgentAvatar } from './agent-avatar'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { observatoryGroups, type ObservatoryAgent, type ObservatoryGroup } from '../../observatory-store'

interface AgentObservatoryProps {
  onAgentClick?: (name: string) => void
}

function stateLabel(state: string): string {
  switch (state) {
    case 'working': return '작업 중'
    case 'watching': return '관찰 중'
    case 'quiet': return '조용함'
    case 'offline': return '오프라인'
    default: return state
  }
}

function healthColor(health: string | null): string {
  if (!health) return 'var(--text-muted, #666)'
  switch (health) {
    case 'ok':
    case 'healthy':
      return 'var(--status-ok, #4ade80)'
    case 'degraded':
      return 'var(--status-warn, #fbbf24)'
    case 'critical':
    case 'bad':
      return 'var(--status-bad, #f87171)'
    default:
      return 'var(--text-muted, #666)'
  }
}

function contextBar(ratio: number | null) {
  if (ratio == null) return null
  const pct = Math.round(ratio * 100)
  const barColor =
    pct < 50 ? 'var(--status-ok, #4ade80)'
    : pct < 70 ? 'var(--status-warn, #fbbf24)'
    : pct < 85 ? '#f97316'
    : 'var(--status-bad, #f87171)'

  return html`
    <span class="obs-ctx" title="context ${pct}%">
      <span class="obs-ctx__bar" style=${{ width: `${pct}%`, background: barColor }} />
      <span class="obs-ctx__label">${pct}%</span>
    </span>
  `
}

function toolChips(tools: string[]) {
  if (tools.length === 0) return null
  const display = tools.slice(0, 3)
  const remaining = tools.length - display.length
  return html`
    <span class="obs-tools">
      ${display.map(t => html`<span class="obs-tool-chip" key=${t}>${t}</span>`)}
      ${remaining > 0 ? html`<span class="obs-tool-chip obs-tool-chip--more">+${remaining}</span>` : null}
    </span>
  `
}

function truncate(text: string | null, max = 60): string | null {
  if (!text) return null
  const clean = text.replace(/\s+/g, ' ').trim()
  if (!clean) return null
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean
}

/** Determine if an agent's signal is stale (no fresh data in 10+ minutes) */
function isStaleAgent(agent: ObservatoryAgent): boolean {
  if (agent.signalTruth === 'stale' || agent.signalTruth === 'archived') return true
  if (agent.lastSignalAgeSec != null && agent.lastSignalAgeSec > 600) return true
  return agent.state === 'quiet' || agent.state === 'offline'
}

function staleDurationLabel(ageSec: number | null): string | null {
  if (ageSec == null) return null
  if (ageSec < 3600) return `${Math.floor(ageSec / 60)}분 전 마지막 신호`
  if (ageSec < 86400) return `${Math.floor(ageSec / 3600)}시간 전 마지막 신호`
  return `${Math.floor(ageSec / 86400)}일 전 마지막 신호`
}

function AgentRow({ agent, onAgentClick }: { agent: ObservatoryAgent; onAgentClick?: (name: string) => void }) {
  const focusText = truncate(agent.focus ?? agent.currentTask)
  const previewText = truncate(agent.recentOutputPreview, 80)
  const stale = isStaleAgent(agent)
  const staleLabel = stale ? staleDurationLabel(agent.lastSignalAgeSec) : null

  return html`
    <div
      class="obs-agent-row obs-agent-row--${agent.state} ${stale ? 'obs-agent-row--stale' : ''}"
      onClick=${onAgentClick ? () => onAgentClick(agent.name) : undefined}
      role=${onAgentClick ? 'button' : undefined}
      tabindex=${onAgentClick ? '0' : undefined}
      onKeyDown=${onAgentClick ? (e: KeyboardEvent) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onAgentClick(agent.name) }
      } : undefined}
    >
      <div class="obs-agent-row__avatar">
        <${AgentAvatar}
          name=${agent.name}
          status=${agent.status}
          size="sm"
          activityAge=${agent.lastSignalAgeSec}
          signalTruth=${agent.signalTruth}
        />
      </div>

      <div class="obs-agent-row__info">
        <div class="obs-agent-row__name-line">
          <span class="obs-agent-row__name">${agent.name}</span>
          ${agent.koreanName ? html`<span class="obs-agent-row__korean">(${agent.koreanName})</span>` : null}
          <span class="obs-agent-row__state obs-agent-row__state--${agent.state}">
            ${stateLabel(agent.state)}
          </span>
          ${stale ? html`<span class="obs-agent-row__stale-badge">stale</span>` : null}
          ${agent.model ? html`<span class="obs-agent-row__model">${agent.model}</span>` : null}
        </div>

        ${staleLabel && !focusText ? html`
          <div class="obs-agent-row__focus obs-agent-row__focus--stale">${staleLabel}</div>
        ` : null}
        ${focusText ? html`
          <div class="obs-agent-row__focus">${focusText}</div>
        ` : null}

        <div class="obs-agent-row__meta">
          ${toolChips(agent.recentTools)}
          ${contextBar(agent.contextRatio)}
          ${agent.lastSignalAt ? html`
            <span class="obs-agent-row__signal">
              <${TimeAgo} timestamp=${agent.lastSignalAt} />
            </span>
          ` : null}
        </div>

        ${previewText ? html`
          <div class="obs-agent-row__preview">${previewText}</div>
        ` : null}
      </div>
    </div>
  `
}

function SessionGroupHeader({ group }: { group: ObservatoryGroup }) {
  if (!group.sessionId) {
    return html`
      <div class="obs-group-header obs-group-header--unassigned">
        <span class="obs-group-header__title">미배정 에이전트</span>
        <span class="obs-group-header__count">${group.agents.length}</span>
      </div>
    `
  }

  const workingCount = group.agents.filter(a => a.state === 'working').length

  return html`
    <div class="obs-group-header">
      <div class="obs-group-header__top">
        <span
          class="obs-group-header__health-dot"
          style=${{ background: healthColor(group.health) }}
        />
        <span class="obs-group-header__title">${group.goal ?? group.sessionId}</span>
        ${group.status ? html`<${StatusBadge} status=${group.status} />` : null}
      </div>
      <div class="obs-group-header__stats">
        <span>${group.memberCount} 에이전트</span>
        ${workingCount > 0 ? html`<span class="obs-group-header__working">${workingCount} 작업 중</span>` : null}
        <span class="obs-group-header__session-id">${group.sessionId}</span>
      </div>
    </div>
  `
}

export function AgentObservatory({ onAgentClick }: AgentObservatoryProps) {
  const groups = observatoryGroups.value

  if (groups.length === 0) {
    return html`
      <div class="obs-empty">
        <div style="color: var(--text-muted); padding: 16px;">등록된 에이전트 없음</div>
      </div>
    `
  }

  const totalAgents = groups.reduce((sum: number, g: ObservatoryGroup) => sum + g.agents.length, 0)
  const totalWorking = groups.reduce(
    (sum: number, g: ObservatoryGroup) => sum + g.agents.filter((a: ObservatoryAgent) => a.state === 'working').length, 0,
  )
  const totalStale = groups.reduce(
    (sum: number, g: ObservatoryGroup) => sum + g.agents.filter((a: ObservatoryAgent) => isStaleAgent(a)).length, 0,
  )
  const allStale = totalStale === totalAgents && totalAgents > 0

  return html`
    <div class="obs-container ${allStale ? 'obs-container--all-stale' : ''}">
      <div class="obs-summary">
        ${allStale ? html`
          <span class="obs-summary__stale-notice">${totalAgents}개 에이전트 등록됨 (활성 신호 없음)</span>
        ` : html`
          <span>${totalAgents} 에이전트</span>
          ${totalWorking > 0 ? html`<span class="obs-summary__working">${totalWorking} 작업 중</span>` : null}
          ${totalStale > 0 ? html`<span class="obs-summary__stale">${totalStale} stale</span>` : null}
          <span>${groups.filter((g: ObservatoryGroup) => g.sessionId).length} 세션</span>
        `}
      </div>

      ${groups.map(group => html`
        <div class="obs-group" key=${group.sessionId ?? '__unassigned'}>
          <${SessionGroupHeader} group=${group} />
          <div class="obs-agent-list">
            ${group.agents.map(agent => html`
              <${AgentRow} key=${agent.name} agent=${agent} onAgentClick=${onAgentClick} />
            `)}
          </div>
        </div>
      `)}
    </div>
  `
}
