// MASC Dashboard — Home Overview Surface

import { html } from 'htm/preact'
import { agents, keepers, tasks, shellCounts } from '../../store'
import { missionSnapshot } from '../../mission-store'
import { journal } from '../../sse'
import { navigate } from '../../router'
import { QuickStats } from './quick-stats'
import type { TaskBreakdown } from './quick-stats'
import { EcosystemRing } from './ecosystem-ring'
import { SessionStrip } from './session-strip'
import { HealthBeacon } from './health-beacon'
import { ActivityTicker } from './activity-ticker'
import { KeeperSummaryCard } from './keeper-summary-card'
import { DASHBOARD_SURFACES } from '../../config/navigation'

export function Overview() {
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
  const roomName = snap?.summary?.current_room ?? null
  const attentionCount = snap?.attention_queue?.length ?? snap?.summary?.pending_approvals ?? 0
  const sessions = snap?.sessions ?? snap?.session_briefs ?? []

  const navSurfaces = DASHBOARD_SURFACES.filter(s => s.id !== 'home')

  return html`
    <div class="overview-surface">
      <${QuickStats}
        agentCount=${agentCount}
        activeTaskCount=${taskCount}
        keeperCount=${keeperCount}
        attentionCount=${attentionCount}
        taskBreakdown=${taskBreakdown}
      />

      <div class="overview-main">
        <div class="overview-ring-col">
          <div class="overview-section-label">에이전트 생태계</div>
          <${EcosystemRing}
            agents=${agentList}
            roomName=${roomName}
            roomHealth=${roomHealth}
            onAgentClick=${(name: string) => navigate('execution', { agent: name })}
          />
        </div>

        <div class="overview-sessions-col">
          <div class="overview-section-label">활성 세션</div>
          <${SessionStrip} sessions=${sessions} />

          <div class="overview-section-label" style="margin-top: var(--space-sm, 8px)">최근 활동</div>
          <${ActivityTicker} entries=${journal} maxItems=${8} />
        </div>

        <div class="overview-health-col">
          <div class="overview-section-label">시스템 상태</div>
          <${HealthBeacon} health=${roomHealth} />

          ${keeperList.length > 0 ? html`
            <div class="overview-section-label" style="margin-top: var(--space-sm, 8px)">키퍼</div>
            ${keeperList.map(k => html`
              <${KeeperSummaryCard} key=${k.name} keeper=${k} />
            `)}
          ` : null}
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
