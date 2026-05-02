// Agent session report — GitHub Agents–style activity view
// Renders broadcast messages as full markdown cards, shows task summary, agent meta info

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { Markdown } from './common/markdown'
import { TextInput } from './common/input'
import { ringFocusClasses } from './common/ring'
import {
  agentTimeline,
  selectedAgent,
  missionAgentBrief,
  continuityBriefForAgent,
  keeperForAgent,
} from './agent-detail-state'
import type { AgentTimelineEvent } from '../api'

// ── Helpers (exported for testing) ───────────────

/** Safely read a string field from evt.detail (typed as Record<string, unknown>) */
function detailStr(detail: Record<string, unknown>, key: string): string {
  const val = detail[key]
  return typeof val === 'string' ? val : ''
}

/** Extract broadcast events with meaningful content from timeline */
export function extractBroadcasts(events: AgentTimelineEvent[]): AgentTimelineEvent[] {
  return events
    .filter(evt => evt.type === 'broadcast')
    .filter(evt => {
      const content = detailStr(evt.detail, 'content')
      // Skip trivial heartbeat-like messages
      return content.length > 20
    })
}

/** Extract task-related events from timeline */
export function extractTaskEvents(events: AgentTimelineEvent[]): AgentTimelineEvent[] {
  return events.filter(evt => evt.type.startsWith('task_'))
}

/** Group consecutive broadcasts that are part of the same report.
 *  Broadcasts within 60 seconds of each other (compared to the previous event,
 *  not the group start) are merged into one report card. */
export function groupBroadcastsIntoReports(
  broadcasts: AgentTimelineEvent[],
): { ts: string; content: string }[] {
  if (broadcasts.length === 0) return []

  const reports: { ts: string; parts: string[] }[] = []
  let current: { ts: string; parts: string[] } | null = null
  let prevTs: string | null = null

  for (const evt of broadcasts) {
    const content = detailStr(evt.detail, 'content')
    const ts = evt.ts

    if (current && prevTs) {
      const prevTime = new Date(prevTs).getTime()
      const curTime = new Date(ts).getTime()
      const gapSec = (curTime - prevTime) / 1000
      if (gapSec >= 0 && gapSec < 60) {
        current.parts.push(content)
        prevTs = ts
        continue
      }
    }

    current = { ts, parts: [content] }
    reports.push(current)
    prevTs = ts
  }

  return reports.map(r => ({
    ts: r.ts,
    content: r.parts.join('\n\n---\n\n'),
  }))
}

/** Case-insensitive substring match on report content. Empty query returns all. */
export function filterReportsByQuery(
  reports: { ts: string; content: string }[],
  query: string,
): { ts: string; content: string }[] {
  const q = query.trim().toLowerCase()
  if (q === '') return reports
  return reports.filter(r => r.content.toLowerCase().includes(q))
}

/** Case-insensitive substring match on task event title/task_id. Empty query returns all. */
export function filterTaskEventsByQuery(
  events: AgentTimelineEvent[],
  query: string,
): AgentTimelineEvent[] {
  const q = query.trim().toLowerCase()
  if (q === '') return events
  return events.filter(evt => {
    const title = detailStr(evt.detail, 'title')
    const taskId = detailStr(evt.detail, 'task_id')
    return (
      title.toLowerCase().includes(q)
      || taskId.toLowerCase().includes(q)
      || evt.type.toLowerCase().includes(q)
    )
  })
}

function taskEventIcon(type: string): string {
  switch (type) {
    case 'task_completed': return 'done'
    case 'task_claimed': return 'claim'
    case 'task_started': return 'start'
    case 'task_cancelled': return 'cancel'
    default: return type.replace('task_', '')
  }
}

function taskEventColor(type: string): string {
  switch (type) {
    case 'task_completed': return 'text-ok'
    case 'task_cancelled': return 'text-bad'
    default: return 'text-accent'
  }
}

// ── Components ───────────────────────────────────

function SessionMeta({ agentName }: { agentName: string }) {
  const agent = selectedAgent()
  const brief = missionAgentBrief(agentName)
  const continuity = continuityBriefForAgent(agentName)
  const keeper = keeperForAgent(agentName)
  const timeline = agentTimeline.value

  const meta: { label: string; value: string }[] = []

  if (brief?.where) {
    meta.push({ label: '위치', value: brief.where })
  }

  if (brief?.related_session_id) {
    meta.push({ label: '세션', value: brief.related_session_id })
  }

  if (agent?.model) {
    meta.push({ label: '모델', value: agent.model })
  }

  if (timeline?.summary?.active_duration_minutes) {
    const mins = Math.round(timeline.summary.active_duration_minutes)
    meta.push({ label: '활동 시간', value: `${mins}분` })
  }

  if (keeper?.name) {
    meta.push({ label: '키퍼', value: keeper.name })
  }

  if (brief?.current_work) {
    meta.push({ label: '현재 작업', value: brief.current_work })
  }

  if (continuity?.continuity_summary) {
    meta.push({ label: '연속성', value: continuity.continuity_summary })
  }

  if (meta.length === 0) return null

  return html`
    <div class="flex flex-wrap gap-2 mb-4">
      ${meta.map(m => html`
        <span key=${m.label} class="inline-flex items-center gap-1.5 text-2xs font-medium py-1 px-2.5 bg-[var(--white-5)] border border-[var(--white-10)] rounded-[var(--r-1)] text-text-muted">
          <span class="text-text-dim">${m.label}</span>
          <span class="text-text-strong font-mono text-3xs">${m.value}</span>
        </span>
      `)}
    </div>
  `
}

function TaskEventTimeline({ events }: { events: AgentTimelineEvent[] }) {
  if (events.length === 0) return null

  return html`
    <div class="mt-4">
      <div class="text-2xs font-semibold uppercase tracking-wider text-text-muted mb-2">태스크 이력</div>
      <div class="flex flex-col gap-1">
        ${events.map((evt, idx) => {
          const title = detailStr(evt.detail, 'title') || detailStr(evt.detail, 'task_id')
          const icon = taskEventIcon(evt.type)
          const color = taskEventColor(evt.type)
          return html`
            <div key=${idx} class="flex items-center gap-2 py-1.5 px-3 rounded hover:bg-[var(--white-3)] transition-colors">
              <span class="text-3xs font-bold uppercase tracking-wider ${color} bg-[var(--white-5)] px-2 py-0.5 rounded">${icon}</span>
              <span class="text-xs text-text-body flex-1 truncate">${title}</span>
              ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
            </div>
          `
        })}
      </div>
    </div>
  `
}

function BroadcastReport({ report, index }: { report: { ts: string; content: string }; index: number }) {
  const [expanded, setExpanded] = useState(index === 0) // first one expanded by default

  // For long reports, show a preview when collapsed
  const isLong = report.content.length > 400
  const preview = isLong && !expanded
    ? report.content.slice(0, 300) + '...'
    : report.content

  return html`
    <div class="border border-card-border/60 rounded-[var(--r-1)] bg-card/30 overflow-hidden hover:border-accent/20 transition-colors">
      <button
        type="button"
        class=${`w-full flex items-center justify-between px-4 py-2.5 bg-[var(--white-3)] border-b border-card-border/40 cursor-pointer select-none text-left ${ringFocusClasses()}`}
        onClick=${() => setExpanded(!expanded)}
        aria-expanded=${expanded}
      >
        <div class="flex items-center gap-2">
          <span class="size-2 rounded-sm ${index === 0 ? 'bg-accent' : 'bg-[var(--white-20)]'}"></span>
          <${TimeAgo} timestamp=${report.ts} />
        </div>
        ${isLong ? html`
          <span class="text-3xs text-text-dim font-medium">
            ${expanded ? '접기' : '펼치기'}
          </span>
        ` : null}
      </button>
      <div class="px-4 py-3 text-sm leading-relaxed">
        <${Markdown} text=${expanded || !isLong ? report.content : preview} />
      </div>
    </div>
  `
}

// ── Main Export ───────────────────────────────────

export function AgentSessionReport({ agentName }: { agentName: string }) {
  const [query, setQuery] = useState('')

  const timeline = agentTimeline.value
  if (!timeline) return null

  const events = timeline.events ?? []
  const broadcasts = extractBroadcasts(events)
  const taskEvents = extractTaskEvents(events)
  const reports = groupBroadcastsIntoReports(broadcasts)
  const summary = timeline.summary

  // Don't show this section if there's no meaningful content
  if (reports.length === 0 && taskEvents.length === 0) return null

  const filteredReports = filterReportsByQuery(reports, query)
  const filteredTaskEvents = filterTaskEventsByQuery(taskEvents, query)
  const totalItems = reports.length + taskEvents.length
  const filteredItems = filteredReports.length + filteredTaskEvents.length
  const showSearch = totalItems >= 5
  const hasQuery = query.trim() !== ''

  return html`
    <${Card} title="세션 활동 리포트" class="mb-5">
      <${SessionMeta} agentName=${agentName} />

      ${summary ? html`
        <div class="flex gap-3 flex-wrap mb-4">
          ${summary.tasks_completed > 0 ? html`
            <div class="flex items-center gap-1.5 text-xs font-medium text-ok bg-ok/10 border border-ok/20 px-3 py-1.5 rounded-[var(--r-1)]">
              <span class="font-bold">${summary.tasks_completed}</span> 완료
            </div>
          ` : null}
          ${summary.tasks_claimed > 0 ? html`
            <div class="flex items-center gap-1.5 text-xs font-medium text-accent bg-[var(--accent-10)] border border-accent/20 px-3 py-1.5 rounded-[var(--r-1)]">
              <span class="font-bold">${summary.tasks_claimed}</span> 수임
            </div>
          ` : null}
          ${summary.messages_sent > 0 ? html`
            <div class="flex items-center gap-1.5 text-xs font-medium text-text-muted bg-[var(--white-5)] border border-[var(--white-10)] px-3 py-1.5 rounded-[var(--r-1)]">
              <span class="font-bold">${summary.messages_sent}</span> 메시지
            </div>
          ` : null}
        </div>
      ` : null}

      ${showSearch ? html`
        <div class="mb-4 flex items-center gap-2">
          <${TextInput}
            value=${query}
            placeholder="리포트/태스크 검색..."
            ariaLabel="세션 리포트 검색"
            class="max-w-90"
            onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          />
          ${hasQuery ? html`
            <span class="text-2xs text-text-muted whitespace-nowrap">
              ${filteredItems} / ${totalItems}
            </span>
          ` : null}
        </div>
      ` : null}

      ${filteredReports.length > 0 ? html`
        <div class="flex flex-col gap-3">
          ${filteredReports.map((report, idx) => html`
            <${BroadcastReport} key=${report.ts} report=${report} index=${idx} />
          `)}
        </div>
      ` : hasQuery && reports.length > 0 ? html`
        <div class="text-xs text-text-muted py-3">검색 결과 없음 (리포트)</div>
      ` : null}

      <${TaskEventTimeline} events=${filteredTaskEvents} />

      ${hasQuery && filteredTaskEvents.length === 0 && taskEvents.length > 0 ? html`
        <div class="text-xs text-text-muted py-2">검색 결과 없음 (태스크)</div>
      ` : null}
    <//>
  `
}
