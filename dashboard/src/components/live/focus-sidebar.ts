// Focus Sidebar — active agents with task info and pressure gauge

import { html } from 'htm/preact'
import { focusAgents } from '../../live-store'
import { openAgentDetail, selectedAgentName } from '../agent-detail-state'
import { TimeAgo } from '../common/time-ago'
import { ringFocusClasses } from '../common/ring'

function pressureClass(pressure: 'calm' | 'normal' | 'hot'): string {
  switch (pressure) {
    case 'hot': return 'focus-pressure-hot'
    case 'normal': return 'focus-pressure-normal'
    default: return 'focus-pressure-calm'
  }
}

function pressureLabel(pressure: 'calm' | 'normal' | 'hot'): string {
  switch (pressure) {
    case 'hot': return '높음'
    case 'normal': return '활동중'
    default: return '평온'
  }
}

interface FocusSidebarProps {
  compact?: boolean
}

function FocusSidebarContent({ compact = false }: FocusSidebarProps) {
  const list = focusAgents.value
  const selected = selectedAgentName.value

  return html`
    <div class="grid gap-3 grid-rows-[auto_1fr] min-h-0">
      ${compact
        ? null
        : html`
            <div class="focus-sidebar-head flex items-center justify-between gap-3 border-b border-[var(--color-border-divider)] pb-3">
              <h3 class="m-0 text-md font-semibold text-[var(--color-fg-secondary)]">에이전트</h3>
              <span class="text-xs text-[var(--color-fg-muted)]">${list.length}명 활성</span>
            </div>
          `}
      <div class="grid content-start gap-1.5 overflow-y-auto pr-1 ${compact ? 'max-h-[32vh]' : 'max-h-140'}">
        ${list.length === 0
          ? html`<div class="py-6 text-center text-[var(--color-fg-muted)] text-sm">활성 에이전트 없음. masc_join으로 접속하면 여기에 표시됩니다.</div>`
          : list.map(agent => html`
            <button
              type="button"
              key=${agent.name}
              class=${`focus-agent-card w-full rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-surface)] p-3.5 transition-colors duration-[var(--t-med)] text-left cursor-pointer ${ringFocusClasses()} ${selected === agent.name ? 'focus-agent-selected' : ''}`}
              onClick=${() => openAgentDetail(agent.name)}
            >
              <div class="focus-agent-header">
                <span class="text-sm font-medium text-[var(--color-fg-secondary)] flex items-center gap-1">
                  ${agent.emoji ? html`<span class="text-md">${agent.emoji}</span>` : null}
                  ${agent.koreanName ?? agent.name}
                </span>
                <span class="focus-pressure-badge rounded-[var(--r-1)] ${pressureClass(agent.pressure)}">
                  ${pressureLabel(agent.pressure)}
                  ${agent.assignedCount > 0 ? html` <span class="bg-[var(--color-bg-hover)] px-1 text-[var(--fs-9)] rounded-[var(--r-1)]">${agent.assignedCount}</span>` : null}
                </span>
              </div>
              ${agent.currentTask
                ? html`<div class="text-xs text-[var(--color-fg-primary)] py-[3px] px-2 bg-[var(--color-bg-surface)] border border-[var(--color-border-divider)] whitespace-nowrap overflow-hidden text-ellipsis rounded-[var(--r-1)]">${agent.currentTask}</div>`
                : null}
              <div class="flex items-center gap-2 mt-1">
                ${agent.lastActivityText
                  ? html`<span class="text-2xs text-[var(--color-fg-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0">${agent.lastActivityText}</span>`
                  : html`<span class="text-2xs text-[var(--color-fg-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0 italic">최근 활동 없음</span>`}
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
