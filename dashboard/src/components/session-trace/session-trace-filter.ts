// Session trace filter — category chips, status chips, and search input.
// Receives agentName as prop to avoid global activeTraceAgent dependency.

import { html } from 'htm/preact'
import { FilterChips } from '../common/filter-chips'
import {
  getKindCounts, getTraceFilter, setTraceFilter,
  getStatusCounts, getTraceStatusFilter, setTraceStatusFilter,
  getTraceSearchQuery, setTraceSearchQuery,
  _traceSlots,
} from './session-trace-state'
import type { TraceEventKind, TraceStatus } from './session-trace-state'

type FilterKey = TraceEventKind | 'all'
type StatusKey = TraceStatus | 'all'

const CATEGORY_CHIPS: Array<{ key: FilterKey; label: string }> = [
  { key: 'all',        label: '전체' },
  { key: 'tool_call',  label: '도구 호출' },
  { key: 'oas_tool',   label: 'OAS 도구' },
  { key: 'oas_turn',   label: 'OAS 턴' },
  { key: 'oas_context', label: 'OAS 압축' },
  { key: 'thinking',   label: '내부 사고' },
  { key: 'broadcast',  label: '브로드캐스트' },
  { key: 'task',       label: '태스크' },
  { key: 'heartbeat',  label: '하트비트' },
  { key: 'lifecycle',  label: '생명주기' },
]

const STATUS_CHIPS: Array<{ key: StatusKey; label: string }> = [
  { key: 'all',           label: '전체' },
  { key: 'success',       label: '성공' },
  { key: 'failure',       label: '실패' },
  { key: 'gate_rejected', label: '게이트 거부' },
]

export function SessionTraceFilter({ agentName }: { agentName: string }) {
  // Read _traceSlots.value to subscribe to slot changes
  void _traceSlots.value

  const counts = getKindCounts(agentName)
  const currentFilter = getTraceFilter(agentName)

  const categoryChips = CATEGORY_CHIPS
    .filter(c => c.key === 'all' || (counts[c.key] ?? 0) > 0)
    .map(c => ({ ...c, count: counts[c.key] || null }))

  const statusCounts = getStatusCounts(agentName)
  const currentStatus = getTraceStatusFilter(agentName)

  const statusChips = STATUS_CHIPS
    .filter(c => c.key === 'all' || (statusCounts[c.key] ?? 0) > 0)
    .map(c => ({ ...c, count: statusCounts[c.key] || null }))

  const searchQuery = getTraceSearchQuery(agentName)

  return html`
    <div class="space-y-2">
      <!-- Search -->
      <div class="relative">
        <input
          type="text"
          placeholder="이벤트 검색..."
          value=${searchQuery}
          onInput=${(e: Event) => {
            const v = (e.target as HTMLInputElement).value
            setTraceSearchQuery(agentName, v)
          }}
          class="w-full px-3 py-1.5 text-xs rounded bg-[var(--white-3)] border border-[var(--white-6)] text-[var(--text-body)] placeholder:text-[var(--text-dim)] outline-none focus:border-[var(--accent)]"
        />
        ${searchQuery ? html`
          <button
            onClick=${() => setTraceSearchQuery(agentName, '')}
            class="absolute right-2 top-1/2 -translate-y-1/2 text-[var(--text-dim)] hover:text-[var(--text-body)] text-base leading-none"
          >\u00d7</button>
        ` : null}
      </div>

      <!-- Category chips -->
      <${FilterChips}
        chips=${categoryChips}
        value=${currentFilter}
        onChange=${(key: FilterKey) => { setTraceFilter(agentName, key) }}
        size="sm"
        tone="accent"
      />

      <!-- Status chips -->
      ${statusCounts.all > 0 ? html`
        <div>
          <div class="text-3xs text-[var(--text-dim)] mb-1">상태</div>
          <${FilterChips}
            chips=${statusChips}
            value=${currentStatus}
            onChange=${(key: StatusKey) => { setTraceStatusFilter(agentName, key) }}
            size="sm"
            tone="neutral"
          />
        </div>
      ` : null}
    </div>
  `
}
