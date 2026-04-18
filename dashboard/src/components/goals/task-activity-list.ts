// Task activity list — renders UnifiedTraceEvent[] with collapsible entries.
// Independent from global traceSlots (avoids keeper-detail overlay collision).

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { EmptyState } from '../common/empty-state'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { TimeAgo } from '../common/time-ago'
import { TextInput } from '../common/input'
import { JsonViewerCard, parseJsonLikeData } from '../common/json-viewer'
import { Settings, MessageSquare, CheckSquare, Heart, RefreshCcw, Dot, ChevronRight } from 'lucide-preact'
import type { UnifiedTraceEvent, TraceEventKind } from '../session-trace/session-trace-state'
import { activeFilter, activityListSearchQuery, type ActivityFilter } from './task-detail-state'

// Pure helper — filter events by categorical kind + free-text query.
// Query matches summary, toolName, error, and stringified toolArgs/toolResult (case-insensitive).
export function filterActivityEvents(
  events: UnifiedTraceEvent[],
  filter: ActivityFilter,
  query: string,
): UnifiedTraceEvent[] {
  const byKind = filter === 'all' ? events : events.filter(e => e.kind === filter)
  const q = query.trim().toLowerCase()
  if (q === '') return byKind
  return byKind.filter(e => {
    if (e.summary.toLowerCase().includes(q)) return true
    if (e.toolName && e.toolName.toLowerCase().includes(q)) return true
    if (e.error && e.error.toLowerCase().includes(q)) return true
    if (e.toolArgs != null) {
      const s = typeof e.toolArgs === 'string' ? e.toolArgs : JSON.stringify(e.toolArgs)
      if (s.toLowerCase().includes(q)) return true
    }
    if (e.toolResult != null && e.toolResult.toLowerCase().includes(q)) return true
    return false
  })
}

function kindIcon(kind: TraceEventKind) {
  switch (kind) {
    case 'tool_call': return html`<${Settings} size=${14} aria-hidden="true" focusable="false" />`
    case 'broadcast': return html`<${MessageSquare} size=${14} aria-hidden="true" focusable="false" />`
    case 'task': return html`<${CheckSquare} size=${14} aria-hidden="true" focusable="false" />`
    case 'heartbeat': return html`<${Heart} size=${14} aria-hidden="true" focusable="false" />`
    case 'lifecycle': return html`<${RefreshCcw} size=${14} aria-hidden="true" focusable="false" />`
    default: return html`<${Dot} size=${14} aria-hidden="true" focusable="false" />`
  }
}

function kindColor(kind: TraceEventKind): string {
  switch (kind) {
    case 'tool_call': return 'text-accent'
    case 'broadcast': return 'text-[var(--cyan)]'
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
  const [isOpen, setIsOpen] = useState(false)

  if (!hasDetail) {
    return html`
      <div class="flex items-center gap-3 py-1.5 px-3 rounded hover:bg-[var(--white-3)] transition-colors">
        <span class="text-sm ${kindColor(event.kind)}">${kindIcon(event.kind)}</span>
        <span class="flex-1 text-xs text-text-body truncate">${event.summary}</span>
        ${event.duration_ms != null ? html`<span class="text-3xs tabular-nums ${durationColor(event.duration_ms)}">${event.duration_ms}ms</span>` : null}
        ${event.ts_iso ? html`<${TimeAgo} timestamp=${event.ts_iso} class="text-3xs text-text-dim shrink-0" />` : null}
      </div>
    `
  }

  return html`
    <details
      class="rounded hover:bg-[var(--white-3)] transition-colors"
      onToggle=${(evt: Event) => {
        setIsOpen((evt.currentTarget as HTMLDetailsElement).open)
      }}
    >
      <summary class="flex items-center gap-3 py-1.5 px-3 cursor-pointer list-none [&::-webkit-details-marker]:hidden">
        <span class="text-sm ${kindColor(event.kind)}">${kindIcon(event.kind)}</span>
        <span class="flex-1 text-xs text-text-body truncate">${event.summary}</span>
        ${event.duration_ms != null ? html`<span class="text-3xs tabular-nums ${durationColor(event.duration_ms)}">${event.duration_ms}ms</span>` : null}
        ${event.ts_iso ? html`<${TimeAgo} timestamp=${event.ts_iso} class="text-3xs text-text-dim shrink-0" />` : null}
        <span class="text-3xs text-text-dim flex items-center justify-center"><${ChevronRight} size=${14} aria-hidden="true" focusable="false" /></span>
      </summary>
      ${isOpen ? html`
        <div class="px-3 pb-2 pt-1 ml-7">
          ${event.toolArgs != null ? html`
            <div class="mb-1">
              <${JsonViewerCard} data=${parseJsonLikeData(event.toolArgs)} title="Args" />
            </div>
          ` : null}
          ${event.toolResult != null ? html`
            <div class="mb-1">
              <${JsonViewerCard} data=${parseJsonLikeData(event.toolResult)} title="Result" />
            </div>
          ` : null}
          ${event.toolArgs == null && event.toolResult == null && event.detail && Object.keys(event.detail).length > 0 ? html`
            <div class="mb-1">
              <${JsonViewerCard} data=${event.detail} title="Detail" />
            </div>
          ` : null}
          ${event.error ? html`<div class="text-2xs text-[var(--bad-light)] mt-1">${event.error}</div>` : null}
          ${event.cost_usd != null ? html`<div class="text-3xs text-text-dim mt-1">cost: $${event.cost_usd.toFixed(4)}</div>` : null}
        </div>
      ` : null}
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
  if (error) return html`<${ErrorState} message=${error} />`
  if (events.length === 0) return html`<${EmptyState} message="담당자의 최근 활동이 없습니다" compact />`

  const filter = activeFilter.value
  const query = activityListSearchQuery.value
  const filtered = filterActivityEvents(events, filter, query)

  const filterChips: { key: ActivityFilter; label: string }[] = [
    { key: 'all', label: '전체' },
    ...(showToolCalls ? [{ key: 'tool_call' as const, label: '도구 호출' }] : []),
    { key: 'broadcast', label: '메시지' },
    { key: 'task', label: '태스크' },
  ]

  return html`
    <div class="flex flex-col gap-2">
      <${TextInput}
        type="search"
        value=${query}
        placeholder="활동 검색 (summary, tool, error)"
        ariaLabel="활동 검색"
        onInput=${(e: Event) => {
          activityListSearchQuery.value = (e.currentTarget as HTMLInputElement).value
        }}
      />
      <div class="flex items-center gap-1.5">
        ${filterChips.map(chip => html`
          <button
            key=${chip.key}
            type="button"
            class="px-2 py-1 rounded text-2xs font-medium border cursor-pointer transition-colors ${
              filter === chip.key
                ? 'border-accent/40 bg-accent/12 text-[var(--accent)]'
                : 'border-[var(--white-10)] bg-[var(--white-4)] text-text-muted hover:bg-[var(--white-8)]'
            }"
            onClick=${() => { activeFilter.value = chip.key }}
          >${chip.label}</button>
        `)}
        <span class="ml-auto text-3xs text-text-dim tabular-nums">${filtered.length}건</span>
      </div>
      <div class="flex flex-col gap-0.5 max-h-100 overflow-y-auto">
        ${filtered.map((evt, i) => {
          const stable = evt.id ?? evt.ts_iso ?? evt.summary
          return html`<${ActivityEntry} key=${`${stable}-${i}`} event=${evt} />`
        })}
      </div>
    </div>
  `
}
