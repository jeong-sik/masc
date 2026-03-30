// Session trace filter — FilterChips wrapper for trace event kinds.
// Uses pre-computed kindCounts signal (single-pass) instead of per-chip .filter().

import { html } from 'htm/preact'
import { FilterChips } from '../common/filter-chips'
import { kindCounts, activeTraceAgent, setTraceFilter, traceFilter } from './session-trace-state'
import type { TraceEventKind } from './session-trace-state'

type FilterKey = TraceEventKind | 'all'

const CHIP_DEFS: Array<{ key: FilterKey; label: string }> = [
  { key: 'all',        label: '전체' },
  { key: 'tool_call',  label: '도구 호출' },
  { key: 'broadcast',  label: '브로드캐스트' },
  { key: 'task',       label: '태스크' },
  { key: 'heartbeat',  label: '하트비트' },
  { key: 'lifecycle',  label: '생명주기' },
]

export function SessionTraceFilter() {
  const counts = kindCounts.value
  const currentFilter = traceFilter.value
  const agent = activeTraceAgent.value

  const chips = CHIP_DEFS
    .filter(c => c.key === 'all' || (counts[c.key] ?? 0) > 0)
    .map(c => ({ ...c, count: counts[c.key] || null }))

  return html`
    <${FilterChips}
      chips=${chips}
      value=${currentFilter}
      onChange=${(key: FilterKey) => { if (agent) setTraceFilter(agent, key) }}
      size="sm"
      tone="accent"
    />
  `
}
