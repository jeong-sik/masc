// AgentLiveTimeline — enhanced per-agent event timeline with filter chips,
// event rate, auto-scroll toggle, and color-coded event badges.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef, useMemo } from 'preact/hooks'
import { TimeAgo } from '../common/time-ago'
import { FilterChips } from '../common/filter-chips'
import { EmptyState } from '../common/empty-state'
import { journal } from '../../sse'
import { isErrorJournalEntry } from '../../journal-entry'
import type { JournalEntry, JournalEventType } from '../../types'

export type FilterKind = 'all' | 'heartbeat' | 'message' | 'oas_turn' | 'tool' | 'error' | 'lifecycle'

const activeFilter = signal<FilterKind>('all')
const autoScroll = signal(true)

const FILTER_CHIPS: { key: FilterKind; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'heartbeat', label: 'Heartbeat' },
  { key: 'message', label: 'Message/Board' },
  { key: 'oas_turn', label: 'OAS Turn' },
  { key: 'tool', label: 'Tool' },
  { key: 'error', label: 'Error' },
  { key: 'lifecycle', label: 'Lifecycle' },
]

export function eventMatchesFilter(entry: JournalEntry, filter: FilterKind): boolean {
  if (filter === 'all') return true
  const et = entry.eventType ?? 'unknown'
  switch (filter) {
    case 'heartbeat':
      return et === 'keeper_heartbeat' || et === 'oas_keeper_snapshot'
    case 'message':
      return et === 'broadcast' || et === 'board_post' || et === 'board_comment'
    case 'oas_turn':
      return et === 'oas_turn'
    case 'tool':
      return et === 'keeper_tool_call' || et === 'oas_tool'
    case 'error':
      return et === 'keeper_guardrail' || isErrorJournalEntry(entry)
    case 'lifecycle':
      return et === 'agent_joined' || et === 'agent_left' || et === 'keeper_handoff' || et === 'keeper_compaction' || et === 'keeper_phase_changed' || et === 'oas_context' || et === 'oas_event' || et === 'oas_task'
    default:
      return true
  }
}

function eventKindBadgeClass(entry: JournalEntry): string {
  if (isErrorJournalEntry(entry)) return 'agent-event-badge--error'
  const eventType = entry.eventType
  switch (eventType) {
    case 'keeper_heartbeat':
    case 'oas_keeper_snapshot':
      return 'agent-event-badge--heartbeat'
    case 'oas_turn':
      return 'agent-event-badge--broadcast'
    case 'oas_tool':
      return 'agent-event-badge--task'
    case 'oas_context':
      return 'agent-event-badge--keeper'
    case 'oas_event':
    case 'oas_task':
      return 'agent-event-badge--lifecycle'
    case 'agent_joined':
    case 'agent_left':
      return 'agent-event-badge--lifecycle'
    case 'keeper_handoff':
    case 'keeper_compaction':
      return 'agent-event-badge--keeper'
    case 'keeper_guardrail':
      return 'agent-event-badge--error'
    case 'broadcast':
      return 'agent-event-badge--broadcast'
    case 'task_update':
      return 'agent-event-badge--task'
    case 'board_post':
    case 'board_comment':
      return 'agent-event-badge--board'
    default:
      return 'agent-event-badge--default'
  }
}

function eventKindLabel(eventType: JournalEventType | undefined): string {
  switch (eventType) {
    case 'keeper_heartbeat': return 'HB'
    case 'oas_keeper_snapshot': return 'OAS'
    case 'oas_turn': return 'TURN'
    case 'oas_tool': return 'TOOL'
    case 'oas_context': return 'CTX'
    case 'oas_event': return 'OAS'
    case 'oas_task': return 'TASK'
    case 'agent_joined': return 'JOIN'
    case 'agent_left': return 'LEFT'
    case 'keeper_handoff': return 'HAND'
    case 'keeper_compaction': return 'COMP'
    case 'keeper_guardrail': return 'GUARD'
    case 'broadcast': return 'CAST'
    case 'task_update': return 'TASK'
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
  const allEntries = getAgentJournalEntries(name)

  const filtered = useMemo(() => {
    const f = activeFilter.value
    return allEntries.filter(e => eventMatchesFilter(e, f))
  }, [allEntries, activeFilter.value])

  // events/min calculation: count events in the last 60 seconds
  const eventsPerMin = useMemo(() => {
    const now = Date.now()
    const cutoff = now - 60_000
    const recentCount = allEntries.filter(e => e.timestamp > cutoff).length
    return recentCount
  }, [allEntries])

  useEffect(() => {
    if (autoScroll.value && scrollRef.current) {
      scrollRef.current.scrollTop = 0
    }
  }, [filtered.length])

  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <${FilterChips} chips=${FILTER_CHIPS} active=${activeFilter} />
        <div class="flex items-center gap-2 text-2xs">
          <span class="px-2 py-0.5 rounded bg-[var(--white-4)] border border-[var(--white-8)] text-[var(--text-muted)] text-3xs">${eventsPerMin}/min</span>
          <span class="text-[var(--text-muted)]">${filtered.length} events</span>
          <button type="button"
            class="px-2 py-0.5 rounded text-3xs border cursor-pointer transition-all duration-150 ${autoScroll.value
              ? 'border-[rgba(34,197,94,0.4)] text-[var(--ok)] bg-[var(--white-4)]'
              : 'border-[var(--white-10)] text-[var(--text-dim)] bg-[var(--white-4)]'}"
            onClick=${() => { autoScroll.value = !autoScroll.value }}
            aria-pressed=${autoScroll.value}
            title=${autoScroll.value ? 'Auto-scroll ON' : 'Auto-scroll OFF'}
          >
            ${autoScroll.value ? 'AUTO' : 'MANUAL'}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-0.5 max-h-80 overflow-y-auto custom-scrollbar" ref=${scrollRef} role="log" aria-label="이벤트 타임라인">
        ${filtered.length === 0
          ? html`<${EmptyState} message="필터에 맞는 이벤트 없음" compact />`
          : filtered.map((entry: JournalEntry, idx: number) => html`
              <div class="flex items-baseline gap-1.5 py-1 px-2 text-sm transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${idx}>
                <span class="agent-event-badge ${eventKindBadgeClass(entry)}">
                  ${eventKindLabel(entry.eventType)}
                </span>
                <span class="flex-1 text-[var(--text-body)] truncate">${compactText(entry.text)}</span>
                ${entry.timestamp ? html`
                  <span class="text-[var(--text-dim)] text-2xs whitespace-nowrap"><${TimeAgo} timestamp=${entry.timestamp} /></span>
                ` : null}
              </div>
            `)}
      </div>
    </div>
  `
}
