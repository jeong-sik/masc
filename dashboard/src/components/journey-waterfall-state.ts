import type {
  AgentTimelineResponse,
  ToolCallsResponse,
  TrajectoryResponse,
} from '../api/dashboard'
import type { KeeperRuntimeTraceResponse } from '../api/keeper'
import { asNullableString } from './common/normalize'
import type { Keeper } from '../types'
import { keeperPriority as classifyKeeperPriority } from '../lib/keeper-classifiers'
import {
  buildTraceEvents,
  type UnifiedTraceEvent,
} from './session-trace/session-trace-state'

type WaterfallEntryKind = 'thinking' | 'tool_call'
type WaterfallEntryStatus = 'success' | 'failure' | 'gate_rejected' | 'unknown'
type WaterfallEntrySource = 'trajectory' | 'trajectory+tool_call_log' | 'tool_call_log' | 'unknown'

export interface JourneyWaterfallEntry {
  id: string
  kind: WaterfallEntryKind
  status: WaterfallEntryStatus
  source: WaterfallEntrySource
  ts: number
  tsIso: string
  turn: number | null
  round: number | null
  summary: string
  toolName: string | null
  toolArgs: Record<string, unknown> | string | null
  toolResult: string | null
  thinkingContent: string | null
  thinkingRedacted: boolean
  durationMs: number | null
  costUsd: number | null
  gateReason: string | null
  error: string | null
  sessionId: string | null
  traceId: string | null
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
  memoryInjectedCount: number
  memoryFlushedCount: number
}

export interface JourneyWaterfallTurn {
  key: string
  turn: number | null
  label: string
  startTs: number
  endTs: number
  entries: JourneyWaterfallEntry[]
  thinkingCount: number
  toolCallCount: number
  failureCount: number
  gateRejectedCount: number
  totalDurationMs: number
  totalCostUsd: number
  runtimeEvidence: JourneyWaterfallRuntimeEvidence | null
}

export interface JourneyWaterfallSummary {
  totalTurns: number
  totalEntries: number
  thinkingCount: number
  toolCallCount: number
  failureCount: number
  gateRejectedCount: number
  totalDurationMs: number
  totalCostUsd: number
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
  const origin = asNullableString(event.detail.trace_origin)
  if (origin === 'trajectory+tool_call_log') return 'trajectory+tool_call_log'
  if (origin === 'tool_call_log') return 'tool_call_log'
  if (origin === 'trajectory') return 'trajectory'
  return 'unknown'
}

function traceEventTraceId(event: UnifiedTraceEvent): string | null {
  return asNullableString(event.detail.trace_id)
}

function traceEventStatus(event: UnifiedTraceEvent): WaterfallEntryStatus {
  if (event.gate?.status === 'reject') return 'gate_rejected'
  if (event.error) return 'failure'
  if (event.kind === 'tool_call') return 'success'
  return 'unknown'
}

function entryFromTraceEvent(event: UnifiedTraceEvent): JourneyWaterfallEntry | null {
  if (event.kind !== 'tool_call' && event.kind !== 'thinking') return null
  const status = traceEventStatus(event)
  return {
    id: event.id,
    kind: event.kind,
    status,
    source: traceEventSource(event),
    ts: event.ts,
    tsIso: event.ts_iso,
    turn: event.turn ?? null,
    round: event.round ?? null,
    summary: event.summary,
    toolName: event.toolName ?? null,
    toolArgs: event.toolArgs ?? null,
    toolResult: event.toolResult ?? null,
    thinkingContent: event.thinkingContent ?? null,
    thinkingRedacted: event.thinkingRedacted === true,
    durationMs: event.duration_ms ?? null,
    costUsd: event.cost_usd ?? null,
    gateReason: event.gate?.reason ?? null,
    error: event.error ?? null,
    sessionId: event.sessionId ?? null,
    traceId: traceEventTraceId(event),
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
    memoryInjectedCount: trace.memory.memory_injected_count,
    memoryFlushedCount: trace.memory.memory_flushed_count,
  }
}

function turnKey(turn: number | null): string {
  return turn == null ? 'turn-unrecorded' : `turn-${turn}`
}

function turnLabel(turn: number | null): string {
  return turn == null ? 'Turn not recorded' : `Turn ${turn}`
}

function buildTurn(
  key: string,
  turn: number | null,
  entries: JourneyWaterfallEntry[],
  runtimeEvidence: JourneyWaterfallRuntimeEvidence | null,
): JourneyWaterfallTurn {
  const sortedEntries = entries.slice().sort((left, right) => left.ts - right.ts)
  const startTs = sortedEntries[0]?.ts ?? 0
  const endTs = sortedEntries.at(-1)?.ts ?? startTs
  const toolEntries = sortedEntries.filter(entry => entry.kind === 'tool_call')
  return {
    key,
    turn,
    label: turnLabel(turn),
    startTs,
    endTs,
    entries: sortedEntries,
    thinkingCount: sortedEntries.filter(entry => entry.kind === 'thinking').length,
    toolCallCount: toolEntries.length,
    failureCount: sortedEntries.filter(entry => entry.status === 'failure').length,
    gateRejectedCount: sortedEntries.filter(entry => entry.status === 'gate_rejected').length,
    totalDurationMs: toolEntries.reduce((sum, entry) => sum + (entry.durationMs ?? 0), 0),
    totalCostUsd: toolEntries.reduce((sum, entry) => sum + (entry.costUsd ?? 0), 0),
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
  const groups = new Map<string, { turn: number | null; entries: JourneyWaterfallEntry[] }>()

  for (const entry of entries) {
    const key = turnKey(entry.turn)
    const current = groups.get(key)
    if (current) {
      current.entries.push(entry)
    } else {
      groups.set(key, { turn: entry.turn, entries: [entry] })
    }
  }

  const turns = [...groups.entries()]
    .map(([key, group]) =>
      buildTurn(
        key,
        group.turn,
        group.entries,
        runtimeEvidence && key === runtimeTurnKey ? runtimeEvidence : null,
      ),
    )
    .sort((left, right) => {
      if (left.turn != null && right.turn != null && left.turn !== right.turn) {
        return left.turn - right.turn
      }
      return left.startTs - right.startTs
    })

  const allTurnEntries = turns.flatMap(turn => turn.entries)
  return {
    keeper: input.keeper,
    turns,
    summary: {
      totalTurns: turns.length,
      totalEntries: allTurnEntries.length,
      thinkingCount: allTurnEntries.filter(entry => entry.kind === 'thinking').length,
      toolCallCount: allTurnEntries.filter(entry => entry.kind === 'tool_call').length,
      failureCount: allTurnEntries.filter(entry => entry.status === 'failure').length,
      gateRejectedCount: allTurnEntries.filter(entry => entry.status === 'gate_rejected').length,
      totalDurationMs: turns.reduce((sum, turn) => sum + turn.totalDurationMs, 0),
      totalCostUsd: turns.reduce((sum, turn) => sum + turn.totalCostUsd, 0),
      timelineStartTs: allTurnEntries[0]?.ts ?? null,
      timelineEndTs: allTurnEntries.at(-1)?.ts ?? null,
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
