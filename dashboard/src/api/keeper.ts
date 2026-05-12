// MASC Dashboard — Keeper messaging (direct, operator-mediated, SSE streaming)

import { isRecord } from '../components/common/normalize'
import {
  formatKeeperVisibleReply,
  normalizeKeeperConversationDetails,
} from '../keeper-message'
import type { KeeperConversationDetails } from '../types'
import { currentDashboardActor, jsonHeaders, runOperatorAction, fetchWithTimeout, DEFAULT_GET_TIMEOUT_MS } from './core'
import {
  parseKeeperCompositeSnapshot,
  parseFleetCompositeSnapshot,
  type KeeperCompositeSnapshot,
  type FleetCompositeSnapshot,
} from './schemas/keeper-composite'
import {
  safeParseKeeperChatHistoryMessage,
  type KeeperChatHistoryMessage,
} from './schemas/keeper-chat-history'
import {
  parseKeeperTransitionsResponse,
  type KeeperTransition,
  type KeeperTransitionsResponse,
} from './schemas/keeper-transitions'

export type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
  KeeperCompositeMeasurement,
  KeeperLastOutcome,
  KeeperCompositeExecution,
  KeeperRuntimeAttention,
  KeeperPhaseDiagnosis,
  KeeperPhaseDiagnosisRow,
  KeeperCompositePhase,
  KeeperCompositeTurnPhase,
  KeeperCompositeDecisionStage,
  KeeperCompositeCascadeState,
  KeeperCompositeCompactionStage,
  FleetCompositeSnapshot,
} from './schemas/keeper-composite'
export {
  KeeperCompositeSnapshotSchema,
  FleetCompositeSnapshotSchema,
  parseKeeperCompositeSnapshot,
  parseFleetCompositeSnapshot,
  CompositeSchemaDriftError,
} from './schemas/keeper-composite'
export type { KeeperChatHistoryMessage } from './schemas/keeper-chat-history'
export {
  KeeperChatHistoryMessageSchema,
  safeParseKeeperChatHistoryMessage,
} from './schemas/keeper-chat-history'
export type { KeeperTransition, KeeperTransitionsResponse }
export { KeeperTransitionsSchemaDriftError } from './schemas/keeper-transitions'

// --- Types ---

interface KeeperToolReply {
  text: string
  details: KeeperConversationDetails | null
}

// Server no longer enforces an external timeout for keeper_msg.
// Keeper internal limits (max_turns, max_cost_usd, max_tokens) control duration.
// Client-side abort via AbortSignal is the recommended cancellation path.

export interface KeeperChatStreamEvent {
  type: string
  threadId?: string
  runId?: string
  messageId?: string
  role?: string
  delta?: string
  name?: string
  value?: unknown
  timestamp?: number
}

// --- Direct and operator-mediated messaging ---

async function callKeeperMessageViaOperator(
  name: string,
  message: string,
): Promise<KeeperToolReply> {
  const payload: Record<string, unknown> = {
    message,
    direct_reply: true,
  }
  const response = await runOperatorAction({
    actor: currentDashboardActor(),
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: name,
    payload,
  })

  const resultPayload = isRecord(response.result) ? response.result : null
  const rawReply =
    resultPayload && typeof resultPayload.reply === 'string'
      ? resultPayload.reply
      : ''
  const detailsRaw =
    resultPayload && isRecord(resultPayload.result)
      ? resultPayload.result
      : resultPayload
  const details = normalizeKeeperConversationDetails(detailsRaw)
  const text = formatKeeperVisibleReply(rawReply || '(empty reply)')
  return { text, details }
}

export async function sendKeeperMessageDetailed(
  name: string,
  message: string,
): Promise<KeeperToolReply> {
  return callKeeperMessageViaOperator(name, message)
}

// --- SSE streaming ---

function parseSseFrames(chunk: string): { frames: string[]; rest: string } {
  const normalized = chunk.replace(/\r\n/g, '\n')
  const frames: string[] = []
  let start = 0
  for (;;) {
    const split = normalized.indexOf('\n\n', start)
    if (split < 0) {
      return {
        frames,
        rest: normalized.slice(start),
      }
    }
    frames.push(normalized.slice(start, split))
    start = split + 2
  }
}

function parseSseEvent(frame: string): KeeperChatStreamEvent | null {
  const dataLines = frame
    .split('\n')
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trimStart())
  if (dataLines.length === 0) return null
  try {
    return JSON.parse(dataLines.join('\n')) as KeeperChatStreamEvent
  } catch (err) {
    console.debug('[keeper-stream] SSE frame parse failed', dataLines.join('\n').slice(0, 120), err instanceof Error ? err.message : err)
    return null
  }
}

function isTerminalKeeperStreamEvent(event: KeeperChatStreamEvent): boolean {
  return event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR'
}

export async function streamKeeperMessage(
  name: string,
  message: string,
  {
    signal,
    onEvent,
  }: {
    signal?: AbortSignal
    onEvent: (event: KeeperChatStreamEvent) => void
  },
): Promise<void> {
  const res = await fetch('/api/v1/keepers/chat/stream', {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      Accept: 'text/event-stream',
    },
    body: JSON.stringify({
      name,
      message,
      direct_reply: true,
      }),
    signal,
  })

  if (!res.ok) {
    const raw = await res.text()
    let message = raw || `스트리밍 요청 실패 (${res.status})`
    try {
      const parsed = JSON.parse(raw) as { error?: { message?: string }; message?: string }
      message = parsed.error?.message ?? parsed.message ?? message
    } catch {
      // Keep raw text fallback.
    }
    throw new Error(message)
  }

  if (!res.body) {
    throw new Error('스트리밍 응답 본문 사용 불가')
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    for (;;) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done })
      const { frames, rest } = parseSseFrames(buffer)
      buffer = rest
      for (const frame of frames) {
        const event = parseSseEvent(frame)
        if (!event) continue
        onEvent(event)
        if (isTerminalKeeperStreamEvent(event)) {
          try {
            await reader.cancel()
          } catch {
            // Ignore stream cancellation errors after terminal events.
          }
          return
        }
      }
      if (done) break
    }
    const tail = buffer.trim()
    if (tail) {
      const event = parseSseEvent(tail)
      if (event) onEvent(event)
    }
  } finally {
    reader.releaseLock()
  }
}

// --- Chat history ---

export async function fetchKeeperChatHistory(
  name: string,
): Promise<KeeperChatHistoryMessage[]> {
  // P1 silent-failure fix: previously HTTP non-2xx and network/parse
  // errors both mapped to `return []`, leaving the caller unable to
  // distinguish "no chat history yet" from "fetch failed."  Now both
  // throw, and the caller (keeper-chat-panel.ts) is responsible for
  // surfacing via chatError.value.  Per-item safeParse drift remains
  // tolerant — only network / HTTP / shape errors throw.
  const resp = await fetch(
    `/api/v1/keepers/${encodeURIComponent(name)}/chat/history`,
    { headers: jsonHeaders() },
  )
  if (!resp.ok) {
    throw new Error(`fetchKeeperChatHistory: HTTP ${resp.status} ${resp.statusText}`)
  }
  const data: unknown = await resp.json()
  if (!Array.isArray(data)) {
    throw new Error('fetchKeeperChatHistory: response is not an array')
  }
  return data
    .map(safeParseKeeperChatHistoryMessage)
    .filter((m): m is KeeperChatHistoryMessage => m !== null)
}

// --- Keeper lifecycle (boot / shutdown) ---

interface KeeperLifecycleResponse {
  ok: boolean
  action?: 'boot' | 'shutdown' | 'reset' | 'clear'
  name?: string
  detail?: unknown
  error?: string
}

async function safeJsonResponse<T>(resp: Response, fallbackError: string): Promise<T> {
  try {
    const body = await resp.text()
    if (!body.trim()) {
      return resp.ok
        ? ({ ok: true } as T)
        : ({ ok: false, error: `${fallbackError} (HTTP ${resp.status})` } as T)
    }

    try {
      return JSON.parse(body) as T
    } catch {
      return resp.ok
        ? ({ ok: true, detail: body } as T)
        : ({ ok: false, error: `${fallbackError} (HTTP ${resp.status}): ${body}` } as T)
    }
  } catch {
    return { ok: false, error: `${fallbackError} (HTTP ${resp.status})` } as T
  }
}

async function safeKeeperLifecycle(
  url: string,
  fallbackError: string,
  init?: RequestInit,
): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: jsonHeaders(),
      ...init,
    })
    const payload = await safeJsonResponse<KeeperLifecycleResponse>(resp, fallbackError)
    if (resp.ok) return payload

    const error =
      isRecord(payload) &&
      typeof payload.error === 'string' &&
      payload.error.trim() !== ''
        ? payload.error
        : `${fallbackError} (HTTP ${resp.status})`

    if (isRecord(payload)) {
      return { ...payload, ok: false, error }
    }

    return { ok: false, error }
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

async function safeKeeperPostWithBody(
  url: string,
  body: Record<string, unknown>,
  fallbackError: string,
): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify(body),
    })
    const payload = await safeJsonResponse<KeeperLifecycleResponse>(resp, fallbackError)
    if (resp.ok) return payload

    const error =
      isRecord(payload) &&
      typeof payload.error === 'string' &&
      payload.error.trim() !== ''
        ? payload.error
        : `${fallbackError} (HTTP ${resp.status})`

    if (isRecord(payload)) {
      return { ...payload, ok: false, error }
    }

    return { ok: false, error }
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : fallbackError }
  }
}

export function bootKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/boot`,
    `Failed to boot ${name}`,
  )
}

export function shutdownKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/shutdown`,
    `Failed to shut down ${name}`,
  )
}

export function resetKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/reset`,
    `Failed to reset ${name}`,
  )
}

interface KeeperClearRequest {
  reason: string
  preserve_system_prompt?: boolean
}

export function clearKeeper(
  name: string,
  payload: KeeperClearRequest,
): Promise<KeeperLifecycleResponse> {
  return safeKeeperLifecycle(
    `/api/v1/keepers/${encodeURIComponent(name)}/clear`,
    `Failed to clear ${name}`,
    {
      body: JSON.stringify(payload),
    },
  )
}

export interface KeeperCheckpointSummary {
  snapshot_id: string
  source_kind: 'oas_current' | 'oas_history' | string
  is_current: boolean
  path: string
  created_at: number
  generation: number
  message_count: number
  system_prompt_present: boolean
  latest_preview: string | null
  continuity_summary: string | null
  file_stat: {
    size_bytes?: number
    mtime?: number
  } | null
}

export interface KeeperCheckpointInventory {
  keeper: string
  trace_id: string
  session_dir: string
  current: KeeperCheckpointSummary | null
  history: KeeperCheckpointSummary[]
  legacy_shadow_count: number
}

interface KeeperCheckpointDeleteResponse {
  ok: boolean
  action: 'delete_history' | string
  keeper: string
  deleted_snapshot_ids: string[]
  missing_snapshot_ids: string[]
  inventory: KeeperCheckpointInventory
}

export async function fetchKeeperCheckpoints(
  name: string,
): Promise<KeeperCheckpointInventory> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/checkpoints`,
    {
      method: 'GET',
      headers: jsonHeaders(),
    },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText)
    throw new Error(`${name} 의 checkpoint 로드 실패 (${resp.status}): ${text}`)
  }
  return resp.json() as Promise<KeeperCheckpointInventory>
}

export async function deleteKeeperHistorySnapshots(
  name: string,
  snapshotIds: string[],
): Promise<KeeperCheckpointDeleteResponse> {
  const resp = await fetch(
    `/api/v1/keepers/${encodeURIComponent(name)}/checkpoints`,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({
        action: 'delete_history',
        snapshot_ids: snapshotIds,
      }),
    },
  )
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText)
    throw new Error(`${name} 의 checkpoint history 삭제 실패 (${resp.status}): ${text}`)
  }
  return resp.json() as Promise<KeeperCheckpointDeleteResponse>
}

export function pauseKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'pause' },
    `Failed to pause ${name}`,
  )
}

export function resumeKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'resume' },
    `Failed to resume ${name}`,
  )
}

export function wakeKeeper(name: string): Promise<KeeperLifecycleResponse> {
  return safeKeeperPostWithBody(
    `/api/v1/keepers/${encodeURIComponent(name)}/directive`,
    { action: 'wakeup' },
    `Failed to wake ${name}`,
  )
}

// --- Keeper observability API ---

export interface MemoryKindUsageEntry {
  kind: string
  used: number
  cap: number
  priority: number
}

export interface KeeperStateDiagramResponse {
  keeper: string
  current_phase: string
  mermaid: string
  decision_pipeline_mermaid?: string
  cascade_fsm_mermaid?: string
  compaction_submachine_mermaid?: string | null
  // Structured data for Cytoscape FSM rendering
  thompson_alpha?: number
  thompson_beta?: number
  tool_count?: number
  recovery_floor_count?: number
  cascade_models?: string[]
  last_provider_result?: string | null
  memory_kind_usage?: MemoryKindUsageEntry[]
}

export async function fetchKeeperTransitions(
  name: string,
  limit = 20,
  opts?: { signal?: AbortSignal },
): Promise<KeeperTransitionsResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/transitions?limit=${limit}`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`transitions fetch failed: ${resp.status}`)
  return parseKeeperTransitionsResponse(await resp.json())
}

// --- Keeper lifecycle timeline (#12798) ---

export interface KeeperLifecycleEvent {
  ts: number
  event: string
  phase: string | null
  detail: string
}

export interface KeeperLifecycleTimelineResponse {
  keeper: string
  count: number
  events: KeeperLifecycleEvent[]
}

function parseKeeperLifecycleEvent(raw: unknown): KeeperLifecycleEvent {
  if (!isRecord(raw)) throw new Error('lifecycle event is not a record')
  return {
    ts: typeof raw.ts === 'number' ? raw.ts : 0,
    event: typeof raw.event === 'string' ? raw.event : '',
    phase: typeof raw.phase === 'string' ? raw.phase : null,
    detail: typeof raw.detail === 'string' ? raw.detail : '',
  }
}

export function parseKeeperLifecycleResponse(raw: unknown): KeeperLifecycleTimelineResponse {
  if (!isRecord(raw)) throw new Error('lifecycle response is not a record')
  const events = Array.isArray(raw.events) ? raw.events.map(parseKeeperLifecycleEvent) : []
  return {
    keeper: typeof raw.keeper === 'string' ? raw.keeper : '',
    count: typeof raw.count === 'number' ? raw.count : events.length,
    events,
  }
}

export async function fetchKeeperLifecycle(
  name: string,
  limit = 50,
  opts?: { signal?: AbortSignal },
): Promise<KeeperLifecycleTimelineResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/lifecycle?limit=${limit}`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`lifecycle fetch failed: ${resp.status}`)
  return parseKeeperLifecycleResponse(await resp.json())
}

export async function fetchKeeperStateDiagram(
  name: string,
  opts?: { signal?: AbortSignal },
): Promise<KeeperStateDiagramResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/state-diagram`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`state-diagram fetch failed: ${resp.status}`)
  return resp.json() as Promise<KeeperStateDiagramResponse>
}

export async function fetchKeeperComposite(
  name: string,
  opts?: { signal?: AbortSignal },
): Promise<KeeperCompositeSnapshot> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/composite`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`composite fetch failed: ${resp.status}`)
  return parseKeeperCompositeSnapshot(await resp.json())
}

// --- Runtime trace evidence ---

export interface KeeperRuntimeTraceTurnIdentity {
  requested_keeper_turn_id: number | null
  manifest_keeper_turn_ids: number[]
  receipt_turn_counts: number[]
  max_oas_turn_count: number | null
  provider_lane_resolved_count: number
  provider_attempt_started_count: number
  provider_attempt_finished_count: number
  checkpoint_saved_count: number
  event_bus_correlated_count: number
  memory_injected_count: number
  memory_flushed_count: number
  receipt_appended_count: number
  turn_finished_count: number
}

export interface KeeperRuntimeTraceEventBusSummary {
  event_bus_correlated_count: number
  correlation_ids: string[]
  run_ids: string[]
  context_compact_started_count: number
  context_compacted_count: number
  last_compaction: unknown | null
}

export interface KeeperRuntimeTraceMemorySummary {
  memory_injected_count: number
  memory_injected_present_count: number
  memory_flushed_count: number
  memory_flush_success_count: number
  memory_flush_error_count: number
  episodes_flushed: number
  procedures_flushed: number
}

export interface KeeperRuntimeTraceProviderAttempt {
  ts: string
  event: string
  cascade_name: string | null
  provider_kind: string | null
  model_id: string | null
  status: string
  error: string | null
  exception_kind: string | null
}

export interface KeeperRuntimeTraceProviderAttemptsSummary {
  started_count: number
  finished_count: number
  terminal_status: string | null
  terminal_provider_kind: string | null
  terminal_model_id: string | null
  terminal_error: string | null
  terminal_exception_kind: string | null
  attempts: KeeperRuntimeTraceProviderAttempt[]
}

export interface KeeperRuntimeTraceResponse {
  keeper: string
  trace_id: string
  turn_id: number | null
  manifest_path: string
  manifest_path_present: boolean
  manifest_total_rows: number
  manifest_returned_rows: number
  receipt_returned_rows: number
  turn_identity: KeeperRuntimeTraceTurnIdentity
  provider_attempts: KeeperRuntimeTraceProviderAttemptsSummary
  event_bus: KeeperRuntimeTraceEventBusSummary
  memory: KeeperRuntimeTraceMemorySummary
  health: string
  stale_reason: string | null
}

function numberField(raw: Record<string, unknown>, key: string): number {
  const value = raw[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function nullableNumberField(raw: Record<string, unknown>, key: string): number | null {
  const value = raw[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function stringField(raw: Record<string, unknown>, key: string): string {
  const value = raw[key]
  return typeof value === 'string' ? value : ''
}

function nullableStringField(raw: Record<string, unknown>, key: string): string | null {
  const value = raw[key]
  return typeof value === 'string' ? value : null
}

function numberListField(raw: Record<string, unknown>, key: string): number[] {
  const value = raw[key]
  if (!Array.isArray(value)) return []
  return value.filter((item): item is number => typeof item === 'number' && Number.isFinite(item))
}

function stringListField(raw: Record<string, unknown>, key: string): string[] {
  const value = raw[key]
  if (!Array.isArray(value)) return []
  return value.filter((item): item is string => typeof item === 'string')
}

function parseRuntimeTraceTurnIdentity(raw: unknown): KeeperRuntimeTraceTurnIdentity {
  const obj = isRecord(raw) ? raw : {}
  return {
    requested_keeper_turn_id: nullableNumberField(obj, 'requested_keeper_turn_id'),
    manifest_keeper_turn_ids: numberListField(obj, 'manifest_keeper_turn_ids'),
    receipt_turn_counts: numberListField(obj, 'receipt_turn_counts'),
    max_oas_turn_count: nullableNumberField(obj, 'max_oas_turn_count'),
    provider_lane_resolved_count: numberField(obj, 'provider_lane_resolved_count'),
    provider_attempt_started_count: numberField(obj, 'provider_attempt_started_count'),
    provider_attempt_finished_count: numberField(obj, 'provider_attempt_finished_count'),
    checkpoint_saved_count: numberField(obj, 'checkpoint_saved_count'),
    event_bus_correlated_count: numberField(obj, 'event_bus_correlated_count'),
    memory_injected_count: numberField(obj, 'memory_injected_count'),
    memory_flushed_count: numberField(obj, 'memory_flushed_count'),
    receipt_appended_count: numberField(obj, 'receipt_appended_count'),
    turn_finished_count: numberField(obj, 'turn_finished_count'),
  }
}

function parseRuntimeTraceEventBus(raw: unknown): KeeperRuntimeTraceEventBusSummary {
  const obj = isRecord(raw) ? raw : {}
  return {
    event_bus_correlated_count: numberField(obj, 'event_bus_correlated_count'),
    correlation_ids: stringListField(obj, 'correlation_ids'),
    run_ids: stringListField(obj, 'run_ids'),
    context_compact_started_count: numberField(obj, 'context_compact_started_count'),
    context_compacted_count: numberField(obj, 'context_compacted_count'),
    last_compaction: obj.last_compaction ?? null,
  }
}

function parseRuntimeTraceMemory(raw: unknown): KeeperRuntimeTraceMemorySummary {
  const obj = isRecord(raw) ? raw : {}
  return {
    memory_injected_count: numberField(obj, 'memory_injected_count'),
    memory_injected_present_count: numberField(obj, 'memory_injected_present_count'),
    memory_flushed_count: numberField(obj, 'memory_flushed_count'),
    memory_flush_success_count: numberField(obj, 'memory_flush_success_count'),
    memory_flush_error_count: numberField(obj, 'memory_flush_error_count'),
    episodes_flushed: numberField(obj, 'episodes_flushed'),
    procedures_flushed: numberField(obj, 'procedures_flushed'),
  }
}

function parseRuntimeTraceProviderAttempt(raw: unknown): KeeperRuntimeTraceProviderAttempt {
  const obj = isRecord(raw) ? raw : {}
  return {
    ts: stringField(obj, 'ts'),
    event: stringField(obj, 'event'),
    cascade_name: nullableStringField(obj, 'cascade_name'),
    provider_kind: nullableStringField(obj, 'provider_kind'),
    model_id: nullableStringField(obj, 'model_id'),
    status: stringField(obj, 'status'),
    error: nullableStringField(obj, 'error'),
    exception_kind: nullableStringField(obj, 'exception_kind'),
  }
}

function parseRuntimeTraceProviderAttempts(raw: unknown): KeeperRuntimeTraceProviderAttemptsSummary {
  const obj = isRecord(raw) ? raw : {}
  const attempts = Array.isArray(obj.attempts)
    ? obj.attempts.map(parseRuntimeTraceProviderAttempt)
    : []
  return {
    started_count: numberField(obj, 'started_count'),
    finished_count: numberField(obj, 'finished_count'),
    terminal_status: nullableStringField(obj, 'terminal_status'),
    terminal_provider_kind: nullableStringField(obj, 'terminal_provider_kind'),
    terminal_model_id: nullableStringField(obj, 'terminal_model_id'),
    terminal_error: nullableStringField(obj, 'terminal_error'),
    terminal_exception_kind: nullableStringField(obj, 'terminal_exception_kind'),
    attempts,
  }
}

export function parseKeeperRuntimeTrace(raw: unknown): KeeperRuntimeTraceResponse {
  if (!isRecord(raw)) throw new Error('runtime trace response is not a record')
  return {
    keeper: stringField(raw, 'keeper'),
    trace_id: stringField(raw, 'trace_id'),
    turn_id: nullableNumberField(raw, 'turn_id'),
    manifest_path: stringField(raw, 'manifest_path'),
    manifest_path_present: raw.manifest_path_present === true,
    manifest_total_rows: numberField(raw, 'manifest_total_rows'),
    manifest_returned_rows: numberField(raw, 'manifest_returned_rows'),
    receipt_returned_rows: numberField(raw, 'receipt_returned_rows'),
    turn_identity: parseRuntimeTraceTurnIdentity(raw.turn_identity),
    provider_attempts: parseRuntimeTraceProviderAttempts(raw.provider_attempts),
    event_bus: parseRuntimeTraceEventBus(raw.event_bus),
    memory: parseRuntimeTraceMemory(raw.memory),
    health: stringField(raw, 'health') || 'unknown',
    stale_reason: nullableStringField(raw, 'stale_reason'),
  }
}

export async function fetchKeeperRuntimeTrace(
  name: string,
  opts?: { traceId?: string; turnId?: number; limit?: number; signal?: AbortSignal },
): Promise<KeeperRuntimeTraceResponse> {
  const params = new URLSearchParams()
  if (opts?.traceId) params.set('trace_id', opts.traceId)
  if (typeof opts?.turnId === 'number') params.set('turn_id', String(opts.turnId))
  if (typeof opts?.limit === 'number') params.set('limit', String(opts.limit))
  const qs = params.toString()
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/runtime-trace${qs ? `?${qs}` : ''}`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`runtime trace fetch failed: ${resp.status}`)
  return parseKeeperRuntimeTrace(await resp.json())
}

/**
 * LT-16a: fetch the fleet-wide composite snapshot in one envelope.
 * Backend reuses the same per-snapshot shape as fetchKeeperComposite,
 * wrapped in { generated_at, count, snapshots: [...] }.
 */
export async function fetchKeepersComposite(
  opts?: { signal?: AbortSignal },
): Promise<FleetCompositeSnapshot> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/composite`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`fleet composite fetch failed: ${resp.status}`)
  return parseFleetCompositeSnapshot(await resp.json())
}

// --- Eval Quality (RFC-MASC-005 Phase 3) ---

export interface EvalLayerResult {
  layer_name: string
  passed: boolean
  score: number | null
  evidence: string[]
  detail: string | null
}

export interface EvalVerdict {
  schema_version: number
  all_passed: boolean
  coverage: number
  layer_results: EvalLayerResult[]
}

export interface EvalSnapshot {
  agent_name: string
  session_id: string | null
  worker_run_id: string
  timestamp: number
  verdict: EvalVerdict
  baseline_status: string | null
}

export interface KeeperEvalResponse {
  keeper: string
  count: number
  latest_coverage: number | null
  latest_all_passed: boolean | null
  snapshots: EvalSnapshot[]
}

export async function fetchKeeperEval(name: string, limit = 10): Promise<KeeperEvalResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/eval?limit=${limit}`,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`eval fetch failed: ${resp.status}`)
  return resp.json() as Promise<KeeperEvalResponse>
}
