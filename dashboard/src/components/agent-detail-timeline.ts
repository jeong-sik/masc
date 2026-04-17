// Agent detail timeline section — activity timeline with event summary
// Includes tool_call events from Activity Graph integration.

import { html } from 'htm/preact'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TimeAgo } from './common/time-ago'
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

function ToolCallEventRow({ evt, idx }: { evt: AgentTimelineEvent; idx: number }) {
  const d = evt.detail as Record<string, unknown>
  const toolName = (d.tool_name as string) ?? 'unknown'
  const success = d.success !== false
  const durationMs = d.duration_ms as number | undefined
  const errorMsg = d.error as string | null
  const args = d.args as Record<string, unknown> | string | undefined
  const cat = toolCategory(toolName)

  return html`
    <div class="flex flex-col py-1.5 px-2 rounded hover:bg-[var(--white-4)] transition-colors" key=${idx} style=${{ animation: 'activityFadeIn 0.25s ease-out' }}>
      <div class="flex items-center gap-2 text-[13px]">
        <div class="flex-shrink-0 size-6 rounded-md bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-[10px] font-mono font-bold ${cat.color}">
          ${cat.icon}
        </div>
        <span class="text-xs font-mono font-medium ${cat.color} truncate max-w-[200px]" title=${toolName}>${toolName}</span>
        <span class="text-[9px] px-1 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)]">${cat.label}</span>
        ${durationMs != null
          ? html`<span class="text-[11px] font-mono ${durationColor(durationMs)}">${formatDuration(durationMs)}</span>`
          : null}
        ${success
          ? html`<span class="text-[10px] px-1 py-0.5 rounded bg-[rgba(52,211,153,0.1)] text-[var(--ok)]">ok</span>`
          : html`<span class="text-[10px] px-1 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">err</span>`}
        <span class="flex-1"></span>
        ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
      </div>
      ${args ? html`
        <div class="ml-8 mt-0.5 text-[10px] text-[var(--text-dim)] font-mono truncate">
          ${typeof args === 'string' ? trimText(args, 60) : formatArgs(args)}
        </div>
      ` : null}
      ${errorMsg ? html`
        <div class="ml-8 mt-0.5 text-[10px] text-[var(--bad)] font-mono truncate" title=${errorMsg}>
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

  return html`
    <${Card} title="활동 타임라인 (${summary?.total_events ?? 0}건)">
      ${summary ? html`
        <div class="flex gap-1.5 flex-wrap mb-2">
          ${summary.tasks_completed > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-full">완료 ${summary.tasks_completed}</span>` : null}
          ${summary.tasks_claimed > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-full">수임 ${summary.tasks_claimed}</span>` : null}
          ${summary.messages_sent > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-full">메시지 ${summary.messages_sent}</span>` : null}
          ${(summary.tool_calls ?? 0) > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-full">도구 ${summary.tool_calls}</span>` : null}
          ${summary.active_duration_minutes > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-full">${Math.round(summary.active_duration_minutes)}분 활동</span>` : null}
        </div>
      ` : null}
      ${events.length === 0
        ? html`<${EmptyState} message="작업 기록이 아직 없습니다" compact />`
        : html`
            <div class="flex flex-col gap-0.5 max-h-[400px] overflow-y-auto">
              ${events.map((evt: AgentTimelineEvent, idx: number) => {
                if (evt.type === 'tool_call') {
                  return html`<${ToolCallEventRow} evt=${evt} idx=${idx} />`
                }
                const detail = evt.detail as Record<string, string | undefined>
                const title = detail.title ?? detail.content ?? ''
                return html`
                  <div class="agent-timeline-event flex items-baseline gap-1.5 py-1 px-2 text-[13px] transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${idx}>
                    <span class="agent-journal-kind">${timelineEventIcon(evt.type)}</span>
                    <span class="agent-timeline-type">${timelineEventLabel(evt.type)}</span>
                    ${title ? html`<span class="agent-timeline-detail">${trimText(title, 80)}</span>` : null}
                    ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
                  </div>
                `
              })}
            </div>
          `}
    <//>
  `
}
