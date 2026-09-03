// AgentLiveTimeline — enhanced per-agent event timeline with filter chips,
// event rate, auto-scroll toggle, and color-coded event badges.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef, useMemo } from 'preact/hooks'
import { TimeAgo } from '../common/time-ago'
import { FilterChips } from '../common/filter-chips'
import { EmptyState } from '../common/feedback-state'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { journal } from '../../sse'
import { isErrorJournalEntry } from '../../journal-entry'
import type { JournalEntry, JournalEventType } from '../../types'

type FilterKind = 'all' | 'heartbeat' | 'message' | 'agent_core_turn' | 'tool' | 'error' | 'lifecycle'

const activeFilter = signal<FilterKind>('all')
const autoScroll = signal(true)

const FILTER_CHIPS: { key: FilterKind; label: string }[] = [
  { key: 'all', label: '전체' },
  { key: 'heartbeat', label: '하트비트' },
  { key: 'message', label: '메시지/보드' },
  { key: 'agent_core_turn', label: 'Agent Core 턴' },
  { key: 'tool', label: '도구' },
  { key: 'error', label: '오류' },
  { key: 'lifecycle', label: '라이프사이클' },
]

type EventBadgeTone = Extract<StatusChipTone, 'ok' | 'warn' | 'bad' | 'info' | 'neutral'>

function eventMatchesFilter(entry: JournalEntry, filter: FilterKind): boolean {
  if (filter === 'all') return true
  const et = entry.eventType ?? 'unknown'
  switch (filter) {
    case 'heartbeat':
      return et === 'keeper_heartbeat'
    case 'message':
      return et === 'broadcast' || et === 'board_post' || et === 'board_comment'
    case 'agent_core_turn':
      return et === 'agent_core_turn'
    case 'tool':
      return et === 'keeper_tool_call' || et === 'agent_core_tool'
    case 'error':
      return isErrorJournalEntry(entry)
    case 'lifecycle':
      return et === 'keeper_handoff' || et === 'keeper_phase_changed' || et === 'agent_core_event'
    default:
      return true
  }
}

function eventKindBadgeTone(entry: JournalEntry): EventBadgeTone {
  if (isErrorJournalEntry(entry)) return 'bad'
  const eventType = entry.eventType
  switch (eventType) {
    case 'keeper_heartbeat':
      return 'ok'
    case 'agent_core_turn':
      return 'info'
    case 'agent_core_tool':
      return 'warn'
    case 'agent_core_event':
      return 'info'
    case 'keeper_handoff':
      return 'info'
    case 'broadcast':
      return 'info'
    case 'board_post':
    case 'board_comment':
      return 'info'
    default:
      return 'neutral'
  }
}

function eventKindLabel(eventType: JournalEventType | undefined): string {
  switch (eventType) {
    case 'keeper_heartbeat': return 'HB'
    case 'agent_core_turn': return 'TURN'
    case 'agent_core_tool': return 'TOOL'
    case 'agent_core_event': return 'Agent Core'
    case 'keeper_handoff': return 'HAND'
    case 'broadcast': return 'CAST'
    case 'board_post': return 'POST'
    case 'board_comment': return 'CMNT'
    case 'unknown': return 'SYS'
    default: return 'EVT'
  }
}

function compactText(value: string | null | undefined, max = 120): string {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return ''
  return text.length > max ? `${text.slice(0, max - 1)}...` : text
}

function getAgentJournalEntries(name: string): JournalEntry[] {
  const lower = name.toLowerCase()
  return journal.value
    .filter((e: JournalEntry) => {
      const text = e.text.toLowerCase()
      const agent = e.agent.toLowerCase()
      return agent === lower || text.includes(lower) || text.includes(`@${lower}`)
    })
    .slice(0, 50)
}

export function AgentLiveTimeline({ name }: { name: string }) {
  const scrollRef = useRef<HTMLDivElement>(null)
  // getAgentJournalEntries scans the full MAX_JOURNAL_ENTRIES ring buffer (200)
  // with 2x toLowerCase + includes per entry. Parent AgentProfile re-renders on
  // every mention-input keystroke (mentionText) and other unrelated signals;
  // memoizing on [name, journal.value] skips the scan when neither the journal
  // contents nor the target agent changed. This also makes the downstream
  // `filtered` useMemo ([allEntries, activeFilter]) effective — previously
  // allEntries was a fresh array every render so that memo always missed.
  const allEntries = useMemo(() => getAgentJournalEntries(name), [name, journal.value])

  const filtered = useMemo(() => {
    const f = activeFilter.value
    return allEntries.filter(e => eventMatchesFilter(e, f))
  }, [allEntries, activeFilter.value])

  // events/min: kept as a plain (non-memoized) computation because it reads
  // Date.now() to define a sliding 60s window. With allEntries now ref-stable,
  // a useMemo([allEntries]) would freeze this count whenever the journal was
  // quiet — the window would stop sliding and past events would never age out.
  // allEntries is capped at 50 (sliced upstream), so this filter is cheap.
  const now = Date.now()
  const cutoff = now - 60_000
  const eventsPerMin = allEntries.filter(e => e.timestamp > cutoff).length

  useEffect(() => {
    if (autoScroll.value && scrollRef.current) {
      scrollRef.current.scrollTop = 0
    }
  }, [filtered.length])

  return html`
    <div class="v2-monitoring-detail flex flex-col gap-2">
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <${FilterChips} chips=${FILTER_CHIPS} active=${activeFilter} />
        <div class="flex items-center gap-2 text-2xs">
          <span class="px-2 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] text-[var(--color-fg-muted)] text-3xs">${eventsPerMin}/min</span>
          <span class="text-[var(--color-fg-muted)]">${filtered.length} events</span>
          <button type="button"
            class="v2-monitoring-action px-2 py-0.5 rounded-[var(--r-1)] text-3xs border cursor-pointer transition-[background-color,border-color,box-shadow] duration-[var(--t-med)] ${autoScroll.value
              ? 'border-[var(--ok-border)] text-[var(--color-status-ok)] bg-[var(--color-bg-elevated)]'
              : 'border-[var(--color-border-default)] text-[var(--color-fg-disabled)] bg-[var(--color-bg-elevated)]'}"
            aria-pressed=${autoScroll.value}
            aria-label="자동 스크롤"
            onClick=${() => { autoScroll.value = !autoScroll.value }}
            title=${autoScroll.value ? '자동 스크롤 ON' : '자동 스크롤 OFF'}
          >
            ${autoScroll.value ? 'AUTO' : 'MANUAL'}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-0.5 max-h-80 overflow-y-auto" ref=${scrollRef}>
        ${filtered.length === 0
          ? html`<${EmptyState} message="필터에 맞는 이벤트 없음" compact />`
          : filtered.map((entry: JournalEntry, idx: number) => html`
              <div class="v2-monitoring-row flex items-baseline gap-1.5 py-1 px-2 text-sm transition-[background] duration-[var(--t-fast)] rounded-[var(--r-1)] hover:bg-[var(--color-bg-elevated)]" key=${idx}>
                <${StatusChip} tone=${eventKindBadgeTone(entry)}>${eventKindLabel(entry.eventType)}<//>
                <span class="flex-1 text-[var(--color-fg-primary)] truncate">${compactText(entry.text)}</span>
                ${entry.timestamp ? html`
                  <span class="text-[var(--color-fg-disabled)] text-2xs whitespace-nowrap"><${TimeAgo} timestamp=${entry.timestamp} /></span>
                ` : null}
              </div>
            `)}
      </div>
    </div>
  `
}
