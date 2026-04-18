// MASC Dashboard — Narrative Timeline
// Grouped event feed with timestamps and actor attribution.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { ReadonlySignal } from '@preact/signals'
import { formatTimeOnly } from '../../lib/format-time'
import type { JournalEntry } from '../../types'

interface NarrativeTimelineProps {
  entries: ReadonlySignal<JournalEntry[]>
  maxItems?: number
}

const expandedItems = signal(0)

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

function buildNarrative(entry: JournalEntry): NarrativeEvent {
  const actor = entry.agent ?? null
  const text = entry.narrativeText ?? entry.preview ?? entry.text

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

// Delegated to lib/format-time (SSOT)
const formatTimestamp = formatTimeOnly

export function NarrativeTimeline({ entries, maxItems }: NarrativeTimelineProps) {
  const baseLimit = maxItems ?? 8
  const limit = baseLimit + expandedItems.value
  const totalAvailable = entries.value.length
  const raw = entries.value.slice(0, limit)

  if (raw.length === 0) {
    return html`
      <div class="flex flex-col items-center gap-2 py-8 text-center">
        <div class="text-[var(--text-muted)] text-sm">이벤트 대기 중</div>
        <div class="text-[var(--text-muted)] text-xs leading-relaxed max-w-[360px]">에이전트가 활동을 시작하면 시간순으로 여기에 표시됩니다. 연결이 끊겨있으면 라이브 모니터 탭에서 확인하세요.</div>
      </div>
    `
  }

  const narratives = raw.map(buildNarrative)
  const groups = groupByTime(narratives)
  const hasMore = totalAvailable > limit

  return html`
    <div class="flex flex-col gap-3">
      ${groups.map(group => html`
        <div class="flex flex-col gap-0" key=${group.label}>
          <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider pb-1.5 mb-1 border-b border-[var(--white-6)]">${group.label}</div>
          <div class="flex flex-col">
            ${group.events.map(event => html`
              <div class="flex items-start gap-3 py-1.5 group" key=${event.timestamp}>
                <span class="text-[10px] text-[var(--text-muted)] tabular-nums shrink-0 mt-0.5 w-8">${formatTimestamp(event.timestamp)}</span>
                <div class="w-1.5 h-1.5 rounded-full bg-[var(--card-border)] shrink-0 mt-1.5"></div>
                <div class="flex-1 min-w-0">
                  ${event.actor ? html`<span class="text-xs font-medium text-[var(--accent)] mr-1.5">${event.actor}</span>` : null}
                  <span class="text-xs text-[var(--text-body)] leading-relaxed">${event.text}</span>
                </div>
              </div>
            `)}
          </div>
        </div>
      `)}
      ${hasMore ? html`
        <button type="button"
          class="w-full py-2 bg-transparent border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-xs cursor-pointer text-center rounded hover:border-[var(--accent)] hover:text-[var(--accent)] transition-colors"
          onClick=${() => { expandedItems.value += baseLimit }}
        >
          더 보기 (${totalAvailable - limit}건 남음)
        </button>
      ` : null}
    </div>
  `
}
