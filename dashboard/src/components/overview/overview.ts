// MASC Dashboard — Home Overview Surface (Redesigned)
// 4-Layer information architecture: Situation -> Anomaly -> Entity Grid -> Timeline

import { html } from 'htm/preact'
import { agents, keepers, tasks, shellCounts } from '../../store'
import { missionSnapshot } from '../../mission-store'
import { journal } from '../../sse'
import { navigate } from '../../router'
import { formatDuration } from '../mission-utils'
import { SituationBanner } from './situation-banner'
import { AttentionSpotlight } from './attention-spotlight'
import { AgentObservatory } from './agent-observatory'
import { SessionTriage } from './session-triage'
import { NarrativeTimeline } from './narrative-timeline'
import { QuickStats } from './quick-stats'
import type { TaskBreakdown, TaskSource } from './quick-stats'

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
  const taskSource: TaskSource = activeTasks.length > 0 ? 'store' : 'cache'
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
  const keeperBriefs = snap?.keeper_briefs ?? []

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
        taskSource=${taskSource}
      />

      <div class="overview-main-v2">
        <div class="overview-left-col">
          <div class="overview-section-header">
            <span class="overview-section-label">에이전트 Observatory</span>
            <a class="overview-section-link" onClick=${() => navigate('agent-roster')}>전체 보기</a>
          </div>
          <${AgentObservatory}
            onAgentClick=${(name: string) => navigate('execution', { agent: name })}
          />
        </div>

        <div class="overview-right-col">
          <div class="overview-section-label">세션</div>
          <${SessionTriage} sessions=${sessions} />

          ${keeperBriefs.length > 0 ? html`
            <div class="overview-section-header" style="margin-top: var(--space-md, 16px)">
              <span class="overview-section-label">키퍼</span>
              <a class="overview-section-link" onClick=${() => navigate('keeper-roster')}>전체 보기</a>
            </div>
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
        </div>
      </div>
    </div>
  `
}

