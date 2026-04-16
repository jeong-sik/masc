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
  type KeeperCompositeSnapshot,
} from './schemas/keeper-composite'

export type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
  KeeperCompositeMeasurement,
  KeeperLastOutcome,
  KeeperCompositePhase,
  KeeperCompositeTurnPhase,
  KeeperCompositeDecisionStage,
  KeeperCompositeCascadeState,
  KeeperCompositeCompactionStage,
} from './schemas/keeper-composite'
export {
  KeeperCompositeSnapshotSchema,
  parseKeeperCompositeSnapshot,
  CompositeSchemaDriftError,
} from './schemas/keeper-composite'

// --- Types ---

export interface KeeperToolReply {
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
    let message = raw || `Streaming request failed (${res.status})`
    try {
      const parsed = JSON.parse(raw) as { error?: { message?: string }; message?: string }
      message = parsed.error?.message ?? parsed.message ?? message
    } catch {
      // Keep raw text fallback.
    }
    throw new Error(message)
  }

  if (!res.body) {
    throw new Error('Streaming response body is unavailable')
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

export interface KeeperChatHistoryMessage {
  role: string
  content: string
  ts: number
}

export async function fetchKeeperChatHistory(
  name: string,
): Promise<KeeperChatHistoryMessage[]> {
  try {
    const resp = await fetch(
      `/api/v1/keepers/${encodeURIComponent(name)}/chat/history`,
      { headers: jsonHeaders() },
    )
    if (!resp.ok) return []
    const data: unknown = await resp.json()
    if (!Array.isArray(data)) return []
    return data.filter(
      (m): m is KeeperChatHistoryMessage =>
        isRecord(m) &&
        typeof m.role === 'string' &&
        typeof m.content === 'string' &&
        typeof m.ts === 'number',
    )
  } catch {
    return []
  }
}

// --- Keeper lifecycle (boot / shutdown) ---

export interface KeeperLifecycleResponse {
  ok: boolean
  action?: 'boot' | 'shutdown'
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

async function safeKeeperLifecycle(url: string, fallbackError: string): Promise<KeeperLifecycleResponse> {
  try {
    const resp = await fetch(url, { method: 'POST', headers: jsonHeaders() })
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

// --- Keeper tool policy editing ---

export interface KeeperToolPolicyInput {
  action: 'set_policy'
  mode: 'preset' | 'custom' | 'full'
  preset?: 'minimal' | 'messaging' | 'coding' | 'research' | 'full'
  allow?: string[]
  also_allow?: string[]
  deny?: string[]
}

export interface ToolEditResponse {
  ok: boolean
  tool_policy_mode: 'preset' | 'custom' | string
  tool_preset?: 'minimal' | 'messaging' | 'coding' | 'research' | 'full' | null
  tool_also_allow: string[]
  tool_custom_allowlist: string[]
  resolved_allowlist: string[]
  tool_denylist: string[]
  active_masc_tool_count: number
  total_active: number
  error?: string
}

export async function editKeeperTools(
  name: string,
  payload: KeeperToolPolicyInput,
): Promise<ToolEditResponse> {
  const resp = await fetch(
    `/api/v1/keepers/${encodeURIComponent(name)}/tools`,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify(payload),
    },
  )
  if (!resp.ok) {
    const text = await resp.text().catch(() => resp.statusText)
    throw new Error(`Tool edit failed (${resp.status}): ${text}`)
  }
  return resp.json() as Promise<ToolEditResponse>
}

// --- Keeper observability API ---

export interface KeeperTransition {
  prev_phase: string
  new_phase: string
  selected_event: unknown
  wall_clock_at_decision: number
  transition_outcome: string
}

export interface KeeperTransitionsResponse {
  keeper: string
  current_phase: string | null
  count: number
  transitions: KeeperTransition[]
}

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
  return resp.json() as Promise<KeeperTransitionsResponse>
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
