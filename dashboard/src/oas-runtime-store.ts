import { appendLiveOasEvent } from './components/session-trace/session-trace-live-store'
import { isRecord, asNumber, asString } from './components/common/normalize'
import { toKeeperPhase } from './keeper-store-normalize'
import { fetchTelemetry, type TelemetryEntry } from './api/dashboard'
import { OAS_TELEMETRY_REPLAY_LIMIT, OAS_EVENT_PREFIX } from './config/constants'
import {
  oasTotalEvents,
  oasAgentEvents,
  oasReplayLoadedEvents,
  oasReplayTotalMatchingEvents,
  noteOasReplayWindow,
  pushOasAgentEvent,
  recordOasError,
  recordOasEvidenceRefs,
  recordOasLlmCall,
  resetOasRuntimeSignals,
  updateOasKeeperSnapshot,
} from './store'
import type {
  OasKeeperLifecycleEvent,
  OasKeeperSnapshot,
} from './types/oas'

type OasRuntimeEnvelope = Record<string, unknown> & {
  type: string
  payload: Record<string, unknown>
}

type IngestOptions = {
  includeLiveTrace?: boolean
  origin?: 'live' | 'replay'
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

const seenOasEventKeys = new Set<string>()
let replayGeneration = 0
let initialReplayPromise: Promise<void> | null = null

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

function recordEvidenceRefsForEvent(event: OasRuntimeEnvelope): void {
  const sets = emptyEvidenceRefSets()
  collectEvidenceRefs(event, sets)
  if (sets.evidenceRefs.size === 0) return
  recordOasEvidenceRefs({
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

function eventPayload(event: OasRuntimeEnvelope): Record<string, unknown> {
  return isRecord(event.payload) ? event.payload : {}
}

function eventReportedUnixSeconds(event: OasRuntimeEnvelope): number | null {
  return (
    asNumber(event.ts_unix)
    ?? asNumber(event.timestamp)
    ?? asNumber(event.ts)
    ?? null
  )
}

function eventUnixSeconds(event: OasRuntimeEnvelope): number {
  return eventReportedUnixSeconds(event) ?? Date.now() / 1000
}

function eventTimestampMs(event: OasRuntimeEnvelope): number {
  return Math.round(eventUnixSeconds(event) * 1000)
}

function runtimeEventType(event: OasRuntimeEnvelope): string {
  return asString(event.event_type) ?? event.type
}

function runtimeEventKey(event: OasRuntimeEnvelope): string {
  const payload = eventPayload(event)
  const type = runtimeEventType(event)
  const correlationId = asString(event.correlation_id)
  const runId = asString(event.run_id)
  const reportedTsUnix = eventReportedUnixSeconds(event)
  const agentName =
    asString(event.agent_name)
    ?? asString(payload.agent_name)
    ?? asString(payload.agent)
    ?? asString(payload.keeper_name)
    ?? ''
  const taskId = asString(event.task_id) ?? asString(payload.task_id) ?? ''
  const toolName = asString(event.tool_name) ?? asString(payload.tool_name) ?? ''
  const turn = asNumber(event.turn) ?? asNumber(payload.turn)
  if (correlationId || runId || reportedTsUnix != null) {
    return [
      type,
      agentName,
      correlationId ?? '',
      runId ?? '',
      reportedTsUnix != null ? String(reportedTsUnix) : '',
      taskId,
      toolName,
      turn != null ? String(turn) : '',
    ].join('|')
  }
  return JSON.stringify({
    type,
    agentName,
    taskId,
    toolName,
    turn: turn ?? null,
    payload,
  })
}

function traceDetail(
  event: OasRuntimeEnvelope,
  detail: Record<string, unknown>,
): Record<string, unknown> {
  return {
    event_type: runtimeEventType(event),
    correlation_id: asString(event.correlation_id) ?? null,
    run_id: asString(event.run_id) ?? null,
    ts_unix: eventUnixSeconds(event),
    ...detail,
  }
}

function agentNameFromEnvelope(event: OasRuntimeEnvelope): string {
  const payload = eventPayload(event)
  return (
    asString(payload.agent_name)
    ?? asString(event.agent_name)
    ?? asString(payload.agent)
    ?? ''
  )
}

function keeperLifecycleEvent(event: OasRuntimeEnvelope): OasKeeperLifecycleEvent {
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
    correlation_id: asString(event.correlation_id),
    run_id: asString(event.run_id),
    event_key: runtimeEventKey(event),
    timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
  }
}

function maybeAppendLiveTrace(
  agentName: string,
  event: OasRuntimeEnvelope,
  detail: {
    idSuffix: string
    kind: 'lifecycle' | 'oas_tool' | 'oas_turn' | 'oas_context'
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
  appendLiveOasEvent(agentName, {
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
  event: OasRuntimeEnvelope,
  opts?: IngestOptions,
): void {
  const payload = eventPayload(event)
  const agentName = agentNameFromEnvelope(event)
  recordEvidenceRefsForEvent(event)
  switch (event.type) {
    case 'oas:masc:autonomy:agent_selected':
      pushOasAgentEvent({
        type: 'selected',
        agent_name: agentName,
        actor_kind: 'agent',
        trigger: asString(payload.trigger),
        thompson_score: asNumber(payload.thompson_score),
        final_score: asNumber(payload.final_score),
        event_type: runtimeEventType(event),
        correlation_id: asString(event.correlation_id),
        run_id: asString(event.run_id),
        event_key: runtimeEventKey(event),
        timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
      })
      return
    case 'oas:masc:autonomy:agent_decision':
      pushOasAgentEvent({
        type: 'decision',
        agent_name: agentName,
        actor_kind: 'agent',
        action: asString(payload.action),
        trigger_reason: asString(payload.trigger_reason),
        event_type: runtimeEventType(event),
        correlation_id: asString(event.correlation_id),
        run_id: asString(event.run_id),
        event_key: runtimeEventKey(event),
        timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
      })
      return
    case 'oas:masc:autonomy:agent_action_executed':
      pushOasAgentEvent({
        type: 'action_executed',
        agent_name: agentName,
        actor_kind: 'agent',
        action: asString(payload.action),
        success: typeof payload.success === 'boolean' ? payload.success : undefined,
        event_type: runtimeEventType(event),
        correlation_id: asString(event.correlation_id),
        run_id: asString(event.run_id),
        event_key: runtimeEventKey(event),
        timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
      })
      return
    case 'oas:masc:keeper:snapshot':
      updateOasKeeperSnapshot({
        keeper_name: asString(payload.keeper_name) ?? '',
        generation: asNumber(payload.generation, 0),
        context_ratio: asNumber(payload.context_ratio, 0),
        message_count: asNumber(payload.message_count, 0),
        timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
      } satisfies OasKeeperSnapshot)
      return
    case 'oas:masc:keeper:lifecycle':
      {
        const lifecycle = keeperLifecycleEvent(event)
        pushOasAgentEvent(lifecycle)
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
    case 'oas:masc:trust_updated':
      pushOasAgentEvent({
        type: 'trust_updated',
        agent_name: asString(payload.agent_a) ?? '',
        actor_kind: 'agent',
        secondary_agent: asString(payload.agent_b),
        trust_score: asNumber(payload.trust_score),
        event_type: runtimeEventType(event),
        correlation_id: asString(event.correlation_id),
        run_id: asString(event.run_id),
        event_key: runtimeEventKey(event),
        timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
      })
      return
    case 'oas:masc:reputation_changed':
      pushOasAgentEvent({
        type: 'reputation_changed',
        agent_name: agentName,
        actor_kind: 'agent',
        old_score: asNumber(payload.old_score),
        new_score: asNumber(payload.new_score),
        trend: asString(payload.trend),
        event_type: runtimeEventType(event),
        correlation_id: asString(event.correlation_id),
        run_id: asString(event.run_id),
        event_key: runtimeEventKey(event),
        timestamp: asNumber(payload.timestamp) ?? eventUnixSeconds(event),
      })
      return
    case 'oas:agent_started':
    case 'oas:agent_completed':
      if (opts?.includeLiveTrace) {
        const phase = event.type === 'oas:agent_started' ? 'started' : 'completed'
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
    case 'oas:tool_called':
    case 'oas:tool_completed':
      if (opts?.includeLiveTrace) {
        const phase = event.type === 'oas:tool_called' ? 'called' : 'completed'
        const toolName = asString(payload.tool_name) ?? 'unknown'
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `${phase}|${toolName}`,
          kind: 'oas_tool',
          summary: `${phase} ${toolName}`,
          data: { phase, tool_name: toolName },
          toolName,
        })
      }
      return
    case 'oas:turn_started':
    case 'oas:turn_completed':
      if (opts?.includeLiveTrace) {
        const phase = event.type === 'oas:turn_started' ? 'started' : 'completed'
        const turn = asNumber(payload.turn)
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `${phase}|${turn ?? 'na'}`,
          kind: 'oas_turn',
          summary: `${phase} turn${turn != null ? ` ${turn}` : ''}`,
          data: { phase, turn: turn ?? null },
          turn: turn ?? undefined,
        })
      }
      return
    case 'oas:context_compacted':
      if (opts?.includeLiveTrace) {
        const before = asNumber(payload.before_tokens)
        const after = asNumber(payload.after_tokens)
        const phase = asString(payload.phase)
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `${phase ?? 'compact'}|${before ?? 'na'}|${after ?? 'na'}`,
          kind: 'oas_context',
          summary: `compact${before != null && after != null ? ` ${before}→${after}` : ''}`,
          data: {
            before_tokens: before ?? null,
            after_tokens: after ?? null,
            phase: phase ?? null,
          },
        })
      }
      return
    case 'oas:durable:llm_request':
      recordOasLlmCall(eventTimestampMs(event))
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
    case 'oas:durable:llm_response':
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
    case 'oas:durable:error_occurred':
      recordOasError(eventTimestampMs(event))
      if (opts?.includeLiveTrace) {
        const turn = asNumber(payload.turn)
        const errorDomain = asString(payload.error_domain) ?? 'unknown'
        const detail = asString(payload.detail) ?? ''
        maybeAppendLiveTrace(agentName, event, {
          idSuffix: `error_occurred|${turn ?? 'na'}|${errorDomain}`,
          kind: 'lifecycle',
          summary: `OAS 에러 · ${errorDomain}${turn != null ? ` · turn ${turn}` : ''}`,
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

function coerceOasRuntimeEnvelope(raw: unknown): OasRuntimeEnvelope | null {
  if (!isRecord(raw)) return null
  const type = asString(raw.type)
  if (!type || !type.startsWith(OAS_EVENT_PREFIX)) return null
  return {
    ...raw,
    type,
    payload: isRecord(raw.payload) ? raw.payload : {},
  }
}

export function applyOasRuntimeEvent(raw: unknown, opts?: IngestOptions): boolean {
  const event = coerceOasRuntimeEnvelope(raw)
  if (!event) return false
  const key = runtimeEventKey(event)
  if (seenOasEventKeys.has(key)) {
    return false
  }
  seenOasEventKeys.add(key)
  ingestRuntimeProjection(event, opts)
  if (opts?.origin === 'replay') {
    oasTotalEvents.value = seenOasEventKeys.size
  } else {
    oasTotalEvents.value = Math.max(seenOasEventKeys.size, oasTotalEvents.value + 1)
  }
  return true
}

export function hydrateOasRuntimeFromTelemetryEntries(entries: TelemetryEntry[]): void {
  resetOasRuntimeSignals()
  seenOasEventKeys.clear()
  const ordered = [...entries].sort((a, b) => {
    const left = coerceOasRuntimeEnvelope(a)
    const right = coerceOasRuntimeEnvelope(b)
    return (left ? (eventReportedUnixSeconds(left) ?? 0) : 0) - (right ? (eventReportedUnixSeconds(right) ?? 0) : 0)
  })
  for (const entry of ordered) {
    applyOasRuntimeEvent(entry, { origin: 'replay' })
  }
  noteOasReplayWindow({
    loadedEvents: oasTotalEvents.value,
    totalMatchingEvents: oasTotalEvents.value,
    truncated: false,
  })
}

export function appendOasRuntimeFromTelemetryEntries(entries: TelemetryEntry[]): void {
  const ordered = [...entries].sort((a, b) => {
    const left = coerceOasRuntimeEnvelope(a)
    const right = coerceOasRuntimeEnvelope(b)
    return (left ? (eventReportedUnixSeconds(left) ?? 0) : 0) - (right ? (eventReportedUnixSeconds(right) ?? 0) : 0)
  })
  for (const entry of ordered) {
    applyOasRuntimeEvent(entry, { origin: 'replay' })
  }
}

export async function replayOasRuntimeTelemetry(signal?: AbortSignal): Promise<void> {
  const generation = ++replayGeneration
  const response = await fetchTelemetry({
    source: 'oas_event',
    n: OAS_TELEMETRY_REPLAY_LIMIT,
    signal,
  })
  if (generation !== replayGeneration) return
  hydrateOasRuntimeFromTelemetryEntries(response.entries)
  noteOasReplayWindow({
    loadedEvents: oasTotalEvents.value,
    totalMatchingEvents: response.total_matching_entries ?? response.count,
    truncated: response.has_more ?? response.truncated ?? false,
  })
}

export function ensureOasRuntimeReplay(): Promise<void> {
  if (oasReplayLoadedEvents.value > 0 || oasReplayTotalMatchingEvents.value > 0) {
    return Promise.resolve()
  }
  if (initialReplayPromise) return initialReplayPromise
  initialReplayPromise = replayOasRuntimeTelemetry()
    .finally(() => {
      initialReplayPromise = null
    })
  return initialReplayPromise
}

export async function loadMoreOasEvents(signal?: AbortSignal): Promise<void> {
  const currentOffset = oasAgentEvents.value.length
  const response = await fetchTelemetry({
    source: 'oas_event',
    n: OAS_TELEMETRY_REPLAY_LIMIT,
    offset: currentOffset,
    signal,
  })
  appendOasRuntimeFromTelemetryEntries(response.entries)
  noteOasReplayWindow({
    loadedEvents: oasTotalEvents.value,
    totalMatchingEvents: response.total_matching_entries ?? response.count,
    truncated: response.has_more ?? response.truncated ?? false,
  })
}
