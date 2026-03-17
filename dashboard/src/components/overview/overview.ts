// MASC Dashboard — Home Overview Surface (Redesigned)
// 4-Layer information architecture: Situation -> Anomaly -> Entity Grid -> Timeline

import { html } from 'htm/preact'
import { agents, keepers, tasks, shellCounts, providerCapacity, agentActivity, refreshAgentActivity } from '../../store'
import { useEffect } from 'preact/hooks'
import { missionSnapshot } from '../../mission-store'
import { journal } from '../../sse'
import { navigate } from '../../router'
import { formatDuration } from '../mission-utils'
import { SituationBanner } from './situation-banner'
import { AttentionSpotlight } from './attention-spotlight'
import { AgentGrid } from './agent-grid'
import { SessionTriage } from './session-triage'
import { NarrativeTimeline } from './narrative-timeline'
import { QuickStats } from './quick-stats'
import type { TaskBreakdown } from './quick-stats'
import { DASHBOARD_SURFACES } from '../../config/navigation'

function pressureClass(ratio: number | null | undefined): string {
  if (ratio == null) return ''
  const pct = ratio * 100
  if (pct < 50) return 'pressure--ok'
  if (pct < 70) return 'pressure--amber'
  if (pct < 85) return 'pressure--orange'
  return 'pressure--red'
}

function keeperHealthClass(status?: string): string {
  const s = (status ?? '').toLowerCase()
  if (s === 'active' || s === 'running' || s === 'ok') return 'keeper-status--ok'
  if (s === 'idle' || s === 'listening') return 'keeper-status--idle'
  if (s === 'offline' || s === 'inactive') return 'keeper-status--offline'
  return ''
}

export function Overview() {
  useEffect(() => { refreshAgentActivity() }, [])
  const snap = missionSnapshot.value
  const agentList = agents.value
  const keeperList = keepers.value
  const taskList = tasks.value
  const counts = shellCounts.value

  const activeAgents = agentList.filter((a: { status: string }) =>
    a.status === 'active' || a.status === 'busy' || a.status === 'listening'
  )
  const activeTasks = taskList.filter((t: { status: string }) =>
    t.status === 'in_progress' || t.status === 'claimed'
  )

  const agentCount = activeAgents.length > 0 ? activeAgents.length : (counts?.agents ?? 0)
  const taskCount = activeTasks.length > 0 ? activeTasks.length : (counts?.tasks ?? 0)
  const keeperCount = keeperList.length > 0 ? keeperList.length : (counts?.keepers ?? 0)

  const taskBreakdown: TaskBreakdown = {
    todo: taskList.filter((t: { status: string }) => t.status === 'todo').length,
    claimed: taskList.filter((t: { status: string }) => t.status === 'claimed').length,
    inProgress: taskList.filter((t: { status: string }) => t.status === 'in_progress').length,
    done: taskList.filter((t: { status: string }) => t.status === 'done').length,
  }

  const roomHealth = snap?.summary?.room_health ?? null
  const attentionCount = snap?.attention_queue?.length ?? snap?.summary?.pending_approvals ?? 0
  const sessions = snap?.sessions ?? snap?.session_briefs ?? []
  const agentBriefs = snap?.agent_briefs ?? []
  const keeperBriefs = snap?.keeper_briefs ?? []

  const navSurfaces = DASHBOARD_SURFACES.filter(s => s.id !== 'home')

  return html`
    <div class="overview-surface">
      <${SituationBanner} snap=${snap} roomHealth=${roomHealth} />
      <${AttentionSpotlight} snap=${snap} />

      <${QuickStats}
        agentCount=${agentCount}
        activeTaskCount=${taskCount}
        keeperCount=${keeperCount}
        attentionCount=${attentionCount}
        taskBreakdown=${taskBreakdown}
      />

      <${ProviderGauge} />

      <div class="overview-main-v2">
        <div class="overview-left-col">
          <div class="overview-section-label">에이전트</div>
          <${AgentGrid}
            agents=${agentList}
            agentBriefs=${agentBriefs}
            onAgentClick=${(name: string) => navigate('execution', { agent: name })}
          />
        </div>

        <div class="overview-right-col">
          <div class="overview-section-label">세션</div>
          <${SessionTriage} sessions=${sessions} />

          ${keeperBriefs.length > 0 ? html`
            <div class="overview-section-label" style="margin-top: var(--space-md, 16px)">키퍼</div>
            <div class="keeper-cards-v2">
              ${keeperBriefs.map(k => html`
                <div class="keeper-card-v2 ${keeperHealthClass(k.status)}" key=${k.name}>
                  <div class="keeper-card-v2__header">
                    <span class="keeper-card-v2__name">${k.name}</span>
                    ${k.generation != null ? html`
                      <span class="keeper-card-v2__gen">G${k.generation}</span>
                    ` : null}
                  </div>
                  ${k.current_work ? html`
                    <div class="keeper-card-v2__work">${k.current_work}</div>
                  ` : null}
                  ${k.context_ratio != null ? html`
                    <div class="keeper-card-v2__pressure">
                      <div
                        class="keeper-card-v2__pressure-bar ${pressureClass(k.context_ratio)}"
                        style=${{ width: `${Math.round(k.context_ratio * 100)}%` }}
                      />
                      <span class="keeper-card-v2__pressure-label">
                        ctx ${Math.round(k.context_ratio * 100)}%
                      </span>
                    </div>
                  ` : null}
                  ${k.last_turn_ago_s != null ? html`
                    <span class="keeper-card-v2__activity">
                      ${formatDuration(k.last_turn_ago_s)} 전
                    </span>
                  ` : null}
                </div>
              `)}
            </div>
          ` : null}

          <div class="overview-section-label" style="margin-top: var(--space-md, 16px)">최근 활동</div>
          <${NarrativeTimeline} entries=${journal} maxItems=${12} />

          <${AgentActivityPanel} />
        </div>
      </div>

      <nav class="overview-nav-strip">
        ${navSurfaces.map(surface => html`
          <button
            class="overview-nav-btn"
            key=${surface.id}
            onClick=${() => navigate(surface.defaultTab)}
          >
            <span class="overview-nav-icon">${surface.icon}</span>
            <span class="overview-nav-label">${surface.label}</span>
            <span class="overview-nav-desc">${surface.description}</span>
          </button>
        `)}
      </nav>
    </div>
  `
}

function ProviderGauge() {
  const cap = providerCapacity.value
  if (!cap) return null

  const pool = cap.glm_pool
  const agentCap = cap.agent_capacity
  const loadPct = pool.total_capacity > 0
    ? Math.round((pool.current_load / pool.total_capacity) * 100)
    : 0
  const loadTone = loadPct < 50 ? 'ok' : loadPct < 80 ? 'warn' : 'bad'

  return html`
    <div class="mission-stat-grid" style="margin-bottom: var(--space-md, 16px);">
      <div class="summary-stat-card ${loadTone}">
        <span>GLM Pool</span>
        <strong>${pool.current_load}/${pool.total_capacity}</strong>
        <small>${pool.has_capacity ? 'capacity available' : 'at capacity'}</small>
      </div>
      <div class="summary-stat-card">
        <span>Agent Slots</span>
        <strong>${agentCap.target_agents}</strong>
        <small>${agentCap.min_agents}-${agentCap.max_agents} range${agentCap.gardener_enabled ? '' : ' (gardener off)'}</small>
      </div>
      ${pool.models.length > 0 ? html`
        <div class="summary-stat-card">
          <span>Models</span>
          <strong>${pool.models.length}</strong>
          <small>${pool.models.map((m: { model: string }) => m.model).join(', ')}</small>
        </div>
      ` : null}
    </div>
  `
}

function relativeTimeShort(ts: number): string {
  const diff = (Date.now() / 1000) - ts
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

function AgentActivityPanel() {
  const activities = agentActivity.value
  if (activities.length === 0) return null

  return html`
    <div style="margin-top: var(--space-md, 16px);">
      <div class="overview-section-label">에이전트 활동 (24h)</div>
      <div style="display: flex; flex-direction: column; gap: 6px;">
        ${activities.slice(0, 8).map(a => html`
          <div class="mission-activity-row" style="padding: 8px 12px;" key=${a.agent_id}>
            <div style="display: flex; justify-content: space-between; align-items: center;">
              <strong style="font-size: 13px;">${a.agent_id}</strong>
              <span class="command-chip ${a.failure_count > 0 ? 'warn' : 'ok'}" style="font-size: 11px;">
                ${a.tool_calls} calls
              </span>
            </div>
            <div style="font-size: 11px; color: rgba(255,255,255,0.45); margin-top: 2px;">
              ${a.success_count} ok / ${a.failure_count} fail · ${relativeTimeShort(a.last_seen)}
            </div>
          </div>
        `)}
      </div>
    </div>
  `
}
