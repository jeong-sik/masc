// Session trace state — unified event store for GitHub Agents-style trace view.
// Merges agent-timeline (broadcast/task), canonical keeper trajectory,
// tool-call provenance, and live OAS runtime SSE events into one chronological
// event stream. Tool-call provenance never replaces Trajectory-owned I/O.
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
  TrajectoryThinkingBlock,
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

export type TraceStatus = 'success' | 'failure'

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
  turn?: number
  round?: number
  cost_usd?: number
  error?: string | null
  // RFC-0233: canonical execution identity — same id across trajectory,
  // tool_call log, and oas-event rows for one physical execution.
  // Source rows without this identity remain independent observations.
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
  observationErrors?: string[]
  filter: TraceEventKind | 'all'
  statusFilter: TraceStatus | 'all'
  searchQuery: string
  /** Monotonic fetch token — used to discard stale in-flight responses. */
  fetchToken: number
}

// ── Per-agent state map ────────────────────────────────

export const traceSlots = signal<Record<string, TraceSlot>>({})

const EMPTY_SLOT: TraceSlot = { events: [], loading: false, error: null, filter: 'all', statusFilter: 'all', searchQuery: '', fetchToken: 0 }

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

export function getTraceObservationErrors(agent: string): string[] {
  return getSlot(agent).observationErrors ?? []
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
  for (const e of events) {
    const s = getEventStatus(e)
    if (s === 'success') success++
    else if (s === 'failure') failure++
  }
  return { all: success + failure, success, failure }
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

function reasoningDetailText(detail: unknown): string {
  if (detail === null || typeof detail !== 'object' || Array.isArray(detail)) return ''
  const text = (detail as Record<string, unknown>).text
  return typeof text === 'string' ? text : ''
}

function thinkingBlockText(block: TrajectoryThinkingBlock): string | undefined {
  switch (block.type) {
    case 'thinking':
      return block.thinking
    case 'reasoning_details':
      if (block.reasoning_content !== undefined && block.reasoning_content !== '') {
        return block.reasoning_content
      }
      return block.details.map(reasoningDetailText).join('')
    case 'redacted_thinking':
      return undefined
  }
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

function toolCallProvenanceDetail(entry: ToolCallEntry): Record<string, unknown> {
  const detail: Record<string, unknown> = {}
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

function toolCallSourceDetail(entry: ToolCallEntry): Record<string, unknown> {
  return { trace_origin: 'tool_call_log', ...toolCallProvenanceDetail(entry) }
}

function findExactToolCallEntryMatch(
  entries: ToolCallEntry[],
  event: UnifiedTraceEvent,
  usedIndexes: Set<number>,
): number | null {
  if (event.kind !== 'tool_call' || !event.executionId) return null
  for (let index = 0; index < entries.length; index++) {
    if (usedIndexes.has(index)) continue
    const entry = entries[index]!
    if (entry.execution_id === event.executionId) return index
  }
  return null
}

function enrichToolCallTrace(
  event: UnifiedTraceEvent,
  entry: ToolCallEntry,
): UnifiedTraceEvent {
  return {
    ...event,
    agentName: entry.keeper,
    sessionId: entry.session_id ?? event.sessionId ?? null,
    detail: {
      ...event.detail,
      trace_origin: 'trajectory+tool_call_log',
      tool_call_log: toolCallProvenanceDetail(entry),
    },
  }
}

function toolCallEntryToSyntheticTrace(entry: ToolCallEntry, index: number): UnifiedTraceEvent {
  const ts = entry.ts * 1000
  const outputText = formatToolCallOutput(entry)
  return {
    // execution_id is unique per physical execution and survives refetch.
    // Unidentified log rows remain explicit source-local observations.
    id: entry.execution_id
      ? `tc-${entry.execution_id}`
      : `tc-${entry.trace_id ?? 'no-trace'}-${entry.session_id ?? 'no-session'}-${entry.tool}-${Math.round(ts)}-${entry.turn ?? entry.keeper_turn_id ?? index}`,
    ts,
    ts_iso: new Date(ts).toISOString(),
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: entry.tool,
    detail: toolCallSourceDetail(entry),
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

function toolCallsShareExecutionId(
  canonical: UnifiedTraceEvent,
  timeline: UnifiedTraceEvent,
): boolean {
  if (canonical.kind !== 'tool_call' || timeline.kind !== 'tool_call') return false
  return canonical.executionId !== undefined
    && timeline.executionId !== undefined
    && canonical.executionId === timeline.executionId
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
    const executionId = stringField(detail.execution_id)
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
      executionId,
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

  // Handle thinking entries (type === 'thinking')
  if (entry.type === 'thinking') {
    const redacted = entry.block.type === 'redacted_thinking'
    const content = thinkingBlockText(entry.block)
    return {
      id: `tj-${ts}-thinking-T${entry.turn}-B${entry.block_index}-${index}`,
      ts,
      ts_iso: entry.ts_iso,
      kind: 'thinking',
      sourceLane: 'masc',
      summary: redacted ? '[비공개 사고]' : (content?.slice(0, 120) ?? ''),
      detail: { ...detail, block_index: entry.block_index, block: entry.block },
      turn: entry.turn,
      thinkingContent: content,
      thinkingRedacted: redacted,
    }
  }

  detail.execution_id = entry.execution_id
  const toolResult = entry.outcome.status === 'succeeded' ? entry.outcome.output : null
  const error = entry.outcome.status === 'failed' ? entry.outcome.error : null

  return {
    id: `tj-${entry.execution_id}`,
    ts,
    ts_iso: entry.ts_iso,
    kind: 'tool_call',
    sourceLane: 'masc',
    summary: entry.tool_name ?? 'unknown',
    detail,
    toolName: entry.tool_name,
    toolArgs: entry.args,
    toolResult,
    duration_ms: entry.duration_ms,
    turn: entry.turn,
    round: entry.round,
    executionId: entry.execution_id,
    error,
  }
}

// ── Pure merge function (reusable by task-detail) ──────

/** Build a deduplicated, time-sorted trace from timeline + trajectory data.
 *  Extracted from loadSessionTrace for reuse in task detail overlay. */
export function buildTraceEvents(
  timeline: AgentTimelineResponse | null,
  trajectory: TrajectoryResponse | null,
  toolCalls: ToolCallsResponse | null = null,
): UnifiedTraceEvent[] {
  const timelineTraces = (timeline?.events ?? []).map(timelineEventToTrace)
  const trajectoryTraces = trajectory
    ? (trajectory.entries ?? []).map((entry, index) =>
        trajectoryEntryToTrace(entry, index, trajectory.trace_id),
      )
    : []
  const toolCallEntries = toolCalls?.entries ?? []
  const usedToolCallIndexes = new Set<number>()

  const mergedTrajectoryTraces = trajectoryTraces.map((event) => {
    if (event.kind !== 'tool_call') return event
    const matchedIndex = findExactToolCallEntryMatch(
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
    return !richerToolCallTraces.some((canonical) =>
      toolCallsShareExecutionId(canonical, event),
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
  patchSlot(agentName, {
    loading: true,
    error: null,
    observationErrors: [],
    fetchToken: token,
  })
  ensureLiveTraceSlot(agentName)

  try {
    const timelinePromise = fetchAgentTimeline(agentName, TIMELINE_HOURS, TIMELINE_LIMIT)
    const trajectoryPromise = isKeeper
      ? fetchKeeperTrajectory(agentName, TRAJECTORY_LIMIT)
      : Promise.resolve(null)
    const toolCallsPromise = isKeeper
      ? fetchKeeperToolCalls(agentName, TOOL_CALL_LIMIT)
      : Promise.resolve(null)

    const [timelineResult, trajectoryResult, toolCallsResult] = await Promise.allSettled([
      timelinePromise,
      trajectoryPromise,
      toolCallsPromise,
    ])

    // Discard result if slot was closed or a newer fetch was started during await.
    if (getSlot(agentName).fetchToken !== token) return

    const timeline = timelineResult.status === 'fulfilled' ? timelineResult.value : null
    const trajectory = trajectoryResult.status === 'fulfilled' ? trajectoryResult.value : null
    const toolCalls = toolCallsResult.status === 'fulfilled' ? toolCallsResult.value : null
    const sourceErrors = [
      ...(timelineResult.status === 'rejected'
        ? [`agent timeline read failed: ${timelineResult.reason instanceof Error ? timelineResult.reason.message : String(timelineResult.reason)}`]
        : []),
      ...(trajectoryResult.status === 'rejected'
        ? [`trajectory read failed: ${trajectoryResult.reason instanceof Error ? trajectoryResult.reason.message : String(trajectoryResult.reason)}`]
        : []),
      ...(toolCallsResult.status === 'rejected'
        ? [`tool-call log read failed: ${toolCallsResult.reason instanceof Error ? toolCallsResult.reason.message : String(toolCallsResult.reason)}`]
        : []),
    ]
    const deduped = buildTraceEvents(timeline, trajectory, toolCalls)
    const observationErrors = [
      ...sourceErrors,
      ...(trajectory === null
        ? []
        : [
          ...(trajectory.decode.invalid_line_count > 0
            ? [`trajectory decode invalid ${trajectory.decode.invalid_line_count} rows ${JSON.stringify(trajectory.decode.invalid_reasons)}`]
            : []),
          ...trajectory.io_errors.map(error => `trajectory read failed ${error.path}: ${error.message}`),
        ]),
    ]

    // Final stale check before writing
    if (getSlot(agentName).fetchToken !== token) return

    patchSlot(agentName, { events: deduped, loading: false, observationErrors })
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
