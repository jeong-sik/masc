// MASC Dashboard — Home Overview Surface
// Combines all overview sub-components into the Home landing view.

import { html } from 'htm/preact'
import { agents, keepers, tasks } from '../../store'
import { missionSnapshot } from '../../mission-store'
import { journal } from '../../sse'
import { navigate } from '../../router'
import { QuickStats } from './quick-stats'
import { EcosystemRing } from './ecosystem-ring'
import { SessionStrip } from './session-strip'
import { HealthBeacon } from './health-beacon'
import { ActivityTicker } from './activity-ticker'

export function Overview() {
  const snap = missionSnapshot.value
  const agentList = agents.value
  const keeperList = keepers.value
  const taskList = tasks.value

  const activeAgents = agentList.filter(a =>
    a.status === 'active' || a.status === 'busy' || a.status === 'listening'
  )
  const activeTasks = taskList.filter(t =>
    t.status === 'in_progress' || t.status === 'claimed'
  )

  const roomHealth = snap?.summary?.room_health ?? null
  const roomName = snap?.summary?.current_room ?? null
  const attentionCount = snap?.attention_queue?.length ?? snap?.summary?.pending_approvals ?? 0
  const sessions = snap?.sessions ?? snap?.session_briefs ?? []

  // Keeper mini-cards for the health sidebar
  const keeperBriefs = snap?.keeper_briefs ?? []

  return html`
    <div class="overview-surface">
      <${QuickStats}
        agentCount=${activeAgents.length}
        activeTaskCount=${activeTasks.length}
        keeperCount=${keeperList.length}
        attentionCount=${attentionCount}
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

          ${keeperBriefs.length > 0 ? html`
            <div class="overview-section-label" style="margin-top: var(--space-sm, 8px)">키퍼</div>
            ${keeperBriefs.map(k => html`
              <div class="keeper-mini-card" key=${k.name}>
                <span class="keeper-mini-card__name">${k.name}</span>
                <span class="keeper-mini-card__meta">
                  ${k.status ?? ''}
                  ${k.context_ratio != null ? ` / ctx ${Math.round(k.context_ratio * 100)}%` : ''}
                  ${k.generation != null ? ` / gen ${k.generation}` : ''}
                </span>
              </div>
            `)}
          ` : null}
        </div>
      </div>
    </div>
  `
}
