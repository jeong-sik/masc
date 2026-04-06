// Session trace state — unified event store for GitHub Agents-style trace view.
// Merges agent-timeline (broadcast/task) and keeper-trajectory (tool calls)
// into a single chronological event stream.
// State is keyed per agent to avoid cross-overlay collisions.
// Each SessionTraceView instance passes its own agentName to derived helpers.

import { signal } from '@preact/signals'
import { fetchAgentTimeline, fetchKeeperTrajectory } from '../../api/dashboard'
import type { AgentTimelineEvent, AgentTimelineResponse, TrajectoryEntry, TrajectoryResponse } from '../../api/dashboard'

// ── Types ──────────────────────────────────────────────

export type TraceEventKind = 'broadcast' | 'task' | 'tool_call' | 'heartbeat' | 'lifecycle' | 'thinking'

export interface UnifiedTraceEvent {
  id: string
  ts: number          // unix ms — sort key
  ts_iso: string
  kind: TraceEventKind
  summary: string     // collapsed one-liner
  detail: Record<string, unknown>
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
  broadcast_count: number
  task_completed_count: number
  task_claimed_count: number
  heartbeat_count: number
  lifecycle_count: number
  thinking_count: number
  total_cost_usd: number
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

const EMPTY_SLOT: TraceSlot = { events: [], loading: false, error: null, filter: 'all', fetchToken: 0 }

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
  return getSlot(agent).events
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
  let broadcast_count = 0
  let task_completed_count = 0
  let task_claimed_count = 0
  let heartbeat_count = 0
  let lifecycle_count = 0
  let thinking_count = 0
  let total_cost_usd = 0

  for (const e of events) {
    switch (e.kind) {
      case 'tool_call':
        tool_call_count++
        total_cost_usd += e.cost_usd ?? 0
        break
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
        break
      case 'thinking':
        thinking_count++
        break
    }
  }

  return { tool_call_count, broadcast_count, task_completed_count, task_claimed_count, heartbeat_count, lifecycle_count, thinking_count, total_cost_usd }
}

export function getKindCounts(agent: string): Record<TraceEventKind | 'all', number> {
  const events = getTraceEvents(agent)
  const counts: Record<string, number> = { all: events.length, broadcast: 0, task: 0, tool_call: 0, heartbeat: 0, lifecycle: 0, thinking: 0 }
  for (const e of events) counts[e.kind] = (counts[e.kind] ?? 0) + 1
  return counts as Record<TraceEventKind | 'all', number>
}

// ── Trigger signal ─────────────────────────────────────
// Components subscribe to this to know when traceSlots changed.
// Reading traceSlots.value inside a component body tracks reactivity.
export { traceSlots as _traceSlots }

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
        summary: content || 'heartbeat',
        detail,
      }
    }
    return {
      id: `tl-${ts}-bc-${index}`,
      ts,
      ts_iso: evt.ts ?? new Date(ts).toISOString(),
      kind: 'broadcast',
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
      summary: entry.redacted ? '[비공개 사고]' : (entry.content?.slice(0, 120) ?? ''),
      detail: {},
      turn: entry.turn,
      thinkingContent: entry.content,
      thinkingRedacted: entry.redacted,
    }
  }

  return {
    id: `tj-${ts}-${entry.tool_name}-T${entry.turn}R${entry.round}-${index}`,
    ts,
    ts_iso: entry.ts_iso,
    kind: 'tool_call',
    summary: entry.tool_name,
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
  const merged = [...timelineTraces, ...trajectoryTraces]
  merged.sort((a, b) => a.ts - b.ts)
  const seen = new Set<string>()
  return merged.filter(e => {
    if (seen.has(e.id)) return false
    seen.add(e.id)
    return true
  })
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

export function closeSessionTrace(agentName: string): void {
  const next = { ...traceSlots.value }
  delete next[agentName]
  traceSlots.value = next
}
