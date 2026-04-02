// Task activity list — renders UnifiedTraceEvent[] with collapsible entries.
// Independent from global traceSlots (avoids keeper-detail overlay collision).

import { html } from 'htm/preact'
import { EmptyState } from '../common/empty-state'
import { LoadingState } from '../common/feedback-state'
import { TimeAgo } from '../common/time-ago'
import type { UnifiedTraceEvent, TraceEventKind } from '../session-trace/session-trace-state'
import { activeFilter, type ActivityFilter } from './task-detail-state'

function kindIcon(kind: TraceEventKind): string {
  switch (kind) {
    case 'tool_call': return '\u2699'
    case 'broadcast': return '\u25B6'
    case 'task': return '\u2611'
    case 'heartbeat': return '\u2764'
    case 'lifecycle': return '\u21C4'
    default: return '\u00B7'
  }
}

function kindColor(kind: TraceEventKind): string {
  switch (kind) {
    case 'tool_call': return 'text-accent'
    case 'broadcast': return 'text-[#22d3ee]'
    case 'task': return 'text-ok'
    case 'heartbeat': return 'text-text-dim'
    case 'lifecycle': return 'text-text-muted'
    default: return 'text-text-muted'
  }
}

function durationColor(ms: number | undefined): string {
  if (ms == null) return ''
  if (ms < 500) return 'text-ok'
  if (ms < 2000) return 'text-warn'
  return 'text-bad'
}

function ActivityEntry({ event }: { event: UnifiedTraceEvent }) {
  const hasDetail = event.toolArgs != null || event.toolResult != null || (event.detail && Object.keys(event.detail).length > 0)

  if (!hasDetail) {
    return html`
      <div class="flex items-center gap-3 py-1.5 px-3 rounded-lg hover:bg-[var(--white-3)] transition-colors">
        <span class="text-[13px] ${kindColor(event.kind)}">${kindIcon(event.kind)}</span>
        <span class="flex-1 text-[12px] text-text-body truncate">${event.summary}</span>
        ${event.duration_ms != null ? html`<span class="text-[10px] tabular-nums ${durationColor(event.duration_ms)}">${event.duration_ms}ms</span>` : null}
        ${event.ts_iso ? html`<${TimeAgo} timestamp=${event.ts_iso} class="text-[10px] text-text-dim shrink-0" />` : null}
      </div>
    `
  }

  return html`
    <details class="rounded-lg hover:bg-[var(--white-3)] transition-colors">
      <summary class="flex items-center gap-3 py-1.5 px-3 cursor-pointer list-none [&::-webkit-details-marker]:hidden">
        <span class="text-[13px] ${kindColor(event.kind)}">${kindIcon(event.kind)}</span>
        <span class="flex-1 text-[12px] text-text-body truncate">${event.summary}</span>
        ${event.duration_ms != null ? html`<span class="text-[10px] tabular-nums ${durationColor(event.duration_ms)}">${event.duration_ms}ms</span>` : null}
        ${event.ts_iso ? html`<${TimeAgo} timestamp=${event.ts_iso} class="text-[10px] text-text-dim shrink-0" />` : null}
        <span class="text-[10px] text-text-dim">\u25B8</span>
      </summary>
      <div class="px-3 pb-2 pt-1 ml-7">
        ${event.toolArgs != null ? html`
          <div class="mb-1">
            <div class="text-[10px] text-text-dim mb-0.5">args</div>
            <pre class="text-[11px] text-text-body whitespace-pre-wrap break-all bg-[var(--white-3)] rounded p-2 max-h-[200px] overflow-y-auto">${typeof event.toolArgs === 'string' ? event.toolArgs : JSON.stringify(event.toolArgs, null, 2)}</pre>
          </div>
        ` : null}
        ${event.toolResult != null ? html`
          <div>
            <div class="text-[10px] text-text-dim mb-0.5">result</div>
            <pre class="text-[11px] text-text-body whitespace-pre-wrap break-all bg-[var(--white-3)] rounded p-2 max-h-[200px] overflow-y-auto">${typeof event.toolResult === 'string' ? event.toolResult : JSON.stringify(event.toolResult, null, 2)}</pre>
          </div>
        ` : null}
        ${event.error ? html`<div class="text-[11px] text-bad mt-1">${event.error}</div>` : null}
        ${event.cost_usd != null ? html`<div class="text-[10px] text-text-dim mt-1">cost: $${event.cost_usd.toFixed(4)}</div>` : null}
      </div>
    </details>
  `
}

export function TaskActivityList({
  events,
  loading,
  error,
  showToolCalls,
}: {
  events: UnifiedTraceEvent[]
  loading: boolean
  error: string | null
  showToolCalls: boolean
}) {
  if (loading) return html`<${LoadingState}>활동 불러오는 중...<//>`
  if (error) return html`<div class="text-[12px] text-bad py-2">${error}</div>`
  if (events.length === 0) return html`<${EmptyState} message="담당자의 최근 활동이 없습니다" compact />`

  const filter = activeFilter.value
  const filtered = filter === 'all'
    ? events
    : events.filter(e => e.kind === filter)

  const filterChips: { key: ActivityFilter; label: string }[] = [
    { key: 'all', label: '전체' },
    ...(showToolCalls ? [{ key: 'tool_call' as const, label: '도구 호출' }] : []),
    { key: 'broadcast', label: '메시지' },
    { key: 'task', label: '태스크' },
  ]

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-1.5">
        ${filterChips.map(chip => html`
          <button
            key=${chip.key}
            type="button"
            class="px-2 py-1 rounded-md text-[11px] font-medium border cursor-pointer transition-colors ${
              filter === chip.key
                ? 'border-accent/40 bg-accent/12 text-[#9ad9ff]'
                : 'border-[var(--white-10)] bg-[var(--white-4)] text-text-muted hover:bg-[var(--white-8)]'
            }"
            onClick=${() => { activeFilter.value = chip.key }}
          >${chip.label}</button>
        `)}
        <span class="ml-auto text-[10px] text-text-dim tabular-nums">${filtered.length}건</span>
      </div>
      <div class="flex flex-col gap-0.5 max-h-[400px] overflow-y-auto">
        ${filtered.map((evt, i) => html`<${ActivityEntry} key=${evt.id ?? i} event=${evt} />`)}
      </div>
    </div>
  `
}
