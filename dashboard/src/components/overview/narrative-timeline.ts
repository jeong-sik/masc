// MASC Dashboard — Narrative Timeline (Phase 5)
// Replaces raw log-line ActivityTicker with grouped, narrative-style timeline.
// Groups events by time window and actor, synthesizes Korean descriptions.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { ReadonlySignal } from '@preact/signals'
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

export function NarrativeTimeline({ entries, maxItems }: NarrativeTimelineProps) {
  const baseLimit = maxItems ?? 8
  const limit = baseLimit + expandedItems.value
  const totalAvailable = entries.value.length
  const raw = entries.value.slice(-limit).reverse()

  if (raw.length === 0) {
    return html`
      <div class="narrative-timeline">
        <div class="text-text-muted text-center p-3 text-sm">이벤트 대기 중...</div>
      </div>
    `
  }

  const narratives = raw.map(buildNarrative)
  const groups = groupByTime(narratives)
  const hasMore = totalAvailable > limit

  return html`
    <div class="narrative-timeline">
      ${groups.map(group => html`
        <div class="flex flex-col gap-1" key=${group.label}>
          <div class="narrative-group__label">${group.label}</div>
          <div class="flex flex-col gap-0.5">
            ${group.events.map(event => html`
              <div class="py-1" key=${event.timestamp}>
                <span class="text-text-body text-sm leading-[1.45]">${event.text}</span>
                <details class="narrative-event__raw mt-0.5">
                  <summary>원본</summary>
                  <span>${event.raw}</span>
                </details>
              </div>
            `)}
          </div>
        </div>
      `)}
      ${hasMore ? html`
        <button
          class="narrative-timeline__load-more rounded-md"
          onClick=${() => { expandedItems.value += baseLimit }}
        >
          더 보기 (${totalAvailable - limit}건 남음)
        </button>
      ` : null}
    </div>
  `
}
