// MASC Dashboard — Narrative Timeline (Phase 5)
// Replaces raw log-line ActivityTicker with grouped, narrative-style timeline.
// Groups events by time window and actor, synthesizes Korean descriptions.

import { html } from 'htm/preact'
import type { ReadonlySignal } from '@preact/signals'
import type { JournalEntry } from '../../types'

interface NarrativeTimelineProps {
  entries: ReadonlySignal<JournalEntry[]>
  maxItems?: number
}

interface TimeGroup {
  label: string
  events: NarrativeEvent[]
}

interface NarrativeEvent {
  actor: string | null
  text: string
  raw: string
  timestamp: number
}

function eventVerb(kind?: string, eventType?: string): string {
  const k = kind ?? ''
  const e = (eventType ?? '').toLowerCase()

  if (e.includes('claim')) return '태스크를 claim'
  if (e.includes('done') || e.includes('complete')) return '태스크를 완료'
  if (e.includes('join')) return 'room에 참여'
  if (e.includes('leave')) return 'room에서 퇴장'
  if (e.includes('broadcast')) return '메시지를 브로드캐스트'
  if (e.includes('heartbeat')) return '하트비트를 전송'
  if (e.includes('post') || e.includes('board')) return '게시글을 작성'
  if (e.includes('vote')) return '투표'
  if (e.includes('comment')) return '댓글을 작성'
  if (e.includes('spawn')) return '에이전트를 생성'
  if (e.includes('commit')) return '커밋을 생성'
  if (e.includes('pr') || e.includes('pull_request')) return 'PR을 처리'
  if (k === 'tasks') return '태스크를 처리'
  if (k === 'keepers') return '키퍼 활동'
  if (k === 'system') return '시스템 이벤트'

  return '활동'
}

function buildNarrative(entry: JournalEntry): NarrativeEvent {
  const actor = entry.agent ?? null
  const preview = entry.preview ?? entry.text
  const verb = eventVerb(entry.kind, entry.eventType)

  const actorPrefix = actor ? `${actor}가 ` : ''
  const text = preview
    ? `${actorPrefix}${verb}: ${preview}`
    : `${actorPrefix}${verb}.`

  return {
    actor,
    text,
    raw: `${entry.preview ?? entry.text}`,
    timestamp: entry.timestamp,
  }
}

function timeGroupLabel(deltaSec: number): string {
  if (deltaSec < 120) return '지금'
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}분 전`
  return `${Math.round(deltaSec / 3600)}시간 전`
}

function groupByTime(events: NarrativeEvent[]): TimeGroup[] {
  if (events.length === 0) return []

  const now = Date.now()
  const groups: TimeGroup[] = []
  let currentLabel = ''
  let currentEvents: NarrativeEvent[] = []

  for (const event of events) {
    const deltaSec = Math.max(0, (now - event.timestamp) / 1000)
    const label = timeGroupLabel(deltaSec)

    if (label !== currentLabel) {
      if (currentEvents.length > 0) {
        groups.push({ label: currentLabel, events: currentEvents })
      }
      currentLabel = label
      currentEvents = []
    }
    currentEvents.push(event)
  }

  if (currentEvents.length > 0) {
    groups.push({ label: currentLabel, events: currentEvents })
  }

  return groups
}

export function NarrativeTimeline({ entries, maxItems }: NarrativeTimelineProps) {
  const limit = maxItems ?? 12
  const raw = entries.value.slice(-limit).reverse()

  if (raw.length === 0) {
    return html`
      <div class="narrative-timeline">
        <div class="narrative-timeline__empty">이벤트 대기 중...</div>
      </div>
    `
  }

  const narratives = raw.map(buildNarrative)
  const groups = groupByTime(narratives)

  return html`
    <div class="narrative-timeline">
      ${groups.map(group => html`
        <div class="narrative-group" key=${group.label}>
          <div class="narrative-group__label">${group.label}</div>
          <div class="narrative-group__events">
            ${group.events.map(event => html`
              <div class="narrative-event" key=${event.timestamp}>
                <span class="narrative-event__text">${event.text}</span>
                <details class="narrative-event__raw">
                  <summary>원본</summary>
                  <span>${event.raw}</span>
                </details>
              </div>
            `)}
          </div>
        </div>
      `)}
    </div>
  `
}
