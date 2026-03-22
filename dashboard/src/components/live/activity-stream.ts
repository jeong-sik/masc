// Activity Stream — filtered journal feed with color-coded events

import { html } from 'htm/preact'
import {
  filteredJournal,
  liveFilters,
  toggleLiveFilter,
  eventKindColor,
  eventKindLabel,
  type LiveFilterKind,
} from '../../live-store'
import { formatTimeAgo } from '../common/time-ago'

const FILTER_OPTIONS: { kind: LiveFilterKind; label: string; cssClass: string }[] = [
  { kind: 'broadcast', label: 'Broadcast', cssClass: 'live-event-broadcast' },
  { kind: 'tasks', label: 'Task', cssClass: 'live-event-task' },
  { kind: 'keepers', label: 'Keeper', cssClass: 'live-event-keeper' },
  { kind: 'system', label: 'System', cssClass: 'live-event-system' },
]

function FilterBar() {
  const active = liveFilters.value

  return html`
    <div class="flex gap-1.5">
      ${FILTER_OPTIONS.map(opt => html`
        <button
          key=${opt.kind}
          class="activity-filter-btn rounded-md ${opt.cssClass} ${active.has(opt.kind) ? 'active' : ''}"
          onClick=${() => toggleLiveFilter(opt.kind)}
        >
          ${opt.label}
        </button>
      `)}
    </div>
  `
}

export function ActivityStream() {
  const entries = filteredJournal.value

  return html`
    <div class="grid gap-2.5 grid-rows-[auto_auto_1fr] min-h-0">
      <div class="activity-stream-head">
        <h3 class="m-0 text-[15px] font-semibold">Activity Stream</h3>
        <span class="text-xs text-[var(--text-muted)]">${entries.length} events</span>
      </div>
      <${FilterBar} />
      <div class="activity-stream-list">
        ${entries.length === 0
          ? html`<div class="py-6 text-center text-[var(--text-dim)] text-[13px]">필터에 맞는 이벤트 없음</div>`
          : entries.map((entry, i) => html`
            <div
              key=${`${entry.timestamp}-${i}`}
              class="activity-item rounded-lg ${eventKindColor(entry)} ${i === 0 ? 'activity-item-new' : ''}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip rounded ${eventKindColor(entry)}">${eventKindLabel(entry)}</span>
                <span class="text-xs text-[var(--text-muted)] font-medium">${entry.agent}</span>
                <span class="text-[11px] text-[var(--text-dim)] ml-auto">${formatTimeAgo(entry.timestamp)}</span>
              </div>
              <div class="text-[13px] text-[var(--text-body)] leading-[1.4] break-words">${entry.text}</div>
            </div>
          `)}
      </div>
    </div>
  `
}
