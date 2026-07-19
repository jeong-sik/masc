import type {
  AgentTimelineResponse,
  ToolCallsResponse,
  TrajectoryResponse,
  TrajectoryToolSchedule,
} from '../api/dashboard'
import type { KeeperRuntimeTraceResponse } from '../api/keeper'
import { asNullableString, asRecord } from './common/normalize'
import type { Keeper } from '../types'
import { keeperPriority as classifyKeeperPriority } from '../lib/keeper-classifiers'
import {
  buildTraceEvents,
  type UnifiedTraceEvent,
} from './session-trace/session-trace-state'

type WaterfallEntryKind = 'thinking' | 'tool_call' | 'provenance_gap'
type WaterfallEntryStatus = 'success' | 'failure' | 'gap' | 'unknown'
type WaterfallEntrySource = 'trajectory' | 'agent_timeline' | 'tool_call_log' | 'unknown'

export interface JourneyWaterfallEntry {
  id: string
  kind: WaterfallEntryKind
  status: WaterfallEntryStatus
  source: WaterfallEntrySource
  ts: number
  tsIso: string
  keeperTurnId: number | null
  oasTurn: number | null
  blockIndex: number | null
  toolSchedule: TrajectoryToolSchedule | null
  summary: string
  toolName: string | null
  toolArgs: Record<string, unknown> | string | null
  toolResult: string | null
  thinkingContent: string | null
  thinkingRedacted: boolean
  durationMs: number | null
  error: string | null
  sessionId: string | null
  traceId: string | null
  hasToolCallLogProvenance: boolean
}

export interface JourneyWaterfallRuntimeEvidence {
  health: string
  staleReason: string | null
  traceId: string
  keeperTurnId: number | null
  maxOasTurnCount: number | null
  providerTerminalStatus: string | null
  providerTerminalExceptionKind: string | null
  providerAttemptStartedCount: number
  providerAttemptFinishedCount: number
  eventBusCorrelatedCount: number
  contextCompactedCount: number
  contextCompactStartedCount: number
  memoryInjectedCount: number
  memoryFlushedCount: number
}

export interface JourneyWaterfallTurn {
  key: string
  keeperTurnId: number | null
  label: string
  startTs: number
  endTs: number
  entries: JourneyWaterfallEntry[]
  thinkingCount: number
  toolCallCount: number
  failureCount: number
  provenanceGapCount: number
  totalDurationMs: number
  runtimeEvidence: JourneyWaterfallRuntimeEvidence | null
}

export interface JourneyWaterfallSummary {
  totalTurns: number
  totalEntries: number
  thinkingCount: number
  toolCallCount: number
  failureCount: number
  provenanceGapCount: number
  totalDurationMs: number
  timelineStartTs: number | null
  timelineEndTs: number | null
  runtimeEvidence: JourneyWaterfallRuntimeEvidence | null
}

export interface JourneyWaterfallModel {
  keeper: string
  turns: JourneyWaterfallTurn[]
  summary: JourneyWaterfallSummary
}

export interface JourneyWaterfallInput {
  keeper: string
  trajectory: TrajectoryResponse | null
  toolCalls: ToolCallsResponse | null
  runtimeTrace: KeeperRuntimeTraceResponse | null
}

const EMPTY_TIMELINE: AgentTimelineResponse = {
  agent: '',
  period: {
    from: '',
    to: '',
  },
  events: [],
  summary: {
    tasks_completed: 0,
    tasks_claimed: 0,
    messages_sent: 0,
    tool_calls: 0,
    active_duration_minutes: 0,
    total_events: 0,
  },
}

function numberValue(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function traceEventSource(event: UnifiedTraceEvent): WaterfallEntrySource {
  if (event.detail.observation_kind === 'provenance_gap') {
    const source = asNullableString(event.detail.source)
    if (source === 'agent_timeline' || source === 'tool_call_log') return source
    return 'unknown'
  }
  const origin = asNullableString(event.detail.trace_origin)
  if (origin === 'trajectory') return 'trajectory'
  return 'unknown'
}

function traceEventTraceId(event: UnifiedTraceEvent): string | null {
  const direct = asNullableString(event.detail.trace_id)
  if (direct !== null) return direct
  const toolCallLog = asRecord(event.detail.tool_call_log)
  return asNullableString(toolCallLog?.trace_id)
}

function traceEventStatus(event: UnifiedTraceEvent): WaterfallEntryStatus {
  if (event.detail.observation_kind === 'provenance_gap') return 'gap'
  if (event.error) return 'failure'
  if (event.kind === 'tool_call') return 'success'
  return 'unknown'
}

function entryFromTraceEvent(event: UnifiedTraceEvent): JourneyWaterfallEntry | null {
  const isProvenanceGap = event.detail.observation_kind === 'provenance_gap'
  if (event.kind !== 'tool_call' && event.kind !== 'thinking' && !isProvenanceGap) return null
  const status = traceEventStatus(event)
  return {
    id: event.id,
    kind: isProvenanceGap ? 'provenance_gap' : event.kind as 'tool_call' | 'thinking',
    status,
    source: traceEventSource(event),
    ts: event.ts,
    tsIso: event.ts_iso,
    keeperTurnId: event.keeperTurnId ?? null,
    oasTurn: event.oasTurn ?? null,
    blockIndex: numberValue(event.detail.block_index),
    toolSchedule: event.toolSchedule ?? null,
    summary: event.summary,
    toolName: event.toolName ?? asNullableString(event.detail.provenance_tool_name),
    toolArgs: event.toolArgs ?? null,
    toolResult: event.toolResult ?? null,
    thinkingContent: event.thinkingContent ?? null,
    thinkingRedacted: event.thinkingRedacted === true,
    durationMs: event.duration_ms ?? null,
    error: event.error ?? null,
    sessionId: event.sessionId ?? null,
    traceId: traceEventTraceId(event),
    hasToolCallLogProvenance: asRecord(event.detail.tool_call_log) !== null,
  }
}

function runtimeKeeperTurnId(trace: KeeperRuntimeTraceResponse | null): number | null {
  if (!trace) return null
  return trace.runtime_lens.turn_clock.keeper_turn_id
    ?? trace.turn_identity.requested_keeper_turn_id
    ?? trace.turn_id
    ?? trace.turn_identity.manifest_keeper_turn_ids.at(-1)
    ?? null
}

export function summarizeRuntimeTrace(
  trace: KeeperRuntimeTraceResponse | null,
): JourneyWaterfallRuntimeEvidence | null {
  if (!trace) return null
  const clock = trace.runtime_lens.turn_clock
  return {
    health: trace.health || 'unknown',
    staleReason: trace.stale_reason,
    traceId: trace.trace_id,
    keeperTurnId: runtimeKeeperTurnId(trace),
    maxOasTurnCount: clock.max_oas_turn_count ?? trace.turn_identity.max_oas_turn_count,
    providerTerminalStatus: trace.provider_attempts.terminal_status,
    providerTerminalExceptionKind: trace.provider_attempts.terminal_exception_kind,
    providerAttemptStartedCount: trace.provider_attempts.started_count,
    providerAttemptFinishedCount: trace.provider_attempts.finished_count,
    eventBusCorrelatedCount: trace.event_bus.event_bus_correlated_count,
    contextCompactedCount: trace.event_bus.context_compacted_count,
    contextCompactStartedCount: trace.event_bus.context_compact_started_count,
    memoryInjectedCount: trace.memory.memory_injected_count,
    memoryFlushedCount: trace.memory.memory_flushed_count,
  }
}

function turnKey(keeperTurnId: number | null): string {
  return keeperTurnId == null ? 'keeper-turn-unrecorded' : `keeper-turn-${keeperTurnId}`
}

function turnLabel(keeperTurnId: number | null): string {
  return keeperTurnId == null ? 'Keeper Turn not recorded' : `Keeper Turn ${keeperTurnId}`
}

function compareOptionalClock(left: number | null, right: number | null): number {
  if (left === null) return right === null ? 0 : 1
  if (right === null) return -1
  return left - right
}

function compareWaterfallEntries(
  left: JourneyWaterfallEntry,
  right: JourneyWaterfallEntry,
): number {
  const oasTurnOrder = compareOptionalClock(left.oasTurn, right.oasTurn)
  if (oasTurnOrder !== 0) return oasTurnOrder

  // One OAS turn first receives the complete provider response, then executes
  // its planned Tools. AfterTurn persists Thinking later in wall-clock time,
  // so timestamps would reverse that causal order. Keep the two exact partial
  // orders separate: provider block_index, then Tool schedule.
  const phaseOrder = (entry: JourneyWaterfallEntry): number => {
    if (entry.kind === 'thinking') return 0
    if (entry.kind === 'tool_call') return 1
    return 2
  }
  const phaseDifference = phaseOrder(left) - phaseOrder(right)
  if (phaseDifference !== 0) return phaseDifference
  if (left.kind === 'thinking' && right.kind === 'thinking') {
    return compareOptionalClock(left.blockIndex, right.blockIndex)
  }
  if (left.toolSchedule && right.toolSchedule) {
    const batchOrder = left.toolSchedule.batch_index - right.toolSchedule.batch_index
    if (batchOrder !== 0) return batchOrder
    const plannedOrder = left.toolSchedule.planned_index - right.toolSchedule.planned_index
    if (plannedOrder !== 0) return plannedOrder
    return 0
  }
  return left.ts - right.ts
}

function buildTurn(
  key: string,
  keeperTurnId: number | null,
  entries: JourneyWaterfallEntry[],
  runtimeEvidence: JourneyWaterfallRuntimeEvidence | null,
): JourneyWaterfallTurn {
  const sortedEntries = entries.slice().sort(compareWaterfallEntries)
  let startTs = 0
  let endTs = 0
  if (sortedEntries.length > 0) {
    startTs = sortedEntries[0]!.ts
    endTs = startTs
    for (const entry of sortedEntries) {
      startTs = Math.min(startTs, entry.ts)
      endTs = Math.max(endTs, entry.ts)
    }
  }
  const toolEntries = sortedEntries.filter(entry => entry.kind === 'tool_call')
  return {
    key,
    keeperTurnId,
    label: turnLabel(keeperTurnId),
    startTs,
    endTs,
    entries: sortedEntries,
    thinkingCount: sortedEntries.filter(entry => entry.kind === 'thinking').length,
    toolCallCount: toolEntries.length,
    failureCount: sortedEntries.filter(entry => entry.status === 'failure').length,
    provenanceGapCount: sortedEntries.filter(entry => entry.kind === 'provenance_gap').length,
    totalDurationMs: toolEntries.reduce((sum, entry) => sum + (entry.durationMs ?? 0), 0),
    runtimeEvidence,
  }
}

export function buildJourneyWaterfall(input: JourneyWaterfallInput): JourneyWaterfallModel {
  const traceEvents = buildTraceEvents(
    EMPTY_TIMELINE,
    input.trajectory,
    input.toolCalls,
  )
  const entries = traceEvents
    .map(entryFromTraceEvent)
    .filter((entry): entry is JourneyWaterfallEntry => entry !== null)
    .sort((left, right) => left.ts - right.ts)

  const runtimeEvidence = summarizeRuntimeTrace(input.runtimeTrace)
  const runtimeTurnKey = turnKey(runtimeEvidence?.keeperTurnId ?? null)
  const groups = new Map<string, { keeperTurnId: number | null; entries: JourneyWaterfallEntry[] }>()

  for (const entry of entries) {
    const key = turnKey(entry.keeperTurnId)
    const current = groups.get(key)
    if (current) {
      current.entries.push(entry)
    } else {
      groups.set(key, { keeperTurnId: entry.keeperTurnId, entries: [entry] })
    }
  }

  const turns = [...groups.entries()]
    .map(([key, group]) =>
      buildTurn(
        key,
        group.keeperTurnId,
        group.entries,
        runtimeEvidence && key === runtimeTurnKey ? runtimeEvidence : null,
      ),
    )
    .sort((left, right) => {
      if (
        left.keeperTurnId != null
        && right.keeperTurnId != null
        && left.keeperTurnId !== right.keeperTurnId
      ) {
        return left.keeperTurnId - right.keeperTurnId
      }
      if (left.keeperTurnId == null) return right.keeperTurnId == null ? left.startTs - right.startTs : 1
      if (right.keeperTurnId == null) return -1
      return left.startTs - right.startTs
    })

  const allTurnEntries = turns.flatMap(turn => turn.entries)
  let timelineStartTs: number | null = null
  let timelineEndTs: number | null = null
  for (const entry of allTurnEntries) {
    timelineStartTs = timelineStartTs === null ? entry.ts : Math.min(timelineStartTs, entry.ts)
    timelineEndTs = timelineEndTs === null ? entry.ts : Math.max(timelineEndTs, entry.ts)
  }
  return {
    keeper: input.keeper,
    turns,
    summary: {
      totalTurns: turns.length,
      totalEntries: allTurnEntries.length,
      thinkingCount: allTurnEntries.filter(entry => entry.kind === 'thinking').length,
      toolCallCount: allTurnEntries.filter(entry => entry.kind === 'tool_call').length,
      failureCount: allTurnEntries.filter(entry => entry.status === 'failure').length,
      provenanceGapCount: allTurnEntries.filter(entry => entry.kind === 'provenance_gap').length,
      totalDurationMs: turns.reduce((sum, turn) => sum + turn.totalDurationMs, 0),
      timelineStartTs,
      timelineEndTs,
      runtimeEvidence,
    },
  }
}

function keeperActivityAge(keeper: Keeper): number {
  return numberValue(keeper.last_turn_ago_s)
    ?? numberValue(keeper.last_activity_ago_s)
    ?? numberValue(keeper.agent?.last_seen_ago_s)
    ?? Number.POSITIVE_INFINITY
}

function keeperPriority(keeper: Keeper): number {
  const status = keeper.status.trim().toLowerCase()
  if (keeper.keepalive_running === true) return 0
  return classifyKeeperPriority(status)
}

export function selectDefaultJourneyKeeper(
  rows: readonly Keeper[],
  currentName?: string | null,
): string | null {
  if (currentName && rows.some(row => row.name === currentName)) return currentName
  const sorted = rows
    .filter(row => row.name.trim() !== '')
    .slice()
    .sort((left, right) => {
      const priorityDelta = keeperPriority(left) - keeperPriority(right)
      if (priorityDelta !== 0) return priorityDelta
      const ageDelta = keeperActivityAge(left) - keeperActivityAge(right)
      if (ageDelta !== 0) return ageDelta
      return left.name.localeCompare(right.name)
    })
  return sorted[0]?.name ?? null
}
