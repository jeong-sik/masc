// Session trace filter — FilterChips wrapper for trace event kinds.

import { html } from 'htm/preact'
import { FilterChips } from '../common/filter-chips'
import { traceFilter, traceEvents } from './session-trace-state'
import type { TraceEventKind } from './session-trace-state'

type FilterKey = TraceEventKind | 'all'

function countByKind(kind: TraceEventKind): number {
  return traceEvents.value.filter(e => e.kind === kind).length
}

export function SessionTraceFilter() {
  const events = traceEvents.value
  const total = events.length

  const chips: Array<{ key: FilterKey; label: string; count: number | null }> = [
    { key: 'all',        label: '전체',         count: total || null },
    { key: 'tool_call',  label: '도구 호출',    count: countByKind('tool_call') || null },
    { key: 'broadcast',  label: '브로드캐스트',  count: countByKind('broadcast') || null },
    { key: 'task',       label: '태스크',       count: countByKind('task') || null },
    { key: 'heartbeat',  label: '하트비트',     count: countByKind('heartbeat') || null },
    { key: 'lifecycle',  label: '생명주기',     count: countByKind('lifecycle') || null },
  ]

  // Only show chips that have at least one event (except 'all')
  const visibleChips = chips.filter(c => c.key === 'all' || (c.count != null && c.count > 0))

  return html`
    <${FilterChips}
      chips=${visibleChips}
      active=${traceFilter}
      size="sm"
      tone="accent"
    />
  `
}
