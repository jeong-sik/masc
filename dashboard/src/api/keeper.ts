// MASC Dashboard — Keeper messaging (operator-mediated queue, SSE streaming)

import { asString, isRecord } from '../components/common/normalize'
import {
  formatKeeperVisibleReply,
  keeperTurnOutcomeSuppressesReply,
  normalizeKeeperConversationDetails,
} from '../keeper-message'
import type { KeeperConversationDetails, KeeperUserInputBlock } from '../types'
import type { DashboardAuthErrorCode } from '../types/dashboard-execution'
import {
  currentDashboardActor,
  apiRequestErrorFromResponse,
  clearStoredToken,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  jsonHeaders,
  runOperatorAction,
  fetchWithTimeout,
  DEFAULT_GET_TIMEOUT_MS,
  DEFAULT_POST_TIMEOUT_MS,
} from './core'
import { ensureDevToken, resetDevTokenBootstrap } from './dev-token'
import type {
  KeeperCompositeSnapshot,
  FleetCompositeSnapshot,
} from './schemas/keeper-composite'
import type { KeeperChatHistoryMessage } from './schemas/keeper-chat-history'
import type { KeeperCatchupDigest } from './schemas/keeper-catchup-digest'
import type {
  KeeperTransition,
  KeeperTransitionsResponse,
} from './schemas/keeper-transitions'

export type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
  KeeperCompositeMeasurement,
  KeeperLastOutcome,
  KeeperLiveTurn,
  KeeperLastSkip,
  KeeperLivelock,
  KeeperBoardCursor,
  KeeperCompositeExecution,
  KeeperRuntimeAttention,
  KeeperSecretProjection,
  KeeperSecretFileMount,
  KeeperPhaseDiagnosis,
  KeeperPhaseDiagnosisRow,
  KeeperCompositePhase,
  KeeperCompositeTurnPhase,
  KeeperCompositeDecisionStage,
  KeeperCompositeRuntimeState,
  KeeperCompositeCompactionStage,
  FleetCompositeSnapshot,
} from './schemas/keeper-composite'
export type { KeeperChatHistoryMessage } from './schemas/keeper-chat-history'
export type { KeeperTransition, KeeperTransitionsResponse }

// --- Runtime trace evidence (split to keeper-runtime-trace.ts) ---
export type {
  KeeperRuntimeTraceTurnIdentity,
  KeeperRuntimeTraceEventBusSummary,
  KeeperRuntimeTraceMemorySummary,
  KeeperRuntimeTraceProviderAttempt,
  KeeperRuntimeTraceProviderAttemptsSummary,
  KeeperRuntimeLensTurnClock,
  KeeperRuntimeLensLifecycleAxis,
  KeeperRuntimeLensProviderLaneAxis,
  KeeperRuntimeLensProviderAttemptAxis,
  KeeperRuntimeLensPayloadRoleAxis,
  KeeperRuntimeLensSourceClockAxis,
  KeeperRuntimeLensClaimScopeAxis,
  KeeperRuntimeLensConfigDriftAxis,
  KeeperRuntimeLensContextAxis,
  KeeperRuntimeLensMemoryAxis,
  KeeperRuntimeLensAxes,
  KeeperRuntimeLensLaneEvent,
  KeeperRuntimeLensLane,
  KeeperRuntimeLensSwimlanes,
  KeeperRuntimeLensGap,
  KeeperRuntimeLensClockEdgeLinks,
  KeeperRuntimeLensClockEdge,
  KeeperRuntimeLensClockGroup,
  KeeperRuntimeLens,
  KeeperRuntimeTraceLinkedArtifact,
  KeeperRuntimeTraceLinkedArtifacts,
  KeeperRuntimeTraceResponse,
} from './keeper-runtime-trace'
export {
  parseKeeperRuntimeTrace,
  fetchKeeperRuntimeTrace,
} from './keeper-runtime-trace'

// --- Keeper lifecycle (split to keeper-lifecycle.ts) ---
export type {
  KeeperCheckpointSummary,
  KeeperCheckpointInventory,
  BulkKeeperDirectiveAction,
  BulkKeeperDirectiveResult,
  BulkKeeperDirectiveResponse,
} from './keeper-lifecycle'
export {
  bootKeeper,
  shutdownKeeper,
  resetKeeper,
  clearKeeper,
  pauseKeeper,
  resumeKeeper,
  wakeKeeper,
  fetchKeeperCheckpoints,
  deleteKeeperHistorySnapshots,
  bulkKeeperDirective,
} from './keeper-lifecycle'

// --- Types ---

export interface KeeperToolReply {
  text: string
  details: KeeperConversationDetails | null
}

export type QueuedKeeperMessageStatus =
  | 'queued'
  | 'running'
  | 'done'
  | 'error'
  | 'lost'
  | 'cancelled'

export interface QueuedKeeperMessageSubmission {
  requestId: string
  keeperName: string
  status: QueuedKeeperMessageStatus
  message?: string
}

export interface QueuedKeeperMessageResult {
  requestId: string
  keeperName: string
  status: QueuedKeeperMessageStatus
  submittedAt?: number
  completedAt?: number
  elapsedSec?: number
  ok?: boolean
  result?: unknown
}

export interface QueuedKeeperMessageCancelResult {
  requestId: string
  status: QueuedKeeperMessageStatus
  message?: string
}

const TERMINAL_QUEUED_KEEPER_MESSAGE_STATUSES = new Set<QueuedKeeperMessageStatus>([
  'done',
  'error',
  'lost',
  'cancelled',
])

function normalizeQueuedKeeperMessageStatus(value: unknown): QueuedKeeperMessageStatus {
  switch (asString(value, '').trim()) {
    case 'queued':
      return 'queued'
    case 'running':
      return 'running'
    case 'done':
      return 'done'
    case 'error':
      return 'error'
    case 'lost':
      return 'lost'
    case 'cancelled':
      return 'cancelled'
    default:
      return 'error'
  }
}

function optionalNumberField(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function parseQueuedKeeperMessageSubmission(data: unknown): QueuedKeeperMessageSubmission {
  const record = isRecord(data) ? data : null
  const requestId = asString(record?.request_id, '').trim()
  if (!requestId) {
    throw new Error('keeper message queue response missing request_id')
  }
  return {
    requestId,
    keeperName: (asString(record?.keeper_name) ?? asString(record?.destination_id, '')).trim(),
    status: normalizeQueuedKeeperMessageStatus(record?.status),
    message: asString(record?.message),
  }
}

function parseQueuedKeeperMessageResult(data: unknown): QueuedKeeperMessageResult {
  const record = isRecord(data) ? data : null
  const requestId = asString(record?.request_id, '').trim()
  if (!requestId) {
    throw new Error('keeper message result response missing request_id')
  }
  return {
    requestId,
    keeperName: (asString(record?.keeper_name) ?? asString(record?.destination_id, '')).trim(),
    status: normalizeQueuedKeeperMessageStatus(record?.status),
    submittedAt: record ? optionalNumberField(record, 'submitted_at') : undefined,
    completedAt: record ? optionalNumberField(record, 'completed_at') : undefined,
    elapsedSec: record ? optionalNumberField(record, 'elapsed_sec') : undefined,
    ok: typeof record?.ok === 'boolean' ? record.ok : undefined,
    result: record?.result,
  }
}

function parseQueuedKeeperMessageCancelResult(data: unknown): QueuedKeeperMessageCancelResult {
  const record = isRecord(data) ? data : null
  const requestId = asString(record?.request_id, '').trim()
  if (!requestId) {
    throw new Error('keeper message cancel response missing request_id')
  }
  return {
    requestId,
    status: normalizeQueuedKeeperMessageStatus(record?.status),
    message: asString(record?.message),
  }
}

export function isTerminalQueuedKeeperMessage(result: QueuedKeeperMessageResult): boolean {
  return TERMINAL_QUEUED_KEEPER_MESSAGE_STATUSES.has(result.status)
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
  snapshot?: string
  name?: string
  value?: unknown
  timestamp?: number
  // AG-UI tool call fields (TOOL_CALL_START / TOOL_CALL_ARGS / TOOL_CALL_END)
  toolCallId?: string
  toolCallName?: string
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

export async function submitQueuedKeeperMessage(
  name: string,
  message: string,
): Promise<QueuedKeeperMessageSubmission> {
  const response = await runOperatorAction({
    actor: currentDashboardActor(),
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: name,
    payload: {
      message,
      direct_reply: true,
    },
  })
  const operatorResult = isRecord(response.result) ? response.result : null
  const queuePayload =
    operatorResult && isRecord(operatorResult.result)
      ? operatorResult.result
      : operatorResult
  return parseQueuedKeeperMessageSubmission(queuePayload)
}

export async function fetchQueuedKeeperMessageResult(
  requestId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<QueuedKeeperMessageResult> {
  const path = `/api/v1/gate/message/requests/${encodeURIComponent(requestId)}`
  const resp = await fetchWithTimeout(
    path,
    { headers: jsonHeaders(), signal: opts.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('GET', path, resp)
  }
  return parseQueuedKeeperMessageResult(await resp.json())
}

export async function cancelQueuedKeeperMessage(
  requestId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<QueuedKeeperMessageCancelResult> {
  const path = `/api/v1/gate/message/requests/${encodeURIComponent(requestId)}/cancel`
  const resp = await fetchWithTimeout(
    path,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: '{}',
      signal: opts.signal,
    },
    DEFAULT_POST_TIMEOUT_MS,
  )
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('POST', path, resp)
  }
  return parseQueuedKeeperMessageCancelResult(await resp.json())
}

export function queuedKeeperMessageError(result: QueuedKeeperMessageResult): string {
  if (result.status === 'cancelled') return '요청이 취소되었습니다.'
  const payload = isRecord(result.result) ? result.result : null
  const message = asString(payload?.message) ?? asString(payload?.reason)
  const error = asString(payload?.error)
  return message ?? error ?? `Keeper message request ${result.requestId} ended with ${result.status}`
}

export function queuedKeeperMessageToReply(result: QueuedKeeperMessageResult): KeeperToolReply {
  if (result.status === 'cancelled') {
    return {
      text: '요청이 취소되었습니다.',
      details: null,
    }
  }
  const payload = isRecord(result.result) ? result.result : null
  const rawReply = asString(payload?.reply, '').trim()
  const details = normalizeKeeperConversationDetails(payload ?? result.result)
  if (result.status === 'done' && keeperTurnOutcomeSuppressesReply(details?.turnOutcome)) {
    return {
      text: '',
      details,
    }
  }
  const fallback = rawReply || queuedKeeperMessageError(result)
  return {
    text: formatKeeperVisibleReply(fallback || '(empty reply)'),
    details,
  }
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

export interface StreamAttachment {
  id: string
  type: 'image' | 'file'
  name: string
  size: number
  mimeType: string
  data: string
}

/** Co-view context sent from dashboard surfaces such as the Copilot Dock. */
export interface KeeperStreamSurfaceContext {
  label: string
  route: string
  scene: string
  fields: unknown
}

/** Outcome of a keeper chat stream read loop.
 *  `terminal: false` means the connection closed without a
 *  RUN_FINISHED / RUN_ERROR event — the response was cut mid-stream
 *  and callers must not present it as a completed reply. */
export interface KeeperStreamOutcome {
  terminal: boolean
}

function keeperStreamErrorMessage(raw: string, status: number): string {
  let message = raw || `스트리밍 요청 실패 (${status})`
  try {
    const parsed = JSON.parse(raw) as { error?: string | { message?: string }; message?: string }
    if (typeof parsed.error === 'string') {
      message = parsed.error
    } else {
      message = parsed.error?.message ?? parsed.message ?? message
    }
  } catch {
    // Keep raw text fallback.
  }
  return message
}

/**
 * Auth error codes that mean the stored bearer token is stale or wrong for
 * the requested actor — minting a fresh dev token and retrying can recover.
 * `same_origin_blocked` / `insufficient_role` / `missing_token` are NOT here:
 * a token refresh cannot fix a CORS rejection, a role shortfall, or a request
 * that simply omitted the token.
 */
const STALE_TOKEN_AUTH_CODES: ReadonlySet<DashboardAuthErrorCode> = new Set([
  'invalid_token',
  'token_expired',
  'actor_mismatch',
])

/**
 * Decide whether a 401 body signals a stale/wrong bearer token.
 * Primary gate: the typed `auth_error_code` field in the JSON body
 * (server SSOT: `lib/types/masc_error.ml:dashboard_auth_error_code`,
 * emitted by `lib/server/server_auth.ml:auth_error_json`).
 */
function isStaleTokenAuthError(raw: string): boolean {
  try {
    const parsed = JSON.parse(raw) as { auth_error_code?: unknown }
    const code = parsed.auth_error_code
    if (typeof code === 'string') {
      return STALE_TOKEN_AUTH_CODES.has(code as DashboardAuthErrorCode)
    }
  } catch {
    return false
  }
  return false
}

async function refreshLoopbackDevTokenAfterMismatch(): Promise<boolean> {
  if (isRemoteAccess() || !getStoredToken()) return false
  const meta = getStoredTokenMeta()
  if (meta?.source === 'manual') return false

  clearStoredToken()
  resetDevTokenBootstrap()
  await ensureDevToken()
  return getStoredToken() !== null
}

export interface StreamKeeperMessageOptions {
  signal?: AbortSignal
  onEvent: (event: KeeperChatStreamEvent) => void
  attachments?: StreamAttachment[]
  userBlocks?: KeeperUserInputBlock[]
  channel?: string
  channelWorkspaceId?: string
  turnInstructions?: string
  surfaceContext?: KeeperStreamSurfaceContext
}

function streamUserBlockToWire(block: KeeperUserInputBlock): Record<string, unknown> {
  if (block.type === 'text') {
    return {
      type: 'text',
      text: block.text,
    }
  }
  return {
    type: block.type,
    attachment_id: block.attachmentId,
    name: block.name,
    mime_type: block.mimeType,
    size: block.size,
  }
}

export async function streamKeeperMessage(
  name: string,
  message: string,
  {
    signal,
    onEvent,
    attachments,
    userBlocks,
    channel,
    channelWorkspaceId,
    turnInstructions,
    surfaceContext,
  }: StreamKeeperMessageOptions,
): Promise<KeeperStreamOutcome> {
  const body: Record<string, unknown> = {
    name,
    message,
    direct_reply: true,
  }
  if (channel && channel.trim() !== '') {
    body.channel = channel.trim()
  }
  if (channelWorkspaceId && channelWorkspaceId.trim() !== '') {
    body.channel_workspace_id = channelWorkspaceId.trim()
  }
  if (turnInstructions && turnInstructions.trim() !== '') {
    body.turn_instructions = turnInstructions.trim()
  }
  if (surfaceContext && Object.keys(surfaceContext).length > 0) {
    body.surface_context = surfaceContext
  }
  if (attachments && attachments.length > 0) {
    body.attachments = attachments.map(att => ({
      id: att.id,
      type: att.type,
      name: att.name,
      size: att.size,
      mime_type: att.mimeType,
      data: att.data,
    }))
  }
  if (userBlocks && userBlocks.length > 0) {
    body.user_blocks = userBlocks.map(streamUserBlockToWire)
  }
  const requestBody = JSON.stringify(body)
  const postStream = () => fetch('/api/v1/keepers/chat/stream', {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      Accept: 'text/event-stream',
    },
    body: requestBody,
    signal,
  })

  let res = await postStream()

  if (!res.ok) {
    let raw = await res.text()
    if (
      res.status === 401
      && isStaleTokenAuthError(raw)
      && await refreshLoopbackDevTokenAfterMismatch()
    ) {
      res = await postStream()
      if (res.ok) {
        raw = ''
      } else {
        raw = await res.text()
      }
    }
    if (!res.ok) {
      throw new Error(keeperStreamErrorMessage(raw, res.status))
    }
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
          return { terminal: true }
        }
      }
      if (done) break
    }
    const tail = buffer.trim()
    if (tail) {
      const event = parseSseEvent(tail)
      if (event) {
        onEvent(event)
        if (isTerminalKeeperStreamEvent(event)) return { terminal: true }
      }
    }
    // Connection closed without RUN_FINISHED / RUN_ERROR: mid-stream cut.
    return { terminal: false }
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
  // throw, and the caller (hydrateKeeperChatHistory in
  // keeper-actions.ts) is responsible for surfacing the failure to
  // the operator.  Per-item safeParse drift remains
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
  const { safeParseKeeperChatHistoryMessage } = await import('./schemas/keeper-chat-history')
  return data
    .map(safeParseKeeperChatHistoryMessage)
    .filter((m): m is KeeperChatHistoryMessage => m !== null)
}

// Since-last-seen catch-up digest for one keeper. `sinceUnix` is the operator's
// per-keeper last-seen cursor (unix seconds). The whole payload is decoded and
// thrown on drift (unlike chat history's tolerant per-row drop) so a malformed
// digest can never render a wrong count. Same raw-fetch + jsonHeaders()
// convention as fetchKeeperChatHistory; the valibot schema is imported lazily
// to keep it out of the initial bundle.
export async function fetchKeeperCatchupDigest(
  keeperName: string,
  sinceUnix: number,
): Promise<KeeperCatchupDigest> {
  const resp = await fetch(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/digest?since_unix=${encodeURIComponent(String(sinceUnix))}`,
    { headers: jsonHeaders() },
  )
  if (!resp.ok) {
    throw new Error(`fetchKeeperCatchupDigest: HTTP ${resp.status} ${resp.statusText}`)
  }
  const data: unknown = await resp.json()
  const { parseKeeperCatchupDigest } = await import('./schemas/keeper-catchup-digest')
  const digest = parseKeeperCatchupDigest(data)
  if (!digest) {
    throw new Error('fetchKeeperCatchupDigest: invalid digest payload')
  }
  return digest
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
  runtime_fsm_mermaid?: string
  compaction_submachine_mermaid?: string | null
  // Structured data for Cytoscape FSM rendering
  thompson_alpha?: number
  thompson_beta?: number
  tool_count?: number
  recovery_floor_count?: number
  runtime_models?: string[]
  last_provider_result?: string | null
  runtime_models_source?: string
  last_provider_result_source?: string
  memory_kind_usage?: MemoryKindUsageEntry[]
  /** RFC-0149 §3.1 — sibling field carrying the typed memory-bank
   *  read failure class (`yojson_parse_error | io_error | type_error
   *  | other`).  `null` means the bank was readable; a string label
   *  means the read failed and `memory_kind_usage` contains the
   *  empty-counts fallback rather than a real snapshot. */
  memory_kind_usage_error_class?: string | null
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
  const { parseKeeperTransitionsResponse } = await import('./schemas/keeper-transitions')
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
  const { parseKeeperCompositeSnapshot } = await import('./schemas/keeper-composite')
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
  const { parseFleetCompositeSnapshot } = await import('./schemas/keeper-composite')
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
