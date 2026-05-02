// Agent detail timeline section — activity timeline with event summary
// Includes tool_call events from Activity Graph integration.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TimeAgo } from './common/time-ago'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { agentTimeline } from './agent-detail-state'
import { trimText } from '../lib/truncate'
import { toolCategory, durationColor, formatDuration, formatArgs } from './tool-call-shared'
import type { AgentTimelineEvent } from '../api'

export function timelineEventIcon(type: string): string {
  if (type === 'joined') return 'J'
  if (type.startsWith('task_')) return 'T'
  if (type === 'broadcast') return 'M'
  if (type === 'tool_call') return 'W'
  return 'E'
}

export function timelineEventLabel(type: string): string {
  switch (type) {
    case 'joined': return '참가'
    case 'task_claimed': return '태스크 수임'
    case 'task_started': return '태스크 시작'
    case 'task_completed': return '태스크 완료'
    case 'task_cancelled': return '태스크 취소'
    case 'broadcast': return '공지'
    case 'tool_call': return '도구 호출'
    default: return type
  }
}

function SummaryBadge({ children }: { children: unknown }) {
  return html`
    <span class="text-3xs py-0.5 px-2 border border-solid border-[var(--accent-36)] bg-[var(--accent-12)] text-[var(--color-accent-fg)] whitespace-nowrap rounded-[var(--r-0)]">${children}</span>
  `
}

// ── Event categorization & filter (pure) ──────────────────────────
// Used for FilterChips grouping and filtering. Categories are
// deliberately coarse so chips stay compact even as new event types
// are added server-side.

type TimelineEventCategory = 'all' | 'task' | 'tool_call' | 'broadcast' | 'joined' | 'other'

export function timelineEventCategory(type: string): Exclude<TimelineEventCategory, 'all'> {
  if (type.startsWith('task_')) return 'task'
  if (type === 'tool_call') return 'tool_call'
  if (type === 'broadcast') return 'broadcast'
  if (type === 'joined') return 'joined'
  return 'other'
}

export function timelineEventSearchText(evt: AgentTimelineEvent): string {
  const parts: string[] = [evt.type, timelineEventLabel(evt.type)]
  const d = evt.detail as Record<string, unknown> | undefined
  if (d && typeof d === 'object') {
    for (const key of ['title', 'content', 'tool_name', 'error']) {
      const v = d[key]
      if (typeof v === 'string' && v.length > 0) parts.push(v)
    }
  }
  return parts.join(' ').toLowerCase()
}

export function filterTimelineEvents(
  events: AgentTimelineEvent[],
  category: TimelineEventCategory,
  query: string,
): AgentTimelineEvent[] {
  const q = query.trim().toLowerCase()
  if (category === 'all' && q === '') return events
  return events.filter(evt => {
    if (category !== 'all' && timelineEventCategory(evt.type) !== category) return false
    if (q !== '' && !timelineEventSearchText(evt).includes(q)) return false
    return true
  })
}

export function timelineCategoryCounts(
  events: AgentTimelineEvent[],
): Record<Exclude<TimelineEventCategory, 'all'>, number> {
  const counts = { task: 0, tool_call: 0, broadcast: 0, joined: 0, other: 0 }
  for (const evt of events) counts[timelineEventCategory(evt.type)]++
  return counts
}

const timelineCategoryFilter = signal<TimelineEventCategory>('all')
const timelineSearchQuery = signal('')

function ToolCallEventRow({ evt, idx }: { evt: AgentTimelineEvent; idx: number }) {
  const d = evt.detail as Record<string, unknown>
  const toolName = (d.tool_name as string) ?? 'unknown'
  const success = d.success !== false
  const durationMs = d.duration_ms as number | undefined
  const errorMsg = d.error as string | null
  const args = d.args as Record<string, unknown> | string | undefined
  const cat = toolCategory(toolName)

  return html`
    <div class="flex flex-col py-1.5 px-2 rounded-[var(--r-1)] hover:bg-[var(--color-bg-elevated)] transition-colors" key=${idx} style=${{ animation: 'activityFadeIn 0.25s ease-out' }}>
      <div class="flex items-center gap-2 text-sm">
        <div class="flex-shrink-0 size-6 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] flex items-center justify-center text-3xs font-mono font-bold ${cat.color}">
          ${cat.icon}
        </div>
        <span class="text-xs font-mono font-medium ${cat.color} truncate max-w-50" title=${toolName}>${toolName}</span>
        <span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)]">${cat.label}</span>
        ${durationMs != null
          ? html`<span class="text-2xs font-mono ${durationColor(durationMs)}">${formatDuration(durationMs)}</span>`
          : null}
        ${success
          ? html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]">ok</span>`
          : html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--bad-10)] text-[var(--color-status-err)]">err</span>`}
        <span class="flex-1"></span>
        ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
      </div>
      ${args ? html`
        <div class="ml-8 mt-0.5 text-3xs text-[var(--color-fg-disabled)] font-mono truncate">
          ${typeof args === 'string' ? trimText(args, 60) : formatArgs(args)}
        </div>
      ` : null}
      ${errorMsg ? html`
        <div class="ml-8 mt-0.5 text-3xs text-[var(--color-status-err)] font-mono truncate" title=${errorMsg}>
          ${trimText(errorMsg, 60)}
        </div>
      ` : null}
    </div>
  `
}

export function AgentTimelineSection() {
  const timeline = agentTimeline.value
  if (!timeline) return null

  const events = timeline.events ?? []
  const summary = timeline.summary
  const counts = timelineCategoryCounts(events)
  const activeCategory = timelineCategoryFilter.value
  const query = timelineSearchQuery.value
  const filtered = filterTimelineEvents(events, activeCategory, query)
  const filterActive = activeCategory !== 'all' || query.trim() !== ''

  return html`
    <${Card} title="활동 타임라인 (${summary?.total_events ?? 0}건)">
      ${summary ? html`
        <div class="flex gap-1.5 flex-wrap mb-2">
          ${summary.tasks_completed > 0 ? html`<${SummaryBadge}>완료 ${summary.tasks_completed}<//>` : null}
          ${summary.tasks_claimed > 0 ? html`<${SummaryBadge}>수임 ${summary.tasks_claimed}<//>` : null}
          ${summary.messages_sent > 0 ? html`<${SummaryBadge}>메시지 ${summary.messages_sent}<//>` : null}
          ${(summary.tool_calls ?? 0) > 0 ? html`<${SummaryBadge}>도구 ${summary.tool_calls}<//>` : null}
          ${summary.active_duration_minutes > 0 ? html`<${SummaryBadge}>${Math.round(summary.active_duration_minutes)}분 활동<//>` : null}
        </div>
      ` : null}
      ${events.length === 0
        ? html`<${EmptyState} message="작업 기록이 아직 없습니다" compact />`
        : html`
            <div class="flex flex-wrap gap-2 items-center mb-2">
              <${FilterChips}
                chips=${[
                  { key: 'all' as TimelineEventCategory, label: '전체', count: events.length },
                  { key: 'task' as TimelineEventCategory, label: '태스크', count: counts.task },
                  { key: 'tool_call' as TimelineEventCategory, label: '도구', count: counts.tool_call },
                  { key: 'broadcast' as TimelineEventCategory, label: '공지', count: counts.broadcast },
                  { key: 'joined' as TimelineEventCategory, label: '참가', count: counts.joined },
                  { key: 'other' as TimelineEventCategory, label: '기타', count: counts.other },
                ]}
                active=${timelineCategoryFilter}
                size="sm"
                tone="accent"
              />
              <${TextInput}
                class="max-w-55"
                name="agent_timeline_search"
                ariaLabel="타임라인 검색"
                autoComplete="off"
                placeholder="내용·도구 검색..."
                value=${query}
                onInput=${(e: Event) => { timelineSearchQuery.value = (e.target as HTMLInputElement).value }}
              />
              ${filterActive
                ? html`<span class="text-3xs text-[var(--color-fg-disabled)] tabular-nums">${filtered.length} / ${events.length}</span>`
                : null}
            </div>
            ${filtered.length === 0
              ? html`<${EmptyState} message="조건에 맞는 이벤트가 없습니다" compact />`
              : html`
                  <div role="log" aria-label="활동 타임라인" class="flex flex-col gap-0.5 max-h-100 overflow-y-auto">
                    ${filtered.map((evt: AgentTimelineEvent, idx: number) => {
                      if (evt.type === 'tool_call') {
                        return html`<${ToolCallEventRow} evt=${evt} idx=${idx} />`
                      }
                      const detail = evt.detail as Record<string, string | undefined>
                      const title = detail.title ?? detail.content ?? ''
                      return html`
                        <div class="agent-timeline-event flex items-baseline gap-1.5 py-1 px-2 text-sm transition-[background] duration-[var(--t-fast)] rounded-[var(--r-1)] hover:bg-[var(--color-bg-elevated)]" key=${idx}>
                          <span class="agent-journal-kind">${timelineEventIcon(evt.type)}</span>
                          <span class="agent-timeline-type">${timelineEventLabel(evt.type)}</span>
                          ${title ? html`<span class="agent-timeline-detail">${trimText(title, 80)}</span>` : null}
                          ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
                        </div>
                      `
                    })}
                  </div>
                `}
          `}
    <//>
  `
}
