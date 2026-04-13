// Session trace state — unified event store for GitHub Agents-style trace view.
// Merges agent-timeline (broadcast/task), keeper-trajectory (tool calls),
// and live OAS runtime SSE events into a single chronological event stream.
// State is keyed per agent to avoid cross-overlay collisions.
// Each SessionTraceView instance passes its own agentName to derived helpers.

import { signal } from '@preact/signals'
import { fetchAgentTimeline, fetchKeeperTrajectory } from '../../api/dashboard'
import type { AgentTimelineEvent, AgentTimelineResponse, TrajectoryEntry, TrajectoryResponse } from '../../api/dashboard'

// ── Types ──────────────────────────────────────────────

export type TraceEventKind =
  | 'broadcast'
  | 'task'
  | 'tool_call'
  | 'heartbeat'
  | 'lifecycle'
  | 'thinking'
  | 'oas_tool'
  | 'oas_turn'
  | 'oas_context'

export type TraceSourceLane = 'masc' | 'oas'

export interface UnifiedTraceEvent {
  id: string
  ts: number          // unix ms — sort key
  ts_iso: string
  kind: TraceEventKind
  sourceLane: TraceSourceLane
  summary: string     // collapsed one-liner
  detail: Record<string, unknown>
  agentName?: string
  sessionId?: string | null
  operationId?: string | null
  workerRunId?: string | null
  // tool_call fields
  toolName?: string
  toolArgs?: Record<string, unknown> | string
  toolResult?: string | null
  duration_ms?: number
  gate?: { status: string; reason?: string }
  turn?: number
  round?: number
  cost_usd?: number
  error?: string | null
  // thinking fields
  thinkingContent?: string
  thinkingRedacted?: boolean
}

export interface TraceSummary {
  tool_call_count: number
  oas_tool_count: number
  oas_turn_count: number
  oas_context_count: number
  broadcast_count: number
  task_completed_count: number
  task_claimed_count: number
  heartbeat_count: number
  lifecycle_count: number
  thinking_count: number
  total_cost_usd: number
  oas_input_tokens: number
  oas_output_tokens: number
  oas_llm_call_count: number
  oas_error_count: number
  oas_tokens_saved: number
}

interface TraceSlot {
  events: UnifiedTraceEvent[]
  loading: boolean
  error: string | null
  filter: TraceEventKind | 'all'
  /** Monotonic fetch token — used to discard stale in-flight responses. */
  fetchToken: number
}

// ── Per-agent state map ────────────────────────────────

const traceSlots = signal<Record<string, TraceSlot>>({})
const liveTraceFeeds = signal<Record<string, UnifiedTraceEvent[]>>({})

const EMPTY_SLOT: TraceSlot = { events: [], loading: false, error: null, filter: 'all', fetchToken: 0 }

const LIVE_TRACE_LIMIT = 120
let liveTraceSeq = 0

function getSlot(agent: string): TraceSlot {
  return traceSlots.value[agent] ?? EMPTY_SLOT
}

function patchSlot(agent: string, patch: Partial<TraceSlot>): void {
  const prev = getSlot(agent)
  traceSlots.value = { ...traceSlots.value, [agent]: { ...prev, ...patch } }
}

// ── Per-agent derived helpers ──────────────────────────
// Components pass their own agentName rather than relying on a global
// "active" signal, so multiple overlays can coexist without corruption.

export function getTraceLoading(agent: string): boolean {
  return getSlot(agent).loading
}

export function getTraceError(agent: string): string | null {
  return getSlot(agent).error
}

export function getTraceEvents(agent: string): UnifiedTraceEvent[] {
  return mergeTraceEvents(getSlot(agent).events, liveTraceFeeds.value[agent] ?? [])
}

export function getTraceFilter(agent: string): TraceEventKind | 'all' {
  return getSlot(agent).filter
}

export function getFilteredEvents(agent: string): UnifiedTraceEvent[] {
  const filter = getTraceFilter(agent)
  const events = getTraceEvents(agent)
  if (filter === 'all') return events
  return events.filter(e => e.kind === filter)
}

export function getTraceSummary(agent: string): TraceSummary {
  const events = getTraceEvents(agent)
  let tool_call_count = 0
  let oas_tool_count = 0
  let oas_turn_count = 0
  let oas_context_count = 0
  let broadcast_count = 0
  let task_completed_count = 0
  let task_claimed_count = 0
  let heartbeat_count = 0
  let lifecycle_count = 0
  let thinking_count = 0
  let total_cost_usd = 0
  let oas_input_tokens = 0
  let oas_output_tokens = 0
  let oas_llm_call_count = 0
  let oas_error_count = 0
  let oas_tokens_saved = 0

  for (const e of events) {
    switch (e.kind) {
      case 'tool_call':
        tool_call_count++
        total_cost_usd += e.cost_usd ?? 0
        break
      case 'oas_tool':
        oas_tool_count++
        break
      case 'oas_turn':
        oas_turn_count++
        break
      case 'oas_context': {
        oas_context_count++
        const before = e.detail.before_tokens
        const after = e.detail.after_tokens
        if (typeof before === 'number' && typeof after === 'number' && before > after) {
          oas_tokens_saved += before - after
        }
        break
      }
      case 'broadcast':
        broadcast_count++
        break
      case 'task':
        if (e.detail.type === 'task_completed') task_completed_count++
        if (e.detail.type === 'task_claimed') task_claimed_count++
        break
      case 'heartbeat':
        heartbeat_count++
        break
      case 'lifecycle':
        lifecycle_count++
        total_cost_usd += e.cost_usd ?? 0
        {
          const inTok = e.detail.input_tokens
          const outTok = e.detail.output_tokens
          if (typeof inTok === 'number') oas_input_tokens += inTok
          if (typeof outTok === 'number') oas_output_tokens += outTok
          const durableKind = e.detail.durable_kind
          if (durableKind === 'llm_request') oas_llm_call_count++
          if (durableKind === 'error_occurred') oas_error_count++
        }
        break
      case 'thinking':
        thinking_count++
        break
    }
  }

  return {
    tool_call_count,
    oas_tool_count,
    oas_turn_count,
    oas_context_count,
    broadcast_count,
    task_completed_count,
    task_claimed_count,
    heartbeat_count,
    lifecycle_count,
    thinking_count,
    total_cost_usd,
    oas_input_tokens,
    oas_output_tokens,
    oas_llm_call_count,
    oas_error_count,
    oas_tokens_saved,
  }
}

export function getKindCounts(agent: string): Record<TraceEventKind | 'all', number> {
  const events = getTraceEvents(agent)
  const counts: Record<string, number> = {
    all: events.length,
    broadcast: 0,
    task: 0,
    tool_call: 0,
    heartbeat: 0,
    lifecycle: 0,
    thinking: 0,
    oas_tool: 0,
    oas_turn: 0,
    oas_context: 0,
  }
  for (const e of events) counts[e.kind] = (counts[e.kind] ?? 0) + 1
  return counts as Record<TraceEventKind | 'all', number>
}

// ── Trigger signal ─────────────────────────────────────
// Components subscribe to this to know when traceSlots changed.
// Reading traceSlots.value inside a component body tracks reactivity.
export { traceSlots as _traceSlots }
export { liveTraceFeeds as _liveTraceFeeds }

// ── Filter action ──────────────────────────────────────

export function setTraceFilter(agent: string, filter: TraceEventKind | 'all'): void {
  patchSlot(agent, { filter })
}

// ── Converters ─────────────────────────────────────────

function safeTimestamp(ts: string | undefined | null): number {
  if (!ts) return Date.now()
  const parsed = new Date(ts).getTime()
  return Number.isNaN(parsed) ? Date.now() : parsed
}

function mergeTraceEvents(
  historical: UnifiedTraceEvent[],
  live: UnifiedTraceEvent[],
): UnifiedTraceEvent[] {
  const merged = [...historical, ...live]
  merged.sort((a, b) => a.ts - b.ts)
  const seen = new Set<string>()
  return merged.filter(event => {
    if (seen.has(event.id)) return false
    seen.add(event.id)
    return true
  })
}

function timelineEventToTrace(evt: AgentTimelineEvent, index: number): UnifiedTraceEvent {
  const ts = safeTimestamp(evt.ts)
  const detail = evt.detail ?? {}

  if (evt.type === 'broadcast') {
    const content = typeof detail.content === 'string' ? detail.content : ''
    if (content.length <= 20) {
      return {
        id: `tl-${ts}-hb-${index}`,
        ts,
        ts_iso: evt.ts ?? new Date(ts).toISOString(),
        kind: 'heartbeat',
        sourceLane: 'masc',
        summary: content || 'heartbeat',
        detail,
      }
    }
    return {
      id: `tl-${ts}-bc-${index}`,
      ts,
      ts_iso: evt.ts ?? new Date(ts).toISOString(),
      kind: 'broadcast',
      sourceLane: 'masc',
      summary: content.slice(0, 120),
      detail,
    }
  }

  if (evt.type === 'joined' || evt.type === 'left') {
    return {
      id: `tl-${ts}-${evt.type}-${index}`,
      ts,
      ts_iso: evt.ts ?? new Date(ts).toISOString(),
      kind: 'lifecycle',
      sourceLane: 'masc',
      summary: evt.type,
      detail,
    }
  }

  const title = typeof detail.title === 'string' ? detail.title : ''
  const taskId = typeof detail.task_id === 'string' ? detail.task_id : ''
  return {
    id: `tl-${ts}-${evt.type}-${index}`,
    ts,
    ts_iso: evt.ts ?? new Date(ts).toISOString(),
    kind: 'task',
    sourceLane: 'masc',
    summary: `${evt.type.replace('task_', '')} ${taskId} ${title}`.trim(),
    detail: { ...detail, type: evt.type },
  }
}

function trajectoryEntryToTrace(entry: TrajectoryEntry, index: number): UnifiedTraceEvent {
  const ts = typeof entry.ts === 'number' ? entry.ts : safeTimestamp(entry.ts_iso)

  // Handle thinking entries (type === 'thinking')
  if (entry.type === 'thinking') {
    return {
      id: `tj-${ts}-thinking-T${entry.turn}-${index}`,
      ts,
      ts_iso: entry.ts_iso,
      kind: 'thinking',
      sourceLane: 'masc',
      summary: entry.redacted ? '[비공개 사고]' : (entry.content?.slice(0, 120) ?? ''),
      detail: {},
      turn: entry.turn,
      thinkingContent: entry.content,
      thinkingRedacted: entry.redacted,
    }
  }

  return {
    id: `tj-${ts}-${entry.tool_name ?? 'unknown'}-T${entry.turn}R${entry.round ?? 0}-${index}`,
    ts,
    ts_iso: entry.ts_iso,
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: entry.tool_name ?? 'unknown',
    detail: {},
    toolName: entry.tool_name,
    toolArgs: entry.args,
    toolResult: entry.result,
    duration_ms: entry.duration_ms,
    gate: entry.gate,
    turn: entry.turn,
    round: entry.round,
    cost_usd: entry.cost_usd,
    error: entry.error,
  }
}

// ── Pure merge function (reusable by task-detail) ──────

/** Build a deduplicated, time-sorted trace from timeline + trajectory data.
 *  Extracted from loadSessionTrace for reuse in task detail overlay. */
export function buildTraceEvents(
  timeline: AgentTimelineResponse,
  trajectory: TrajectoryResponse | null,
): UnifiedTraceEvent[] {
  const timelineTraces = (timeline.events ?? []).map(timelineEventToTrace)
  const trajectoryTraces = trajectory
    ? (trajectory.entries ?? []).map(trajectoryEntryToTrace)
    : []
  return mergeTraceEvents(timelineTraces, trajectoryTraces)
}

// ── Actions ────────────────────────────────────────────

const TIMELINE_HOURS = 24
const TIMELINE_LIMIT = 200
const TRAJECTORY_LIMIT = 100

export async function loadSessionTrace(agentName: string, isKeeper: boolean): Promise<void> {
  // Bump fetch token for this agent — any prior in-flight fetch becomes stale.
  const prevSlot = getSlot(agentName)
  const token = prevSlot.fetchToken + 1
  patchSlot(agentName, { loading: true, error: null, fetchToken: token })
  if (!liveTraceFeeds.value[agentName]) {
    liveTraceFeeds.value = { ...liveTraceFeeds.value, [agentName]: [] }
  }

  try {
    const timelinePromise = fetchAgentTimeline(agentName, TIMELINE_HOURS, TIMELINE_LIMIT)
    const trajectoryPromise = isKeeper
      ? fetchKeeperTrajectory(agentName, TRAJECTORY_LIMIT)
      : Promise.resolve(null)

    const [timeline, trajectory] = await Promise.all([timelinePromise, trajectoryPromise])

    // Discard result if slot was closed or a newer fetch was started during await.
    if (getSlot(agentName).fetchToken !== token) return

    const deduped = buildTraceEvents(timeline, trajectory)

    // Final stale check before writing
    if (getSlot(agentName).fetchToken !== token) return

    patchSlot(agentName, { events: deduped, loading: false })
  } catch (err) {
    // Discard if stale
    if (getSlot(agentName).fetchToken !== token) return
    // Preserve existing events on refresh failure
    patchSlot(agentName, {
      loading: false,
      error: err instanceof Error ? err.message : 'fetch failed',
    })
  }
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

export function appendLiveTraceEvent(agentName: string, event: UnifiedTraceEvent): void {
  if (!traceSlots.value[agentName] && !liveTraceFeeds.value[agentName]) return
  const prev = liveTraceFeeds.value[agentName] ?? []
  const historical = traceSlots.value[agentName]?.events ?? []
  const seenIds = new Set([
    ...historical.map(item => item.id),
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

export function closeSessionTrace(agentName: string): void {
  const next = { ...traceSlots.value }
  delete next[agentName]
  traceSlots.value = next
  const feeds = { ...liveTraceFeeds.value }
  delete feeds[agentName]
  liveTraceFeeds.value = feeds
}
