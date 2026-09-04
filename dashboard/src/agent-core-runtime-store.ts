import { appendLiveAgentCoreEvent } from './components/session-trace/session-trace-live-store'
import { isRecord, asNumber, asString } from './components/common/normalize'
import { toKeeperPhase } from './keeper-store-normalize'
import { fetchTelemetry, type TelemetryEntry } from './api/dashboard'
import { AGENT_CORE_TELEMETRY_REPLAY_LIMIT } from './config/constants'
import { isAgentCoreEventType } from './lib/sse-event-type'
import {
  agentCoreTotalEvents,
  agentCoreReplayLoadedEvents,
  agentCoreReplayTotalMatchingEvents,
  noteAgentCoreReplayWindow,
  pushAgentCoreAgentEvent,
  recordAgentCoreError,
  recordAgentCoreEvidenceRefs,
  recordAgentCoreLlmCall,
  resetAgentCoreRuntimeSignals,
} from './store'
import type {
  AgentCoreKeeperLifecycleEvent,
} from './types/agent-core'

type AgentCoreRuntimeEnvelope = Record<string, unknown> & {
  type: string
  payload: Record<string, unknown>
  dashboard_event_key?: string
}

type RuntimeEventIdentity =
  | { kind: 'stable'; key: string }
  | { kind: 'unidentified' }

type IngestOptions = {
  includeLiveTrace?: boolean
  origin?: 'live' | 'replay'
}

type QueuedLiveRuntimeEvent = {
  event: AgentCoreRuntimeEnvelope
  opts?: IngestOptions
}

type EvidenceRefSets = {
  evidenceRefs: Set<string>
  artifactRefs: Set<string>
  rawTraceRefs: Set<string>
  reportRefs: Set<string>
  proofRefs: Set<string>
  telemetryRefs: Set<string>
  runtimeEvidenceRefs: Set<string>
}

const seenAgentCoreEventKeys = new Set<string>()
const loadedReplayAgentCoreEventKeys = new Set<string>()
let unidentifiedAgentCoreEventSequence = 0
let loadedUnidentifiedReplayEventCount = 0
let replayGeneration = 0
let initialReplayPromise: Promise<void> | null = null
let replayFetchedAgentCoreEventCount = 0
let activeFullReplayGeneration: number | null = null
let queuedLiveRuntimeEvents: QueuedLiveRuntimeEvent[] = []

function emptyEvidenceRefSets(): EvidenceRefSets {
  return {
    evidenceRefs: new Set(),
    artifactRefs: new Set(),
    rawTraceRefs: new Set(),
    reportRefs: new Set(),
    proofRefs: new Set(),
    telemetryRefs: new Set(),
    runtimeEvidenceRefs: new Set(),
  }
}

function addEvidenceRef(target: Set<string>, all: Set<string>, ref: string): void {
  const text = ref.trim()
  if (!text) return
  target.add(text)
  all.add(text)
}

function classifyEvidenceString(
  sets: EvidenceRefSets,
  key: string,
  value: string,
): void {
  const keyText = key.toLowerCase()
  const valueText = value.trim()
  if (!valueText) return
  const combined = `${keyText} ${valueText.toLowerCase()}`
  const ref = `${keyText || 'value'}:${valueText}`
  const artifactKey =
    keyText === 'artifact_id'
    || keyText === 'artifact_ref'
    || keyText === 'artifact_path'
    || keyText === 'artifact_uri'
    || keyText === 'artifact'
  if (artifactKey || combined.includes('artifact://')) {
    addEvidenceRef(sets.artifactRefs, sets.evidenceRefs, ref)
  }
  if (
    keyText.includes('raw_trace')
    || combined.includes('raw_trace')
    || combined.includes('raw-trace')
  ) {
    addEvidenceRef(sets.rawTraceRefs, sets.evidenceRefs, ref)
  }
  if (
    keyText === 'report'
    || keyText === 'report_json'
    || keyText === 'report_md'
    || keyText === 'report_path'
    || keyText === 'report_ref'
    || keyText === 'report_uri'
    || combined.includes('report_json')
    || combined.includes('report_md')
  ) {
    addEvidenceRef(sets.reportRefs, sets.evidenceRefs, ref)
  }
  if (
    keyText === 'proof'
    || keyText === 'proof_json'
    || keyText === 'proof_md'
    || keyText === 'proof_path'
    || keyText === 'proof_ref'
    || keyText === 'proof_uri'
    || combined.includes('proof_json')
    || combined.includes('proof_md')
  ) {
    addEvidenceRef(sets.proofRefs, sets.evidenceRefs, ref)
  }
  if (
    keyText === 'telemetry'
    || keyText === 'telemetry_json'
    || keyText === 'telemetry_md'
    || keyText === 'telemetry_path'
    || keyText === 'telemetry_ref'
    || keyText === 'telemetry_uri'
    || combined.includes('runtime-telemetry')
    || combined.includes('telemetry_json')
    || combined.includes('telemetry_md')
  ) {
    addEvidenceRef(sets.telemetryRefs, sets.evidenceRefs, ref)
  }
  if (
    keyText === 'evidence'
    || keyText === 'evidence_json'
    || keyText === 'evidence_bundle'
    || keyText === 'evidence_file'
    || keyText === 'evidence_path'
    || keyText === 'evidence_ref'
    || combined.includes('runtime-evidence')
  ) {
    addEvidenceRef(sets.runtimeEvidenceRefs, sets.evidenceRefs, ref)
  }
}

function collectEvidenceRefs(
  value: unknown,
  sets: EvidenceRefSets,
  key = '',
  depth = 0,
): void {
  if (depth > 8) return
  if (typeof value === 'string') {
    classifyEvidenceString(sets, key, value)
    return
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      collectEvidenceRefs(item, sets, key, depth + 1)
    }
    return
  }
  if (!isRecord(value)) return
  const artifactId = asString(value.artifact_id)
  if (artifactId) {
    addEvidenceRef(sets.artifactRefs, sets.evidenceRefs, `artifact_id:${artifactId}`)
  }
  for (const [childKey, childValue] of Object.entries(value)) {
    collectEvidenceRefs(childValue, sets, childKey, depth + 1)
  }
}

function recordEvidenceRefsForEvent(event: AgentCoreRuntimeEnvelope): void {
  const sets = emptyEvidenceRefSets()
  collectEvidenceRefs(event, sets)
  if (sets.evidenceRefs.size === 0) return
  recordAgentCoreEvidenceRefs({
    evidenceRefsCount: sets.evidenceRefs.size,
    artifactRefsCount: sets.artifactRefs.size,
    rawTraceRefsCount: sets.rawTraceRefs.size,
    reportRefsCount: sets.reportRefs.size,
    proofRefsCount: sets.proofRefs.size,
    telemetryRefsCount: sets.telemetryRefs.size,
    runtimeEvidenceRefsCount: sets.runtimeEvidenceRefs.size,
    tsMs: eventTimestampMs(event),
  })
}

function eventPayload(event: AgentCoreRuntimeEnvelope): Record<string, unknown> {
  return isRecord(event.payload) ? event.payload : {}
}

function eventReportedUnixSeconds(event: AgentCoreRuntimeEnvelope): number | null {
  return (
    asNumber(event.ts_unix)
    ?? asNumber(event.timestamp)
    ?? asNumber(event.ts)
    ?? null
  )
}

function eventUnixSeconds(event: AgentCoreRuntimeEnvelope): number {
  return eventReportedUnixSeconds(event) ?? Date.now() / 1000
}

function eventTimestampMs(event: AgentCoreRuntimeEnvelope): number {
  return Math.round(eventUnixSeconds(event) * 1000)
}

function runtimeEventType(event: AgentCoreRuntimeEnvelope): string {
  return asString(event.event_type) ?? event.type
}

function stableRuntimeEventIdentity(event: AgentCoreRuntimeEnvelope): RuntimeEventIdentity {
  const payload = eventPayload(event)
  const runId = asString(event.run_id) ?? asString(payload.run_id)
  const eventId = asString(event.event_id) ?? asString(payload.event_id)
  if (eventId) {
    return { kind: 'stable', key: `event:${eventId}` }
  }

  const seq = asNumber(event.seq) ?? asNumber(payload.seq)
  if (runId && seq != null && Number.isSafeInteger(seq) && seq >= 0) {
    return { kind: 'stable', key: `run:${runId}|seq:${seq}` }
  }

  return { kind: 'unidentified' }
}

function runtimeEventKey(event: AgentCoreRuntimeEnvelope): string {
  if (event.dashboard_event_key) return event.dashboard_event_key
  const identity = stableRuntimeEventIdentity(event)
  const key = identity.kind === 'stable'
    ? identity.key
    : `unidentified:${++unidentifiedAgentCoreEventSequence}`
  event.dashboard_event_key = key
  return key
}

function loadedAgentCoreEventCount(): number {
  return loadedReplayAgentCoreEventKeys.size + loadedUnidentifiedReplayEventCount
}

function traceDetail(
  event: AgentCoreRuntimeEnvelope,
  detail: Record<string, unknown>,
): Record<string, unknown> {
  return {
    event_id: asString(event.event_id) ?? null,
    event_type: runtimeEventType(event),
    correlation_id: asString(event.correlation_id) ?? null,
    run_id: asString(event.run_id) ?? null,
    ts_unix: eventUnixSeconds(event),
    ...detail,
  }
}

function agentNameFromEnvelope(event: AgentCoreRuntimeEnvelope): string {
  const payload = eventPayload(event)
  return (
    asString(payload.agent_name)
    ?? asString(event.agent_name)
    ?? asString(payload.agent)
    ?? ''
  )
}

function keeperLifecycleEvent(event: AgentCoreRuntimeEnvelope): AgentCoreKeeperLifecycleEvent {
  const payload = eventPayload(event)
  const keeperName = asString(payload.keeper_name)
  const actorName = keeperName ?? asString(payload.agent_name) ?? ''
  return {
    type: 'keeper_lifecycle',
    agent_name: actorName,
    actor_kind: 'keeper',
    keeper_name: keeperName,
    event: asString(payload.event),
    phase: toKeeperPhase(asString(payload.phase)),
    detail: asString(payload.detail),
    event_type: runtimeEventType(event),
    event_id: asString(event.event_id),
    correlation_id: asString(event.correlation_id),
    run_id: asString(event.run_id),
    event_key: runtimeEventKey(event),
    timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
  }
}

function maybeAppendLiveTrace(
  agentName: string,
  event: AgentCoreRuntimeEnvelope,
  detail: {
    idSuffix: string
    kind: 'lifecycle' | 'agent_core_tool' | 'agent_core_turn'
    summary: string
    data: Record<string, unknown>
    toolName?: string
    turn?: number
    durationMs?: number
    error?: string
    costUsd?: number
  },
): void {
  if (!agentName) return
  const tsMs = eventTimestampMs(event)
  appendLiveAgentCoreEvent(agentName, {
    id: `${runtimeEventKey(event)}|${detail.idSuffix}`,
    ts: tsMs,
    ts_iso: new Date(tsMs).toISOString(),
    kind: detail.kind,
    summary: detail.summary,
    detail: traceDetail(event, detail.data),
    toolName: detail.toolName,
    turn: detail.turn,
    duration_ms: detail.durationMs,
    error: detail.error,
    cost_usd: detail.costUsd,
  })
}

function ingestRuntimeProjection(
  event: AgentCoreRuntimeEnvelope,
  opts?: IngestOptions,
): void {
  const payload = eventPayload(event)
  const agentName = agentNameFromEnvelope(event)
  recordEvidenceRefsForEvent(event)
  switch (event.type) {
    case 'agent_core:masc:keeper:lifecycle':
      {
        const lifecycle = keeperLifecycleEvent(event)
        pushAgentCoreAgentEvent(lifecycle)
        if (opts?.includeLiveTrace) {
          const actorName = lifecycle.keeper_name ?? lifecycle.agent_name
          const summaryParts = [
            lifecycle.event,
            lifecycle.phase,
            lifecycle.detail,
          ].filter(Boolean)
          maybeAppendLiveTrace(actorName, event, {
            idSuffix: summaryParts.join('|') || 'lifecycle',
            kind: 'lifecycle',
            summary: `keeper ${summaryParts.join(' · ') || 'lifecycle'}`,
            data: {
              keeper_name: lifecycle.keeper_name ?? null,
              event: lifecycle.event ?? null,
              phase: lifecycle.phase ?? null,
              detail: lifecycle.detail ?? null,
            },
          })
        }
      }
      return
    case 'agent_core:agent_started':
    case 'agent_core:agent_completed':
      if (opts?.includeLiveTrace) {
        const phase = event.type === 'agent_core:agent_started' ? 'started' : 'completed'
        const inputTokens = asNumber(payload.input_tokens)
        const outputTokens = asNumber(payload.output_tokens)
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: phase,
          kind: 'lifecycle',
          summary: `agent ${phase}${inputTokens != null || outputTokens != null ? ` · ${inputTokens ?? 0}→${outputTokens ?? 0}tok` : ''}`,
          data: {
            task_id: asString(payload.task_id) ?? null,
            elapsed_s: asNumber(payload.elapsed_s) ?? null,
            input_tokens: inputTokens ?? null,
            output_tokens: outputTokens ?? null,
          },
          costUsd: asNumber(payload.cost_usd) ?? undefined,
        })
      }
      return
    case 'agent_core:tool_called':
    case 'agent_core:tool_completed':
      if (opts?.includeLiveTrace) {
        const phase = event.type === 'agent_core:tool_called' ? 'called' : 'completed'
        const toolName = asString(payload.tool_name) ?? 'unknown'
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `${phase}|${toolName}`,
          kind: 'agent_core_tool',
          summary: `${phase} ${toolName}`,
          data: { phase, tool_name: toolName },
          toolName,
        })
      }
      return
    case 'agent_core:turn_started':
    case 'agent_core:turn_completed':
      if (opts?.includeLiveTrace) {
        const phase = event.type === 'agent_core:turn_started' ? 'started' : 'completed'
        const turn = asNumber(payload.turn)
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `${phase}|${turn ?? 'na'}`,
          kind: 'agent_core_turn',
          summary: `${phase} turn${turn != null ? ` ${turn}` : ''}`,
          data: { phase, turn: turn ?? null },
          turn: turn ?? undefined,
        })
      }
      return
    case 'agent_core:durable:llm_request':
      recordAgentCoreLlmCall(eventTimestampMs(event))
      if (opts?.includeLiveTrace) {
        const turn = asNumber(payload.turn)
        const runtime = 'runtime'
        const inputTokens = asNumber(payload.input_tokens) ?? 0
        const cacheCreationTokens =
          asNumber(payload.cache_creation_tokens)
          ?? asNumber(payload.cache_creation_input_tokens)
        const cacheReadTokens =
          asNumber(payload.cache_read_tokens)
          ?? asNumber(payload.cache_read_input_tokens)
        const cacheMissInputTokens = asNumber(payload.cache_miss_input_tokens)
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `llm_request|${turn ?? 'na'}`,
          kind: 'lifecycle',
          summary: `LLM 요청 · ${runtime} · ${inputTokens}tok${turn != null ? ` · turn ${turn}` : ''}`,
          data: {
            durable_kind: 'llm_request',
            turn: turn ?? null,
            model: runtime,
            input_tokens: inputTokens,
            cache_creation_tokens: cacheCreationTokens ?? null,
            cache_read_tokens: cacheReadTokens ?? null,
            cache_miss_input_tokens: cacheMissInputTokens ?? null,
          },
        })
      }
      return
    case 'agent_core:durable:llm_response':
      if (opts?.includeLiveTrace) {
        const turn = asNumber(payload.turn)
        const outputTokens = asNumber(payload.output_tokens) ?? 0
        const stopReason = asString(payload.stop_reason) ?? 'unknown'
        const durationMs = asNumber(payload.duration_ms)
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `llm_response|${turn ?? 'na'}`,
          kind: 'lifecycle',
          summary: `LLM 응답 · ${outputTokens}tok · ${stopReason}${durationMs != null ? ` · ${durationMs.toFixed(0)}ms` : ''}`,
          data: {
            durable_kind: 'llm_response',
            turn: turn ?? null,
            output_tokens: outputTokens,
            stop_reason: stopReason,
            duration_ms: durationMs ?? null,
          },
          durationMs: durationMs ?? undefined,
        })
      }
      return
    case 'agent_core:durable:error_occurred':
      recordAgentCoreError(eventTimestampMs(event))
      if (opts?.includeLiveTrace) {
        const turn = asNumber(payload.turn)
        const errorDomain = asString(payload.error_domain) ?? 'unknown'
        const detail = asString(payload.detail) ?? ''
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `error_occurred|${turn ?? 'na'}|${errorDomain}`,
          kind: 'lifecycle',
          summary: `Agent Core 에러 · ${errorDomain}${turn != null ? ` · turn ${turn}` : ''}`,
          data: {
            durable_kind: 'error_occurred',
            turn: turn ?? null,
            error_domain: errorDomain,
            detail,
          },
          error: detail || errorDomain,
        })
      }
      return
    default:
      return
  }
}

function coerceAgentCoreRuntimeEnvelope(raw: unknown): AgentCoreRuntimeEnvelope | null {
  if (!isRecord(raw)) return null
  const type = asString(raw.type)
  if (!type || !isAgentCoreEventType(type)) return null
  return {
    ...raw,
    type,
    payload: isRecord(raw.payload) ? raw.payload : {},
  }
}

function applyCoercedAgentCoreRuntimeEvent(
  event: AgentCoreRuntimeEnvelope,
  opts?: IngestOptions,
): boolean {
  const identity = stableRuntimeEventIdentity(event)
  if (identity.kind === 'stable') {
    if (seenAgentCoreEventKeys.has(identity.key)) return false
    seenAgentCoreEventKeys.add(identity.key)
    if (opts?.origin === 'replay') loadedReplayAgentCoreEventKeys.add(identity.key)
    event.dashboard_event_key = identity.key
  } else {
    runtimeEventKey(event)
    if (opts?.origin === 'replay') loadedUnidentifiedReplayEventCount += 1
  }
  ingestRuntimeProjection(event, opts)
  // A live arrival is news the replay window never counted, so it belongs
  // above the server's total. A replayed row is not: it is already inside
  // that total, and counting it again is what made "load more" claim 1700
  // of 1200 and retire `hasMore` with rows still unfetched.
  if (opts?.origin !== 'replay') agentCoreTotalEvents.value += 1
  return true
}

export function applyAgentCoreRuntimeEvent(raw: unknown, opts?: IngestOptions): boolean {
  const event = coerceAgentCoreRuntimeEnvelope(raw)
  if (!event) return false
  if (opts?.origin !== 'replay' && activeFullReplayGeneration !== null) {
    queuedLiveRuntimeEvents.push({ event, opts })
    return true
  }
  return applyCoercedAgentCoreRuntimeEvent(event, opts)
}

function beginFullReplayHydration(generation: number): void {
  activeFullReplayGeneration = generation
}

function finishFullReplayHydration(generation: number): void {
  if (activeFullReplayGeneration !== generation) return
  activeFullReplayGeneration = null
  if (queuedLiveRuntimeEvents.length === 0) return
  const pending = queuedLiveRuntimeEvents
  queuedLiveRuntimeEvents = []
  for (const { event, opts } of pending) {
    applyCoercedAgentCoreRuntimeEvent(event, opts)
  }
}

export function hydrateAgentCoreRuntimeFromTelemetryEntries(entries: TelemetryEntry[]): void {
  resetAgentCoreRuntimeSignals()
  seenAgentCoreEventKeys.clear()
  loadedReplayAgentCoreEventKeys.clear()
  unidentifiedAgentCoreEventSequence = 0
  loadedUnidentifiedReplayEventCount = 0
  replayFetchedAgentCoreEventCount = 0
  const ordered = [...entries].sort((a, b) => {
    const left = coerceAgentCoreRuntimeEnvelope(a)
    const right = coerceAgentCoreRuntimeEnvelope(b)
    return (left ? (eventReportedUnixSeconds(left) ?? 0) : 0) - (right ? (eventReportedUnixSeconds(right) ?? 0) : 0)
  })
  for (const entry of ordered) {
    applyAgentCoreRuntimeEvent(entry, { origin: 'replay' })
  }
  replayFetchedAgentCoreEventCount = entries.length
  noteAgentCoreReplayWindow({
    loadedEvents: loadedAgentCoreEventCount(),
    totalMatchingEvents: entries.length,
    truncated: false,
  })
}

export function appendAgentCoreRuntimeFromTelemetryEntries(
  entries: TelemetryEntry[],
  replayOffset: number,
): void {
  const ordered = [...entries].sort((a, b) => {
    const left = coerceAgentCoreRuntimeEnvelope(a)
    const right = coerceAgentCoreRuntimeEnvelope(b)
    return (left ? (eventReportedUnixSeconds(left) ?? 0) : 0) - (right ? (eventReportedUnixSeconds(right) ?? 0) : 0)
  })
  for (const entry of ordered) {
    applyAgentCoreRuntimeEvent(entry, { origin: 'replay' })
  }
  replayFetchedAgentCoreEventCount = replayOffset + entries.length
}

export async function replayAgentCoreRuntimeTelemetry(signal?: AbortSignal): Promise<void> {
  const generation = ++replayGeneration
  beginFullReplayHydration(generation)
  try {
    const response = await fetchTelemetry({
      source: 'agent_core_event',
      n: AGENT_CORE_TELEMETRY_REPLAY_LIMIT,
      signal,
    })
    if (generation !== replayGeneration) return
    hydrateAgentCoreRuntimeFromTelemetryEntries(response.entries)
    noteAgentCoreReplayWindow({
      loadedEvents: loadedAgentCoreEventCount(),
      totalMatchingEvents: response.total_matching_entries ?? response.count,
      truncated: response.has_more ?? response.truncated ?? false,
    })
  } finally {
    finishFullReplayHydration(generation)
  }
}

export function ensureAgentCoreRuntimeReplay(): Promise<void> {
  if (agentCoreReplayLoadedEvents.value > 0 || agentCoreReplayTotalMatchingEvents.value > 0) {
    return Promise.resolve()
  }
  if (initialReplayPromise) return initialReplayPromise
  initialReplayPromise = replayAgentCoreRuntimeTelemetry()
    .finally(() => {
      initialReplayPromise = null
    })
  return initialReplayPromise
}

export async function loadMoreAgentCoreEvents(signal?: AbortSignal): Promise<void> {
  const currentOffset = replayFetchedAgentCoreEventCount
  const response = await fetchTelemetry({
    source: 'agent_core_event',
    n: AGENT_CORE_TELEMETRY_REPLAY_LIMIT,
    offset: currentOffset,
    signal,
  })
  // The server caps telemetry offsets. Once it reports an earlier offset than
  // requested, this is a replay of a page we already consumed: do not project
  // it again or advance the cursor beyond reachable history.
  if (response.offset !== currentOffset) {
    noteAgentCoreReplayWindow({
      loadedEvents: loadedAgentCoreEventCount(),
      totalMatchingEvents: response.total_matching_entries ?? response.count,
      truncated: false,
      capped: true,
      observedTotalEvents: agentCoreTotalEvents.value,
    })
    return
  }
  appendAgentCoreRuntimeFromTelemetryEntries(response.entries, response.offset)
  noteAgentCoreReplayWindow({
    loadedEvents: loadedAgentCoreEventCount(),
    totalMatchingEvents: response.total_matching_entries ?? response.count,
    truncated: response.has_more ?? response.truncated ?? false,
    observedTotalEvents: agentCoreTotalEvents.value,
  })
}
