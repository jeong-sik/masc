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
    <div class="grid gap-2.5 grid-rows-[auto_1fr] min-h-0">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="text-xs text-[rgba(255,255,255,0.4)]">${list.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${list.length === 0
          ? html`<div class="focus-empty">No active agents</div>`
          : list.map(agent => html`
            <div
              key=${agent.name}
              class="focus-agent-card rounded-xl transition-colors duration-200 ${selected === agent.name ? 'focus-agent-selected' : ''}"
              onClick=${() => openAgentDetail(agent.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${agent.emoji ? html`<span class="text-[0.95rem]">${agent.emoji}</span>` : null}
                  ${agent.koreanName ?? agent.name}
                </span>
                <span class="focus-pressure-badge rounded-md ${pressureClass(agent.pressure)}">
                  ${pressureLabel(agent.pressure)}
                  ${agent.assignedCount > 0 ? html` <span class="focus-task-count rounded">${agent.assignedCount}</span>` : null}
                </span>
              </div>
              ${agent.currentTask
                ? html`<div class="focus-current-task rounded-md">${agent.currentTask}</div>`
                : null}
              <div class="focus-agent-footer">
                ${agent.lastActivityText
                  ? html`<span class="focus-activity-text">${agent.lastActivityText}</span>`
                  : html`<span class="focus-activity-text italic text-[rgba(255,255,255,0.25)]">No recent activity</span>`}
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
