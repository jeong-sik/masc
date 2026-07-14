// Session trace state — unified event store for GitHub Agents-style trace view.
// Merges agent-timeline (broadcast/task), keeper-trajectory (turn/thinking),
// keeper tool-call log (full I/O), and live OAS runtime SSE events into a
// single chronological event stream.
// State is keyed per agent to avoid cross-overlay collisions.
// Each SessionTraceView instance passes its own agentName to derived helpers.

import { signal } from '@preact/signals'
import {
  fetchAgentTimeline,
  fetchKeeperToolCalls,
  fetchKeeperTrajectory,
} from '../../api/dashboard'
import {
  deleteLiveTraceSlot,
  ensureLiveTraceSlot,
  liveTraceFeeds,
  registerLiveTraceHistoricalIdsProvider,
  registerLiveTraceSlotProvider,
} from './session-trace-live-store'
import type {
  AgentTimelineEvent,
  AgentTimelineResponse,
  ToolCallEntry,
  ToolCallsResponse,
  TrajectoryEntry,
  TrajectoryResponse,
} from '../../api/dashboard'

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

export type TraceStatus = 'success' | 'failure' | 'gate_rejected'

type TraceSourceLane = 'masc' | 'oas'

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
  // RFC-0233: canonical execution identity — same id across trajectory,
  // tool_call log, and oas-event rows for one physical execution.
  // Absent on rows written before PR-1 and on timeline rows.
  executionId?: string
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
  oas_cache_creation_tokens: number
  oas_cache_read_tokens: number
  oas_cache_miss_input_tokens: number
  oas_llm_call_count: number
  oas_error_count: number
  oas_tokens_saved: number
}

interface TraceSlot {
  events: UnifiedTraceEvent[]
  loading: boolean
  error: string | null
  filter: TraceEventKind | 'all'
  statusFilter: TraceStatus | 'all'
  searchQuery: string
  /** Monotonic fetch token — used to discard stale in-flight responses. */
  fetchToken: number
}

// ── Per-agent state map ────────────────────────────────

export const traceSlots = signal<Record<string, TraceSlot>>({})

const EMPTY_SLOT: TraceSlot = { events: [], loading: false, error: null, filter: 'all', statusFilter: 'all', searchQuery: '', fetchToken: 0 }

const TOOL_CALL_MATCH_WINDOW_MS = 2000

registerLiveTraceHistoricalIdsProvider((agentName) =>
  traceSlots.value[agentName]?.events.map(item => item.id) ?? [],
)
registerLiveTraceSlotProvider((agentName) => traceSlots.value[agentName] != null)

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

export function getTraceStatusFilter(agent: string): TraceStatus | 'all' {
  return getSlot(agent).statusFilter
}

export function getTraceSearchQuery(agent: string): string {
  return getSlot(agent).searchQuery
}

// ── Status classification ────────────────────────────────

function getEventStatus(e: UnifiedTraceEvent): TraceStatus | null {
  if (e.gate?.status === 'reject') return 'gate_rejected'
  if (e.error) return 'failure'
  if (e.kind === 'tool_call' || e.kind === 'oas_tool') return 'success'
  return null
}

// ── Search matching ──────────────────────────────────────

function eventMatchesSearch(e: UnifiedTraceEvent, query: string): boolean {
  const q = query.toLowerCase()
  const fields = [
    e.summary,
    e.toolName,
    e.error,
    e.thinkingContent,
    e.toolResult?.slice(0, 500),
    ...Object.values(e.detail).map(v => typeof v === 'string' ? v : ''),
  ]
  return fields.some(f => f != null && f.toLowerCase().includes(q))
}

export function getFilteredEvents(agent: string): UnifiedTraceEvent[] {
  const slot = getSlot(agent)
  let events = getTraceEvents(agent)
  if (slot.filter !== 'all') {
    events = events.filter(e => e.kind === slot.filter)
  }
  if (slot.statusFilter !== 'all') {
    events = events.filter(e => getEventStatus(e) === slot.statusFilter)
  }
  if (slot.searchQuery) {
    events = events.filter(e => eventMatchesSearch(e, slot.searchQuery))
  }
  return events
}

export function getStatusCounts(agent: string): Record<TraceStatus | 'all', number> {
  const events = getTraceEvents(agent)
  let success = 0
  let failure = 0
  let gate_rejected = 0
  for (const e of events) {
    const s = getEventStatus(e)
    if (s === 'success') success++
    else if (s === 'failure') failure++
    else if (s === 'gate_rejected') gate_rejected++
  }
  return { all: success + failure + gate_rejected, success, failure, gate_rejected }
}

function detailNumber(detail: Record<string, unknown>, ...keys: string[]): number | null {
  for (const key of keys) {
    const value = detail[key]
    if (typeof value === 'number' && Number.isFinite(value)) return value
  }
  return null
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
  let oas_cache_creation_tokens = 0
  let oas_cache_read_tokens = 0
  let oas_cache_miss_input_tokens = 0
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
          const inTok = detailNumber(e.detail, 'input_tokens')
          const outTok = detailNumber(e.detail, 'output_tokens')
          const cacheCreation = detailNumber(
            e.detail,
            'cache_creation_tokens',
            'cache_creation_input_tokens',
          )
          const cacheRead = detailNumber(
            e.detail,
            'cache_read_tokens',
            'cache_read_input_tokens',
          )
          const cacheMiss =
            detailNumber(e.detail, 'cache_miss_input_tokens')
            ?? (
              inTok != null && (cacheCreation != null || cacheRead != null)
                ? Math.max(0, inTok - (cacheCreation ?? 0) - (cacheRead ?? 0))
                : null
            )
          if (inTok != null) oas_input_tokens += inTok
          if (outTok != null) oas_output_tokens += outTok
          if (cacheCreation != null) oas_cache_creation_tokens += cacheCreation
          if (cacheRead != null) oas_cache_read_tokens += cacheRead
          if (cacheMiss != null) oas_cache_miss_input_tokens += cacheMiss
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
    oas_cache_creation_tokens,
    oas_cache_read_tokens,
    oas_cache_miss_input_tokens,
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

// ── Filter action ──────────────────────────────────────

export function setTraceFilter(agent: string, filter: TraceEventKind | 'all'): void {
  patchSlot(agent, { filter })
}

export function setTraceStatusFilter(agent: string, statusFilter: TraceStatus | 'all'): void {
  patchSlot(agent, { statusFilter })
}

export function setTraceSearchQuery(agent: string, searchQuery: string): void {
  patchSlot(agent, { searchQuery })
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
  merged.sort((a, b) => b.ts - a.ts)
  const seen = new Set<string>()
  return merged.filter(event => {
    if (seen.has(event.id)) return false
    seen.add(event.id)
    return true
  })
}

function stringField(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

function numberField(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function normalizeToolCallInput(input: unknown): Record<string, unknown> | string | undefined {
  if (typeof input === 'string') return input
  if (input != null && typeof input === 'object') return input as Record<string, unknown>
  if (input == null) return undefined
  try {
    return JSON.stringify(input)
  } catch {
    return String(input)
  }
}

function formatToolCallOutput(entry: ToolCallEntry): string {
  if (typeof entry.output === 'string') return entry.output
  const { sha256, bytes, mime, preview } = entry.output._blob
  return `[masc:blob sha256=${sha256.slice(0, 12)}... bytes=${bytes} mime=${mime}]\n${preview}`
}

function toolCallMetadataDetail(entry: ToolCallEntry, traceOrigin: string): Record<string, unknown> {
  const detail: Record<string, unknown> = { trace_origin: traceOrigin }
  if (entry.trace_id) detail.trace_id = entry.trace_id
  if (entry.session_id) detail.session_id = entry.session_id
  if (entry.turn != null) detail.turn = entry.turn
  if (entry.keeper_turn_id != null) detail.keeper_turn_id = entry.keeper_turn_id
  if (entry.task_id) detail.task_id = entry.task_id
  if (entry.lane) detail.lane = entry.lane
  if (entry.model) detail.model = entry.model
  if (entry.execution_id) detail.execution_id = entry.execution_id
  return detail
}

function toolEventTraceId(event: UnifiedTraceEvent): string | undefined {
  return stringField(event.detail.trace_id)
}

function toolEventSessionId(event: UnifiedTraceEvent): string | undefined {
  return event.sessionId ?? stringField(event.detail.session_id)
}

function toolEventTurn(event: UnifiedTraceEvent): number | undefined {
  return event.turn
    ?? numberField(event.detail.turn)
    ?? numberField(event.detail.keeper_turn_id)
}

function toolEventSuccess(event: UnifiedTraceEvent): boolean {
  return event.gate?.status !== 'reject' && event.error == null
}

function toolCallEntryMatchesTraceEvent(
  entry: ToolCallEntry,
  event: UnifiedTraceEvent,
): boolean {
  if (event.kind !== 'tool_call' || !event.toolName) return false
  if (event.gate?.status === 'reject') return false

  // RFC-0233: when both sides carry the canonical execution_id, identity
  // equality is the whole answer — the heuristic below only exists for
  // rows written before the id was minted (no backfill by design).
  if (entry.execution_id && event.executionId) {
    return entry.execution_id === event.executionId
  }

  if (entry.tool !== event.toolName) return false

  const eventTraceId = toolEventTraceId(event)
  if (eventTraceId && entry.trace_id && eventTraceId !== entry.trace_id) return false

  const eventSessionId = toolEventSessionId(event)
  if (
    eventSessionId
    && entry.session_id
    && eventSessionId !== entry.session_id
    && !(eventTraceId && entry.trace_id && eventTraceId === entry.trace_id)
  ) {
    return false
  }

  const eventTurn = toolEventTurn(event)
  const entryTurn = entry.turn ?? entry.keeper_turn_id
  if (eventTurn != null && entryTurn != null && eventTurn !== entryTurn) return false

  if (
    event.duration_ms != null
    && entry.duration_ms != null
    && Math.abs(event.duration_ms - entry.duration_ms) > 1
  ) return false
  if (toolEventSuccess(event) !== entry.success) return false

  return Math.abs(event.ts - (entry.ts * 1000)) <= TOOL_CALL_MATCH_WINDOW_MS
}

function toolCallEntryMatchScore(entry: ToolCallEntry, event: UnifiedTraceEvent): number {
  let score = Math.abs(event.ts - (entry.ts * 1000))
  if (entry.execution_id && event.executionId && entry.execution_id === event.executionId) score -= 1_000_000
  if (toolEventTraceId(event) && entry.trace_id && toolEventTraceId(event) === entry.trace_id) score -= 500
  if (toolEventSessionId(event) && entry.session_id && toolEventSessionId(event) === entry.session_id) score -= 200
  if (toolEventTurn(event) != null && (entry.turn ?? entry.keeper_turn_id) === toolEventTurn(event)) score -= 100
  return score
}

function findBestToolCallEntryMatch(
  entries: ToolCallEntry[],
  event: UnifiedTraceEvent,
  usedIndexes: Set<number>,
): number | null {
  let bestIndex: number | null = null
  let bestScore = Number.POSITIVE_INFINITY
  for (let index = 0; index < entries.length; index++) {
    if (usedIndexes.has(index)) continue
    const entry = entries[index]!
    if (!toolCallEntryMatchesTraceEvent(entry, event)) continue
    const score = toolCallEntryMatchScore(entry, event)
    if (score < bestScore) {
      bestScore = score
      bestIndex = index
    }
  }
  return bestIndex
}

function enrichToolCallTrace(
  event: UnifiedTraceEvent,
  entry: ToolCallEntry,
): UnifiedTraceEvent {
  const outputText = formatToolCallOutput(entry)
  const error = entry.success ? null : outputText || event.error || 'tool call failed'
  return {
    ...event,
    agentName: entry.keeper,
    sessionId: entry.session_id ?? event.sessionId ?? null,
    summary: entry.tool,
    detail: { ...event.detail, ...toolCallMetadataDetail(entry, 'trajectory+tool_call_log') },
    toolName: entry.tool,
    toolArgs: normalizeToolCallInput(entry.input) ?? event.toolArgs,
    toolResult: entry.success ? outputText : null,
    duration_ms: entry.duration_ms ?? event.duration_ms,
    // Trajectory turn is trace-relative and pairs with `round`; the log's
    // session-absolute turn stays readable as detail.turn. Mixing the two
    // vocabularies in one T#R# badge would mislabel the row.
    turn: event.turn ?? entry.turn ?? entry.keeper_turn_id,
    executionId: entry.execution_id ?? event.executionId,
    error,
  }
}

function toolCallEntryToSyntheticTrace(entry: ToolCallEntry, index: number): UnifiedTraceEvent {
  const ts = entry.ts * 1000
  const outputText = formatToolCallOutput(entry)
  return {
    // execution_id is unique per physical execution — a stable row id that
    // survives refetch; the composite form remains for pre-PR-1 rows.
    id: entry.execution_id
      ? `tc-${entry.execution_id}`
      : `tc-${entry.trace_id ?? 'no-trace'}-${entry.session_id ?? 'no-session'}-${entry.tool}-${Math.round(ts)}-${entry.turn ?? entry.keeper_turn_id ?? index}`,
    ts,
    ts_iso: new Date(ts).toISOString(),
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: entry.tool,
    detail: toolCallMetadataDetail(entry, 'tool_call_log'),
    agentName: entry.keeper,
    sessionId: entry.session_id ?? null,
    toolName: entry.tool,
    toolArgs: normalizeToolCallInput(entry.input),
    toolResult: entry.success ? outputText : null,
    duration_ms: entry.duration_ms ?? undefined,
    turn: entry.turn ?? entry.keeper_turn_id,
    executionId: entry.execution_id,
    error: entry.success ? null : outputText || 'tool call failed',
  }
}

function richerToolCallMatchesFallback(
  richer: UnifiedTraceEvent,
  fallback: UnifiedTraceEvent,
): boolean {
  if (richer.kind !== 'tool_call' || fallback.kind !== 'tool_call') return false

  // RFC-0233: canonical identity decides when both rows carry it.
  if (richer.executionId && fallback.executionId) {
    return richer.executionId === fallback.executionId
  }

  if (!richer.toolName || !fallback.toolName) return false
  if (richer.toolName !== fallback.toolName) return false

  const richerTraceId = toolEventTraceId(richer)
  const fallbackTraceId = toolEventTraceId(fallback)
  if (richerTraceId && fallbackTraceId && richerTraceId !== fallbackTraceId) return false

  const richerSessionId = toolEventSessionId(richer)
  const fallbackSessionId = toolEventSessionId(fallback)
  if (
    richerSessionId
    && fallbackSessionId
    && richerSessionId !== fallbackSessionId
    && !(richerTraceId && fallbackTraceId && richerTraceId === fallbackTraceId)
  ) {
    return false
  }

  const richerTurn = toolEventTurn(richer)
  const fallbackTurn = toolEventTurn(fallback)
  if (richerTurn != null && fallbackTurn != null && richerTurn !== fallbackTurn) return false

  if (
    richer.duration_ms != null
    && fallback.duration_ms != null
    && Math.abs(richer.duration_ms - fallback.duration_ms) > 1
  ) {
    return false
  }

  if (toolEventSuccess(richer) !== toolEventSuccess(fallback)) return false

  return Math.abs(richer.ts - fallback.ts) <= TOOL_CALL_MATCH_WINDOW_MS
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

  if (evt.type === 'tool_call') {
    const toolName = stringField(detail.tool_name) ?? 'TOOL_CALL'
    const durationMs = numberField(detail.duration_ms)
    const toolArgsPreview = stringField(detail.tool_args_preview)
    const toolOutputPreview = stringField(detail.tool_output_preview)
    const explicitSuccess = typeof detail.success === 'boolean' ? detail.success : undefined
    const errorText = stringField(detail.error)
    const success = explicitSuccess ?? (errorText == null)
    return {
      id: `tl-${ts}-${evt.type}-${index}`,
      ts,
      ts_iso: evt.ts ?? new Date(ts).toISOString(),
      kind: 'tool_call',
      sourceLane: 'masc',
      summary: toolName,
      detail: { ...detail, type: evt.type, trace_origin: 'agent_timeline' },
      sessionId: stringField(detail.session_id) ?? null,
      operationId: stringField(detail.operation_id) ?? null,
      toolName,
      toolArgs: toolArgsPreview,
      toolResult: success ? (toolOutputPreview ?? null) : null,
      duration_ms: durationMs,
      error: success ? null : (errorText ?? toolOutputPreview ?? 'tool call failed'),
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

function trajectoryEntryToTrace(
  entry: TrajectoryEntry,
  index: number,
  traceId?: string,
): UnifiedTraceEvent {
  // Backend sends `ts` in seconds (Unix float); normalize to milliseconds for sorting.
  const ts = typeof entry.ts === 'number' ? entry.ts * 1000 : safeTimestamp(entry.ts_iso)
  const detail: Record<string, unknown> = traceId ? { trace_id: traceId, trace_origin: 'trajectory' } : { trace_origin: 'trajectory' }
  if (entry.execution_id) detail.execution_id = entry.execution_id

  // Handle thinking entries (type === 'thinking')
  if (entry.type === 'thinking') {
    return {
      id: `tj-${ts}-thinking-T${entry.turn}-${index}`,
      ts,
      ts_iso: entry.ts_iso,
      kind: 'thinking',
      sourceLane: 'masc',
      summary: entry.redacted ? '[비공개 사고]' : (entry.content?.slice(0, 120) ?? ''),
      detail,
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
    detail,
    toolName: entry.tool_name,
    toolArgs: entry.args,
    toolResult: entry.result,
    duration_ms: entry.duration_ms,
    gate: entry.gate,
    turn: entry.turn,
    round: entry.round,
    cost_usd: entry.cost_usd,
    executionId: entry.execution_id,
    error: entry.error,
  }
}

// ── Pure merge function (reusable by task-detail) ──────

/** Build a deduplicated, time-sorted trace from timeline + trajectory data.
 *  Extracted from loadSessionTrace for reuse in task detail overlay. */
export function buildTraceEvents(
  timeline: AgentTimelineResponse,
  trajectory: TrajectoryResponse | null,
  toolCalls: ToolCallsResponse | null = null,
): UnifiedTraceEvent[] {
  const timelineTraces = (timeline.events ?? []).map(timelineEventToTrace)
  const trajectoryTraces = trajectory
    ? (trajectory.entries ?? []).map((entry, index) =>
        trajectoryEntryToTrace(entry, index, trajectory.trace_id),
      )
    : []
  const toolCallEntries = toolCalls?.entries ?? []
  const usedToolCallIndexes = new Set<number>()

  const mergedTrajectoryTraces = trajectoryTraces.map((event) => {
    if (event.kind !== 'tool_call') return event
    const matchedIndex = findBestToolCallEntryMatch(
      toolCallEntries,
      event,
      usedToolCallIndexes,
    )
    if (matchedIndex == null) return event
    usedToolCallIndexes.add(matchedIndex)
    return enrichToolCallTrace(event, toolCallEntries[matchedIndex]!)
  })

  const syntheticToolCallTraces = toolCallEntries.flatMap((entry, index) =>
    usedToolCallIndexes.has(index) ? [] : [toolCallEntryToSyntheticTrace(entry, index)],
  )

  const richerToolCallTraces = [
    ...mergedTrajectoryTraces.filter((event) => event.kind === 'tool_call'),
    ...syntheticToolCallTraces,
  ]
  const filteredTimelineTraces = timelineTraces.filter((event) => {
    if (event.kind !== 'tool_call') return true
    return !richerToolCallTraces.some((richer) =>
      richerToolCallMatchesFallback(richer, event),
    )
  })

  return mergeTraceEvents(
    [...filteredTimelineTraces, ...mergedTrajectoryTraces, ...syntheticToolCallTraces],
    [],
  )
}

// ── Actions ────────────────────────────────────────────

const TIMELINE_HOURS = 24
const TIMELINE_LIMIT = 200
const TRAJECTORY_LIMIT = 100
const TOOL_CALL_LIMIT = 100
const SESSION_TRACE_RELOAD_DEBOUNCE_MS = 1_000

const sessionTraceReloadTimers = new Map<string, ReturnType<typeof setTimeout>>()

export async function loadSessionTrace(agentName: string, isKeeper: boolean): Promise<void> {
  // Bump fetch token for this agent — any prior in-flight fetch becomes stale.
  const prevSlot = getSlot(agentName)
  const token = prevSlot.fetchToken + 1
  patchSlot(agentName, { loading: true, error: null, fetchToken: token })
  ensureLiveTraceSlot(agentName)

  try {
    const timelinePromise = fetchAgentTimeline(agentName, TIMELINE_HOURS, TIMELINE_LIMIT)
    const trajectoryPromise = isKeeper
      ? fetchKeeperTrajectory(agentName, TRAJECTORY_LIMIT, true, true)
      : Promise.resolve(null)
    const toolCallsPromise = isKeeper
      ? fetchKeeperToolCalls(agentName, TOOL_CALL_LIMIT)
      : Promise.resolve(null)

    const [timeline, trajectory, toolCalls] = await Promise.all([
      timelinePromise,
      trajectoryPromise,
      toolCallsPromise,
    ])

    // Discard result if slot was closed or a newer fetch was started during await.
    if (getSlot(agentName).fetchToken !== token) return

    const deduped = buildTraceEvents(timeline, trajectory, toolCalls)

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

export function scheduleSessionTraceReload(
  agentName: string,
  isKeeper: boolean,
  delayMs = SESSION_TRACE_RELOAD_DEBOUNCE_MS,
): void {
  if (traceSlots.value[agentName] == null) return

  const existing = sessionTraceReloadTimers.get(agentName)
  if (existing != null) clearTimeout(existing)

  const timer = setTimeout(() => {
    sessionTraceReloadTimers.delete(agentName)
    if (traceSlots.value[agentName] == null) return
    void loadSessionTrace(agentName, isKeeper)
  }, delayMs)
  sessionTraceReloadTimers.set(agentName, timer)
}

export function closeSessionTrace(agentName: string): void {
  const timer = sessionTraceReloadTimers.get(agentName)
  if (timer != null) {
    clearTimeout(timer)
    sessionTraceReloadTimers.delete(agentName)
  }
  const next = { ...traceSlots.value }
  delete next[agentName]
  traceSlots.value = next
  deleteLiveTraceSlot(agentName)
}
