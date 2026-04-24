import { signal } from '@preact/signals'
import type { UnifiedTraceEvent } from './session-trace-state'

export const liveTraceFeeds = signal<Record<string, UnifiedTraceEvent[]>>({})

const LIVE_TRACE_LIMIT = 120
let liveTraceSeq = 0
let traceOpenProvider: ((agentName: string) => boolean) | null = null
let historicalIdsProvider: ((agentName: string) => string[]) | null = null

export function registerLiveTraceSlotProvider(
  provider: (agentName: string) => boolean,
): void {
  traceOpenProvider = provider
}

export function registerLiveTraceHistoricalIdsProvider(
  provider: (agentName: string) => string[],
): void {
  historicalIdsProvider = provider
}

export function ensureLiveTraceSlot(agentName: string): void {
  if (liveTraceFeeds.value[agentName]) return
  liveTraceFeeds.value = { ...liveTraceFeeds.value, [agentName]: [] }
}

export function deleteLiveTraceSlot(agentName: string): void {
  const feeds = { ...liveTraceFeeds.value }
  delete feeds[agentName]
  liveTraceFeeds.value = feeds
}

/** Append a live MASC tool call event from SSE into the trace feed. */
export function appendLiveToolCall(
  agentName: string,
  evt: {
    toolName: string
    durationMs: number
    success: boolean
    error: string | null
    tsUnix: number
  },
): void {
  const tsMs = evt.tsUnix * 1000
  appendLiveTraceEvent(agentName, {
    id: `live-masc-tool-${tsMs}-${evt.toolName}`,
    ts: tsMs,
    ts_iso: new Date(tsMs).toISOString(),
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: evt.toolName,
    detail: {},
    agentName,
    toolName: evt.toolName,
    duration_ms: evt.durationMs,
    error: evt.error,
  })
}

/** Append a live OAS runtime event from SSE into the trace feed. */
export function appendLiveOasEvent(
  agentName: string,
  event: Omit<UnifiedTraceEvent, 'sourceLane' | 'agentName'>,
): void {
  appendLiveTraceEvent(agentName, {
    ...event,
    sourceLane: 'oas',
    agentName,
  })
}

function appendLiveTraceEvent(agentName: string, event: UnifiedTraceEvent): void {
  if (!liveTraceFeeds.value[agentName]) {
    if (!traceOpenProvider?.(agentName)) return
    ensureLiveTraceSlot(agentName)
  }
  const prev = liveTraceFeeds.value[agentName] ?? []
  const historicalIds = historicalIdsProvider?.(agentName) ?? []
  const seenIds = new Set([
    ...historicalIds,
    ...prev.map(item => item.id),
  ])
  const uniqueEvent =
    seenIds.has(event.id)
      ? { ...event, id: `${event.id}-${++liveTraceSeq}` }
      : event
  const next = [...prev, uniqueEvent]
  const pruned =
    next.length > LIVE_TRACE_LIMIT
      ? next.slice(next.length - LIVE_TRACE_LIMIT)
      : next
  liveTraceFeeds.value = { ...liveTraceFeeds.value, [agentName]: pruned }
}
