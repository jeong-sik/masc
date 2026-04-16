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
import { connected, totalEvents } from '../../sse'
import { EmptyState, ErrorState } from '../common/feedback-state'
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
    <div class="flex flex-wrap gap-1.5">
      ${FILTER_OPTIONS.map(opt => html`
        <button type="button"
          key=${opt.kind}
          class="px-3 py-1.5 text-[11px] rounded-full border cursor-pointer transition-all duration-150 ${active.has(opt.kind)
            ? 'border-[var(--border-slate-22)] bg-[var(--accent-soft)] text-[var(--text-strong)]'
            : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[var(--border-slate-22)] hover:text-[var(--text-body)]'}"
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
    <div class="grid gap-3 grid-rows-[auto_auto_1fr] min-h-0">
      <div class="activity-stream-head flex items-center justify-between gap-3 border-b border-[var(--border-slate-12)] pb-3">
        <h3 class="m-0 text-[0.95rem] font-semibold text-[var(--text-strong)]">활동 스트림</h3>
        <span class="text-xs text-[var(--text-muted)]">${totalEvents.value} 수신 · ${entries.length} 표시</span>
      </div>
      <${FilterBar} />
      <div class="activity-stream-list grid max-h-[52vh] min-h-0 content-start gap-2 overflow-y-auto pr-1">
        ${entries.length === 0
          ? !connected.value
            ? html`<${ErrorState} message="실시간 연결이 끊겨있습니다. 서버 상태를 확인하세요." />`
            : liveFilters.value.size > 0
              ? html`<${EmptyState} message="선택한 필터에 맞는 이벤트가 없습니다. 필터를 해제해 보세요." />`
              : html`<${EmptyState} message="아직 수신된 이벤트가 없습니다. 에이전트가 활동하면 여기에 표시됩니다." />`
          : entries.map((entry, i) => html`
            <div
              key=${`${entry.timestamp}-${i}`}
              class="activity-item rounded-2xl border border-[var(--border-slate-12)] border-l-2 bg-[var(--white-2)] px-3.5 py-3 ${eventKindColor(entry)} ${i === 0 ? 'activity-item-new' : ''}"
            >
              <div class="activity-item-head flex items-center gap-2">
                <span class="activity-kind-chip rounded-md px-2 py-0.5 text-[10px] font-medium uppercase tracking-[0.04em] ${eventKindColor(entry)}">${eventKindLabel(entry)}</span>
                <span class="text-[0.75rem] text-[var(--text-body)] font-medium">${entry.agent}</span>
                <span class="text-[0.7rem] text-[var(--text-muted)] ml-auto">${formatTimeAgo(entry.timestamp)}</span>
              </div>
              <div class="text-[13px] text-[var(--text-body)] leading-[1.5] break-words">${entry.text}</div>
            </div>
          `)}
      </div>
    </div>
  `
}
