// Session trace state — unified event store for GitHub Agents-style trace view.
// Merges agent-timeline (broadcast/task) and keeper-trajectory (tool calls)
// into a single chronological event stream.
// State is keyed per agent to avoid cross-overlay collisions.

import { signal, computed } from '@preact/signals'
import { fetchAgentTimeline, fetchKeeperTrajectory } from '../../api/dashboard'
import type { AgentTimelineEvent, TrajectoryEntry } from '../../api/dashboard'

// ── Types ──────────────────────────────────────────────

export type TraceEventKind = 'broadcast' | 'task' | 'tool_call' | 'heartbeat' | 'lifecycle'

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
}

export interface TraceSummary {
  tool_call_count: number
  broadcast_count: number
  task_completed_count: number
  task_claimed_count: number
  heartbeat_count: number
  lifecycle_count: number
  total_cost_usd: number
}

interface TraceSlot {
  events: UnifiedTraceEvent[]
  loading: boolean
  error: string | null
  filter: TraceEventKind | 'all'
}

// ── Per-agent state map ────────────────────────────────

const traceSlots = signal<Record<string, TraceSlot>>({})

function getSlot(agent: string): TraceSlot {
  return traceSlots.value[agent] ?? { events: [], loading: false, error: null, filter: 'all' }
}

function patchSlot(agent: string, patch: Partial<TraceSlot>): void {
  const prev = getSlot(agent)
  traceSlots.value = { ...traceSlots.value, [agent]: { ...prev, ...patch } }
}

// ── Active agent (the one currently viewed) ────────────

export const activeTraceAgent = signal<string | null>(null)

// ── Derived signals (read from active agent's slot) ────

export const traceLoading = computed(() => {
  const agent = activeTraceAgent.value
  return agent ? getSlot(agent).loading : false
})

export const traceError = computed(() => {
  const agent = activeTraceAgent.value
  return agent ? getSlot(agent).error : null
})

export const traceEvents = computed(() => {
  const agent = activeTraceAgent.value
  return agent ? getSlot(agent).events : []
})

export const traceFilter = computed(() => {
  const agent = activeTraceAgent.value
  return agent ? getSlot(agent).filter : 'all' as const
})

export const filteredEvents = computed(() => {
  const filter = traceFilter.value
  const events = traceEvents.value
  if (filter === 'all') return events
  return events.filter(e => e.kind === filter)
})

export const traceSummary = computed<TraceSummary>(() => {
  const events = traceEvents.value
  let tool_call_count = 0
  let broadcast_count = 0
  let task_completed_count = 0
  let task_claimed_count = 0
  let heartbeat_count = 0
  let lifecycle_count = 0
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
    }
  }

  return {
    tool_call_count,
    broadcast_count,
    task_completed_count,
    task_claimed_count,
    heartbeat_count,
    lifecycle_count,
    total_cost_usd,
  }
})

/** Pre-computed kind counts for filter chips (avoids repeated .filter() in render). */
export const kindCounts = computed<Record<TraceEventKind | 'all', number>>(() => {
  const events = traceEvents.value
  const counts: Record<string, number> = { all: events.length, broadcast: 0, task: 0, tool_call: 0, heartbeat: 0, lifecycle: 0 }
  for (const e of events) counts[e.kind] = (counts[e.kind] ?? 0) + 1
  return counts as Record<TraceEventKind | 'all', number>
})

// ── Filter action ──────────────────────────────────────

export function setTraceFilter(agent: string, filter: TraceEventKind | 'all'): void {
  patchSlot(agent, { filter })
}

// ── Converters ─────────────────────────────────────────

function timelineEventToTrace(evt: AgentTimelineEvent, index: number): UnifiedTraceEvent {
  const ts = new Date(evt.ts).getTime()
  const detail = evt.detail ?? {}

  if (evt.type === 'broadcast') {
    const content = typeof detail.content === 'string' ? detail.content : ''
    if (content.length <= 20) {
      return {
        id: `tl-${ts}-hb-${index}`,
        ts,
        ts_iso: evt.ts,
        kind: 'heartbeat',
        summary: content || 'heartbeat',
        detail,
      }
    }
    return {
      id: `tl-${ts}-bc-${index}`,
      ts,
      ts_iso: evt.ts,
      kind: 'broadcast',
      summary: content.slice(0, 120),
      detail,
    }
  }

  const title = typeof detail.title === 'string' ? detail.title : ''
  const taskId = typeof detail.task_id === 'string' ? detail.task_id : ''
  return {
    id: `tl-${ts}-${evt.type}-${index}`,
    ts,
    ts_iso: evt.ts,
    kind: 'task',
    summary: `${evt.type.replace('task_', '')} ${taskId} ${title}`.trim(),
    detail: { ...detail, type: evt.type },
  }
}

function trajectoryEntryToTrace(entry: TrajectoryEntry, index: number): UnifiedTraceEvent {
  const ts = typeof entry.ts === 'number' ? entry.ts : new Date(entry.ts_iso).getTime()
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

// ── Actions ────────────────────────────────────────────

const TIMELINE_HOURS = 24
const TIMELINE_LIMIT = 200
const TRAJECTORY_LIMIT = 100

export async function loadSessionTrace(agentName: string, isKeeper: boolean): Promise<void> {
  activeTraceAgent.value = agentName
  patchSlot(agentName, { loading: true, error: null })

  try {
    const timelinePromise = fetchAgentTimeline(agentName, TIMELINE_HOURS, TIMELINE_LIMIT)
    const trajectoryPromise = isKeeper
      ? fetchKeeperTrajectory(agentName, TRAJECTORY_LIMIT)
      : Promise.resolve(null)

    const [timeline, trajectory] = await Promise.all([timelinePromise, trajectoryPromise])

    const timelineTraces = (timeline.events ?? []).map(timelineEventToTrace)
    const trajectoryTraces = trajectory
      ? trajectory.entries.map(trajectoryEntryToTrace)
      : []

    // Merge, sort by timestamp ascending, deduplicate by id
    const merged = [...timelineTraces, ...trajectoryTraces]
    merged.sort((a, b) => a.ts - b.ts)

    const seen = new Set<string>()
    const deduped = merged.filter(e => {
      if (seen.has(e.id)) return false
      seen.add(e.id)
      return true
    })

    patchSlot(agentName, { events: deduped, loading: false })
  } catch (err) {
    patchSlot(agentName, {
      events: [],
      loading: false,
      error: err instanceof Error ? err.message : 'fetch failed',
    })
  }
}

export function closeSessionTrace(agentName: string): void {
  const next = { ...traceSlots.value }
  delete next[agentName]
  traceSlots.value = next
  if (activeTraceAgent.value === agentName) {
    activeTraceAgent.value = null
  }
}
