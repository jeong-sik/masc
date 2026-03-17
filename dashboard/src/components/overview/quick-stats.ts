// MASC Dashboard — Quick Stats Bar (4 key metrics + task distribution + data source)

import { html } from 'htm/preact'
import { navigate } from '../../router'

export interface TaskBreakdown {
  todo: number; claimed: number; inProgress: number; done: number
}

export type TaskSource = 'store' | 'cache'

interface QuickStatsProps {
  agentCount: number
  activeTaskCount: number
  keeperCount: number
  attentionCount: number
  taskBreakdown?: TaskBreakdown
  taskSource?: TaskSource
}

function TaskDistributionBar({ breakdown }: { breakdown: TaskBreakdown }) {
  const total = breakdown.todo + breakdown.claimed + breakdown.inProgress + breakdown.done
  if (total === 0) return null

  const pct = (n: number) => `${(n / total * 100).toFixed(1)}%`

  return html`
    <div class="task-distribution-bar" style="margin-top: 6px">
      <div class="task-distribution-bar__track">
        ${breakdown.todo > 0 ? html`<div class="task-distribution-bar__segment" style=${{ width: pct(breakdown.todo), background: '#94a3b8' }} />` : null}
        ${breakdown.claimed > 0 ? html`<div class="task-distribution-bar__segment" style=${{ width: pct(breakdown.claimed), background: '#f59e0b' }} />` : null}
        ${breakdown.inProgress > 0 ? html`<div class="task-distribution-bar__segment" style=${{ width: pct(breakdown.inProgress), background: '#22d3ee' }} />` : null}
        ${breakdown.done > 0 ? html`<div class="task-distribution-bar__segment" style=${{ width: pct(breakdown.done), background: '#4ade80' }} />` : null}
      </div>
      <div class="task-distribution-bar__legend">
        <span>todo ${breakdown.todo}</span>
        <span>claimed ${breakdown.claimed}</span>
        <span>진행 ${breakdown.inProgress}</span>
        <span>done ${breakdown.done}</span>
      </div>
    </div>
  `
}

export function QuickStats({ agentCount, activeTaskCount, keeperCount, attentionCount, taskBreakdown, taskSource }: QuickStatsProps) {
  return html`
    <div class="overview-stats">
      <div class="overview-stat"
        style="cursor: pointer;"
        onClick=${() => navigate('agent-roster')}
      >
        <span class="overview-stat__label">에이전트</span>
        <strong class="overview-stat__value">${agentCount}</strong>
      </div>
      <div class="overview-stat"
        style="cursor: pointer;"
        onClick=${() => navigate('planning')}
      >
        <span class="overview-stat__label">활성 태스크</span>
        <strong class="overview-stat__value">${activeTaskCount}</strong>
        ${taskSource === 'cache' ? html`
          <span class="overview-stat__source">(캐시)</span>
        ` : null}
        ${taskBreakdown ? html`<${TaskDistributionBar} breakdown=${taskBreakdown} />` : null}
      </div>
      <div class="overview-stat"
        style="cursor: pointer;"
        onClick=${() => navigate('keeper-roster')}
      >
        <span class="overview-stat__label">키퍼</span>
        <strong class="overview-stat__value">${keeperCount}</strong>
      </div>
      <div class="overview-stat">
        <span class="overview-stat__label">주의 필요</span>
        <strong class="overview-stat__value">${attentionCount}</strong>
      </div>
    </div>
  `
}
