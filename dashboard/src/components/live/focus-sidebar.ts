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
    <div class="grid gap-3 grid-rows-[auto_1fr] min-h-0">
      <div class="focus-sidebar-head">
        <h3 class="m-0 text-[0.95rem] font-semibold">Agents</h3>
        <span class="text-xs text-[rgba(255,255,255,0.4)]">${list.length} active</span>
      </div>
      <div class="grid gap-1.5 content-start overflow-y-auto max-h-[560px] pr-1">
        ${list.length === 0
          ? html`<div class="py-6 text-center text-[var(--white-25)] text-[13px]">No active agents</div>`
          : list.map(agent => html`
            <div
              key=${agent.name}
              class="focus-agent-card transition-colors duration-200 ${selected === agent.name ? 'focus-agent-selected' : ''}"
              onClick=${() => openAgentDetail(agent.name)}
            >
              <div class="focus-agent-header">
                <span class="text-[0.85rem] font-medium flex items-center gap-1">
                  ${agent.emoji ? html`<span class="text-[0.95rem]">${agent.emoji}</span>` : null}
                  ${agent.koreanName ?? agent.name}
                </span>
                <span class="focus-pressure-badge rounded-md ${pressureClass(agent.pressure)}">
                  ${pressureLabel(agent.pressure)}
                  ${agent.assignedCount > 0 ? html` <span class="bg-[var(--white-10)] px-1 text-[0.6rem] rounded">${agent.assignedCount}</span>` : null}
                </span>
              </div>
              ${agent.currentTask
                ? html`<div class="text-[0.75rem] text-[var(--white-55)] py-[3px] px-2 bg-[var(--white-3)] border border-[var(--white-5)] whitespace-nowrap overflow-hidden text-ellipsis rounded-md">${agent.currentTask}</div>`
                : null}
              <div class="focus-agent-footer">
                ${agent.lastActivityText
                  ? html`<span class="text-[11px] text-[var(--white-40)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0">${agent.lastActivityText}</span>`
                  : html`<span class="text-[11px] text-[var(--white-40)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0 italic text-[rgba(255,255,255,0.25)]">No recent activity</span>`}
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
