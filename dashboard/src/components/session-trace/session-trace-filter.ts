// Session trace filter — FilterChips wrapper for trace event kinds.
// Receives agentName as prop to avoid global activeTraceAgent dependency.

import { html } from 'htm/preact'
import { FilterChips } from '../common/filter-chips'
import { getKindCounts, getTraceFilter, setTraceFilter, _traceSlots } from './session-trace-state'
import type { TraceEventKind } from './session-trace-state'

type FilterKey = TraceEventKind | 'all'

const CHIP_DEFS: Array<{ key: FilterKey; label: string }> = [
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

export function SessionTraceFilter({ agentName }: { agentName: string }) {
  // Read _traceSlots.value to subscribe to slot changes
  void _traceSlots.value

  const counts = getKindCounts(agentName)
  const currentFilter = getTraceFilter(agentName)

  const chips = CHIP_DEFS
    .filter(c => c.key === 'all' || (counts[c.key] ?? 0) > 0)
    .map(c => ({ ...c, count: counts[c.key] || null }))

  return html`
    <${FilterChips}
      chips=${chips}
      value=${currentFilter}
      onChange=${(key: FilterKey) => { setTraceFilter(agentName, key) }}
      size="sm"
      tone="accent"
    />
  `
}
