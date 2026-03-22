// Focus Sidebar — active agents with task info and pressure gauge

import { html } from 'htm/preact'
import { focusAgents } from '../../live-store'
import { openAgentDetail, selectedAgentName } from '../agent-detail'
import { TimeAgo } from '../common/time-ago'

function pressureClass(pressure: 'calm' | 'normal' | 'hot'): string {
  switch (pressure) {
    case 'hot': return 'focus-pressure-hot'
    case 'normal': return 'focus-pressure-normal'
    default: return 'focus-pressure-calm'
  }
}

function pressureLabel(pressure: 'calm' | 'normal' | 'hot'): string {
  switch (pressure) {
    case 'hot': return 'High'
    case 'normal': return 'Active'
    default: return 'Calm'
  }
}

export function FocusSidebar() {
  const list = focusAgents.value
  const selected = selectedAgentName.value

  return html`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${list.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${list.length === 0
          ? html`<div class="focus-empty">No active agents</div>`
          : list.map(agent => html`
            <div
              key=${agent.name}
              class="focus-agent-card ${selected === agent.name ? 'focus-agent-selected' : ''}"
              onClick=${() => openAgentDetail(agent.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${agent.emoji ? html`<span class="text-[0.95rem]">${agent.emoji}</span>` : null}
                  ${agent.koreanName ?? agent.name}
                </span>
                <span class="focus-pressure-badge ${pressureClass(agent.pressure)}">
                  ${pressureLabel(agent.pressure)}
                  ${agent.assignedCount > 0 ? html` <span class="focus-task-count">${agent.assignedCount}</span>` : null}
                </span>
              </div>
              ${agent.currentTask
                ? html`<div class="focus-current-task">${agent.currentTask}</div>`
                : null}
              <div class="focus-agent-footer">
                ${agent.lastActivityText
                  ? html`<span class="focus-activity-text">${agent.lastActivityText}</span>`
                  : html`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${agent.lastActivityAt
                  ? html`<${TimeAgo} timestamp=${agent.lastActivityAt} />`
                  : null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `
}
