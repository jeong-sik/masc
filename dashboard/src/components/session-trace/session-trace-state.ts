// Session trace state — unified event store for GitHub Agents-style trace view.
// Merges agent-timeline (broadcast/task) and keeper-trajectory (tool calls)
// into a single chronological event stream.

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
  total_cost_usd: number
  active_duration_minutes: number
}

// ── Signals ────────────────────────────────────────────

export const traceAgentName = signal<string | null>(null)
export const traceEvents = signal<UnifiedTraceEvent[]>([])
export const traceLoading = signal(false)
export const traceError = signal<string | null>(null)
export const traceFilter = signal<TraceEventKind | 'all'>('all')

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
    }
  }

  return {
    tool_call_count,
    broadcast_count,
    task_completed_count,
    task_claimed_count,
    total_cost_usd,
    active_duration_minutes: 0, // filled from timeline summary
  }
})

// ── Converters ─────────────────────────────────────────

function timelineEventToTrace(evt: AgentTimelineEvent): UnifiedTraceEvent {
  const ts = new Date(evt.ts).getTime()
  const detail = evt.detail ?? {}

  if (evt.type === 'broadcast') {
    const content = typeof detail.content === 'string' ? detail.content : ''
    // Skip trivial heartbeat-like broadcasts
    if (content.length <= 20) {
      return {
        id: `tl-${ts}-hb`,
        ts,
        ts_iso: evt.ts,
        kind: 'heartbeat',
        summary: content || 'heartbeat',
        detail,
      }
    }
    return {
      id: `tl-${ts}-bc`,
      ts,
      ts_iso: evt.ts,
      kind: 'broadcast',
      summary: content.slice(0, 120),
      detail,
    }
  }

  // task_claimed, task_started, task_completed, task_cancelled
  const title = typeof detail.title === 'string' ? detail.title : ''
  const taskId = typeof detail.task_id === 'string' ? detail.task_id : ''
  return {
    id: `tl-${ts}-${evt.type}`,
    ts,
    ts_iso: evt.ts,
    kind: 'task',
    summary: `${evt.type.replace('task_', '')} ${taskId} ${title}`.trim(),
    detail: { ...detail, type: evt.type },
  }
}

function trajectoryEntryToTrace(entry: TrajectoryEntry): UnifiedTraceEvent {
  const ts = typeof entry.ts === 'number' ? entry.ts : new Date(entry.ts_iso).getTime()
  return {
    id: `tj-${ts}-${entry.tool_name}-${entry.round}`,
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
  traceAgentName.value = agentName
  traceLoading.value = true
  traceError.value = null

  try {
    const timelinePromise = fetchAgentTimeline(agentName, TIMELINE_HOURS, TIMELINE_LIMIT)
    const trajectoryPromise = isKeeper
      ? fetchKeeperTrajectory(agentName, TRAJECTORY_LIMIT)
      : Promise.resolve(null)

    const [timeline, trajectory] = await Promise.all([timelinePromise, trajectoryPromise])

    // Convert timeline events
    const timelineTraces = (timeline.events ?? []).map(timelineEventToTrace)

    // Convert trajectory entries
    const trajectoryTraces = trajectory
      ? trajectory.entries.map(trajectoryEntryToTrace)
      : []

    // Merge and sort by timestamp (ascending = oldest first)
    const merged = [...timelineTraces, ...trajectoryTraces]
    merged.sort((a, b) => a.ts - b.ts)

    // Deduplicate by id
    const seen = new Set<string>()
    const deduped = merged.filter(e => {
      if (seen.has(e.id)) return false
      seen.add(e.id)
      return true
    })

    traceEvents.value = deduped
    traceLoading.value = false
  } catch (err) {
    traceError.value = err instanceof Error ? err.message : 'fetch failed'
    traceLoading.value = false
  }
}

export function appendLiveEvent(event: UnifiedTraceEvent): void {
  if (!traceAgentName.value) return
  const existing = traceEvents.value
  // Append and maintain sort order (new event is likely the latest)
  const updated = [...existing, event]
  // Dedup check
  const seen = new Set<string>()
  traceEvents.value = updated.filter(e => {
    if (seen.has(e.id)) return false
    seen.add(e.id)
    return true
  })
}

export function closeSessionTrace(): void {
  traceAgentName.value = null
  traceEvents.value = []
  traceFilter.value = 'all'
  traceError.value = null
}
