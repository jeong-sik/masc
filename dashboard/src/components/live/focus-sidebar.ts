// Focus Sidebar — active agents with task info and pressure gauge

import { html } from 'htm/preact'
import { focusAgents } from '../../live-store'
import { openAgentDetail, selectedAgentName } from '../agent-detail-state'
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

interface FocusSidebarProps {
  compact?: boolean
}

function FocusSidebarContent({ compact = false }: FocusSidebarProps) {
  const list = focusAgents.value
  const selected = selectedAgentName.value

  return html`
    <div class="grid gap-3 grid-rows-[auto_1fr] min-h-0" role="region" aria-label="에이전트 상태">
      ${compact
        ? null
        : html`
            <div class="focus-sidebar-head flex items-center justify-between gap-3 border-b border-[var(--border-slate-12)] pb-3">
              <h3 class="m-0 text-[0.95rem] font-semibold text-[var(--text-strong)]">에이전트</h3>
              <span class="text-xs text-[var(--text-muted)]">${list.length}명 활성</span>
            </div>
          `}
      <div class="grid content-start gap-1.5 overflow-y-auto custom-scrollbar pr-1 ${compact ? 'max-h-[32vh]' : 'max-h-140'}">
        ${list.length === 0
          ? html`<div class="py-6 text-center text-[var(--text-muted)] text-sm">활성 에이전트 없음. masc_join으로 접속하면 여기에 표시됩니다.</div>`
          : list.map(agent => html`
            <button type="button"
              key=${agent.name}
              class="focus-agent-card w-full rounded border border-[var(--border-slate-12)] bg-[var(--white-3)] p-3.5 transition-colors duration-200 text-left cursor-pointer focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent ${selected === agent.name ? 'focus-agent-selected' : ''}"
              onClick=${() => openAgentDetail(agent.name)}
              aria-label=${`${agent.koreanName ?? agent.name}${agent.currentTask ? ` — ${agent.currentTask}` : ''}`}
            >
              <div class="focus-agent-header">
                <span class="text-[0.85rem] font-medium text-[var(--text-strong)] flex items-center gap-1">
                  ${agent.emoji ? html`<span class="text-[0.95rem]">${agent.emoji}</span>` : null}
                  ${agent.koreanName ?? agent.name}
                </span>
                <span class="focus-pressure-badge rounded ${pressureClass(agent.pressure)}">
                  ${pressureLabel(agent.pressure)}
                  ${agent.assignedCount > 0 ? html` <span class="bg-[var(--white-10)] px-1 text-[0.6rem] rounded">${agent.assignedCount}</span>` : null}
                </span>
              </div>
              ${agent.currentTask
                ? html`<div class="text-[0.75rem] text-[var(--text-body)] py-[3px] px-2 bg-[var(--white-2)] border border-[var(--border-slate-12)] whitespace-nowrap overflow-hidden text-ellipsis rounded">${agent.currentTask}</div>`
                : null}
              <div class="flex items-center gap-2 mt-1">
                ${agent.lastActivityText
                  ? html`<span class="text-2xs text-[var(--text-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0">${agent.lastActivityText}</span>`
                  : html`<span class="text-2xs text-[var(--text-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0 italic">최근 활동 없음</span>`}
                ${agent.lastActivityAt
                  ? html`<${TimeAgo} timestamp=${agent.lastActivityAt} />`
                  : null}
              </div>
            </button>
          `)}
      </div>
    </div>
  `
}

export function FocusSidebar(props: FocusSidebarProps) {
  return html`<${FocusSidebarContent} compact=${props.compact ?? false} />`
}
