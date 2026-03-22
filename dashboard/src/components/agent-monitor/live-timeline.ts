// AgentLiveTimeline — enhanced per-agent event timeline with filter chips,
// event rate, auto-scroll toggle, and color-coded event badges.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef, useMemo } from 'preact/hooks'
import { TimeAgo } from '../common/time-ago'
import { journal } from '../../sse'
import type { JournalEntry, JournalEventType } from '../../types'

type FilterKind = 'all' | 'heartbeat' | 'turn' | 'tool' | 'error' | 'lifecycle'

const activeFilter = signal<FilterKind>('all')
const autoScroll = signal(true)

const FILTER_CHIPS: { key: FilterKind; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'heartbeat', label: 'Heartbeat' },
  { key: 'turn', label: 'Turn' },
  { key: 'tool', label: 'Tool' },
  { key: 'error', label: 'Error' },
  { key: 'lifecycle', label: 'Lifecycle' },
]

function eventMatchesFilter(entry: JournalEntry, filter: FilterKind): boolean {
  if (filter === 'all') return true
  const et = entry.eventType ?? 'unknown'
  switch (filter) {
    case 'heartbeat':
      return et === 'keeper_heartbeat' || et === 'oas_keeper_snapshot'
    case 'turn':
      return et === 'broadcast' || et === 'board_post' || et === 'board_comment'
    case 'tool':
      return entry.text.toLowerCase().includes('tool')
    case 'error':
      return et === 'keeper_guardrail' || entry.text.toLowerCase().includes('error')
    case 'lifecycle':
      return et === 'agent_joined' || et === 'agent_left' || et === 'keeper_handoff' || et === 'keeper_compaction'
    default:
      return true
  }
}

function eventKindBadgeClass(eventType: JournalEventType | undefined): string {
  switch (eventType) {
    case 'keeper_heartbeat':
    case 'oas_keeper_snapshot':
      return 'agent-event-badge--heartbeat'
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
    <div class="agent-live-timeline">
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <div class="agent-live-filter-bar">
          ${FILTER_CHIPS.map(chip => html`
            <button
              key=${chip.key}
              class="agent-live-chip rounded-xl ${activeFilter.value === chip.key ? 'agent-live-chip--active' : ''}"
              onClick=${() => { activeFilter.value = chip.key }}
            >
              ${chip.label}
            </button>
          `)}
        </div>
        <div class="flex items-center gap-2 text-[length:var(--fs-xs)]">
          <span class="agent-event-rate rounded-lg">${eventsPerMin}/min</span>
          <span class="text-text-muted">${filtered.length} events</span>
          <button
            class="agent-live-autoscroll rounded-lg ${autoScroll.value ? 'agent-live-autoscroll--on' : ''}"
            onClick=${() => { autoScroll.value = !autoScroll.value }}
            title=${autoScroll.value ? 'Auto-scroll ON' : 'Auto-scroll OFF'}
          >
            ${autoScroll.value ? 'AUTO' : 'MANUAL'}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-0.5 max-h-[320px] overflow-y-auto" ref=${scrollRef}>
        ${filtered.length === 0
          ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">필터에 맞는 이벤트 없음</div>`
          : filtered.map((entry: JournalEntry, idx: number) => html`
              <div class="flex items-baseline gap-1.5 py-1 px-2 text-[length:var(--fs-sm)] transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${idx}>
                <span class="agent-event-badge ${eventKindBadgeClass(entry.eventType)}">
                  ${eventKindLabel(entry.eventType)}
                </span>
                <span class="agent-live-event-text">${compactText(entry.text)}</span>
                ${entry.timestamp ? html`
                  <span class="agent-live-event-time"><${TimeAgo} timestamp=${entry.timestamp} /></span>
                ` : null}
              </div>
            `)}
      </div>
    </div>
  `
}
