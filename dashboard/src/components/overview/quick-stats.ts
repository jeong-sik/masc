// MASC Dashboard — Quick Stats Bar (4 key metrics)

import { html } from 'htm/preact'

interface QuickStatsProps {
  agentCount: number
  activeTaskCount: number
  keeperCount: number
  attentionCount: number
}

export function QuickStats({ agentCount, activeTaskCount, keeperCount, attentionCount }: QuickStatsProps) {
  return html`
    <div class="overview-stats">
      <div class="overview-stat">
        <span class="overview-stat__label">에이전트</span>
        <strong class="overview-stat__value">${agentCount}</strong>
      </div>
      <div class="overview-stat">
        <span class="overview-stat__label">활성 태스크</span>
        <strong class="overview-stat__value">${activeTaskCount}</strong>
      </div>
      <div class="overview-stat">
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
