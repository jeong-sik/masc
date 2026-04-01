// Agent detail timeline section — activity timeline with event summary

import { html } from 'htm/preact'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TimeAgo } from './common/time-ago'
import { agentTimeline } from './agent-detail-state'
import { trimText } from '../lib/truncate'
import type { AgentTimelineEvent } from '../api'

function timelineEventIcon(type: string): string {
  if (type === 'joined') return 'J'
  if (type.startsWith('task_')) return 'T'
  if (type === 'broadcast') return 'M'
  return 'E'
}

function timelineEventLabel(type: string): string {
  switch (type) {
    case 'joined': return '참가'
    case 'task_claimed': return '태스크 수임'
    case 'task_started': return '태스크 시작'
    case 'task_completed': return '태스크 완료'
    case 'task_cancelled': return '태스크 취소'
    case 'broadcast': return '공지'
    default: return type
  }
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
          ${summary.tasks_completed > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">완료 ${summary.tasks_completed}</span>` : null}
          ${summary.tasks_claimed > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">수임 ${summary.tasks_claimed}</span>` : null}
          ${summary.messages_sent > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">메시지 ${summary.messages_sent}</span>` : null}
          ${summary.active_duration_minutes > 0 ? html`<span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${Math.round(summary.active_duration_minutes)}분 활동</span>` : null}
        </div>
      ` : null}
      ${events.length === 0
        ? html`<${EmptyState} message="작업 기록이 아직 없습니다" compact />`
        : html`
            <div class="flex flex-col gap-0.5 max-h-[300px] overflow-y-auto">
              ${events.map((evt: AgentTimelineEvent, idx: number) => {
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
