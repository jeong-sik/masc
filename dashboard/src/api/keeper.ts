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
