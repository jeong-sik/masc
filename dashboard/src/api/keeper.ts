// MASC Dashboard — Keeper messaging (operator-mediated queue, SSE streaming)

import { asString, isRecord } from '../components/common/normalize'
import {
  formatKeeperVisibleReply,
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
  KEEPER_LIFECYCLE_TIMEOUT_MS,
} from './core'
import { ensureDevToken, resetDevTokenBootstrap } from './dev-token'
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
    // Not JSON — fall through to the legacy substring fallback below.
  }
  // WORKAROUND: legacy server fallback for servers that predate the typed
  // `auth_error_code` 401 body. The substring shape comes from
  // `Auth_error.InvalidToken "Token mismatch"` rendered as
  // "[AuthError] Invalid token: Token mismatch". removal target: next release.
  const normalized = raw.toLowerCase()
  return normalized.includes('autherror')
    && normalized.includes('invalid token')
    && normalized.includes('token mismatch')
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
    const resp = await fetchWithTimeout(url, {
      method: 'POST',
      headers: jsonHeaders(),
      ...init,
    }, KEEPER_LIFECYCLE_TIMEOUT_MS)
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
    const resp = await fetchWithTimeout(url, {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify(body),
    }, DEFAULT_POST_TIMEOUT_MS)
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

export type BulkKeeperDirectiveAction = 'pause' | 'resume' | 'wakeup'

export interface BulkKeeperDirectiveResult {
  name: string
  ok: boolean
  error?: string
}

export interface BulkKeeperDirectiveResponse {
  ok: boolean
  action: BulkKeeperDirectiveAction
  requested: number
  succeeded: number
  results: BulkKeeperDirectiveResult[]
}

/**
 * Apply pause/resume/wakeup to N keepers in one request.
 * Backend collapses the per-keeper cache invalidate into a single batch
 * invalidate at the end, so dashboard rebuild cost is O(1) instead of
 * O(N). Returns a per-keeper result array for granular UI feedback.
 */
export async function bulkKeeperDirective(
  names: string[],
  action: BulkKeeperDirectiveAction,
): Promise<BulkKeeperDirectiveResponse> {
  const fallbackError = `Failed to ${action} ${names.length} keeper(s)`
  try {
    const resp = await fetchWithTimeout(
      '/api/v1/keepers_bulk/directive',
      {
        method: 'POST',
        headers: jsonHeaders(),
        body: JSON.stringify({ names, action }),
      },
      DEFAULT_POST_TIMEOUT_MS,
    )
    const payload = await safeJsonResponse<BulkKeeperDirectiveResponse>(
      resp,
      fallbackError,
    )
    if (resp.ok && isRecord(payload) && payload.ok === true) {
      return payload
    }
    return {
      ok: false,
      action,
      requested: names.length,
      succeeded: 0,
      results: names.map(name => ({ name, ok: false, error: fallbackError })),
    }
  } catch (err) {
    return {
      ok: false,
      action,
      requested: names.length,
      succeeded: 0,
      results: names.map(name => ({
        name,
        ok: false,
        error: err instanceof Error ? err.message : fallbackError,
      })),
    }
  }
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
  runtime_id: string | null
  status: string
  error: string | null
  exception_kind: string | null
}

export interface KeeperRuntimeTraceProviderAttemptsSummary {
  started_count: number
  finished_count: number
  terminal_status: string | null
  terminal_error: string | null
  terminal_exception_kind: string | null
  attempts: KeeperRuntimeTraceProviderAttempt[]
}

export interface KeeperRuntimeLensTurnClock {
  trace_id: string
  keeper_turn_id: number | null
  max_oas_turn_count: number | null
  terminal_event_present: boolean
  terminal_event: string | null
  manifest_total_rows: number
}

export interface KeeperRuntimeLensLifecycleAxis {
  turn_started_count: number
  phase_gate_decided_count: number
  pre_dispatch_blocked_count: number
  receipt_appended_count: number
  turn_finished_count: number
  terminal_status: string
}

export interface KeeperRuntimeLensProviderLaneAxis {
  resolved: boolean
  status: string | null
  resolved_lane: string | null
}

export interface KeeperRuntimeLensProviderAttemptAxis {
  started_count: number
  finished_count: number
  terminal_status: string | null
}

export interface KeeperRuntimeLensPayloadRoleAxis {
  counts: Record<string, number>
}

export interface KeeperRuntimeLensSourceClockAxis {
  counts: Record<string, number>
}

export interface KeeperRuntimeLensClaimScopeAxis {
  present: boolean
  source: string
  status: string
  result: string | null
  mode: string | null
  scoped: boolean | null
  active_goal_ids: string[]
  effective_goal_ids: string[]
  fallback_reason: string | null
  matched_goal_id: string | null
  excluded_count: number | null
  claimed_task_id: string | null
  claimed_goal_id: string | null
}

export interface KeeperRuntimeLensConfigDriftAxis {
  present: boolean
  status: string
  error: string | null
  has_live_override: boolean
  runtime_override: boolean
  override_fields: string[]
  default_runtime_id: string | null
  live_runtime_id: string | null
  active_config_root: string | null
  active_config_root_source: string | null
  default_manifest_path: string | null
}

export interface KeeperRuntimeLensContextAxis {
  context_injected_count: number
  context_compacted_event_count: number
  event_bus_correlated_count: number
  context_compact_started_count: number
  context_compacted_count: number
  checkpoint_loaded_count: number
  checkpoint_saved_count: number
  state_snapshot_sidecar_saved_count: number
  active_open_loop_count: number
  last_compaction: unknown
}

export interface KeeperRuntimeLensMemoryAxis extends KeeperRuntimeTraceMemorySummary {}

export interface KeeperRuntimeLensAxes {
  lifecycle: KeeperRuntimeLensLifecycleAxis
  provider_lane: KeeperRuntimeLensProviderLaneAxis
  provider_attempt: KeeperRuntimeLensProviderAttemptAxis
  payload_role: KeeperRuntimeLensPayloadRoleAxis
  source_clock: KeeperRuntimeLensSourceClockAxis
  claim_scope: KeeperRuntimeLensClaimScopeAxis
  config_drift: KeeperRuntimeLensConfigDriftAxis
  context: KeeperRuntimeLensContextAxis
  memory: KeeperRuntimeLensMemoryAxis
}

export interface KeeperRuntimeLensLaneEvent {
  event: string
  count: number
}

export interface KeeperRuntimeLensLane {
  lane: string
  label: string
  event_count: number
  terminal_status: string
  completeness: string
  gap_codes: string[]
  gap_badge: string | null
  events: KeeperRuntimeLensLaneEvent[]
}

export interface KeeperRuntimeLensSwimlanes {
  keeper: KeeperRuntimeLensLane
  masc_policy_runtime: KeeperRuntimeLensLane
  oas_agent: KeeperRuntimeLensLane
  provider: KeeperRuntimeLensLane
  tool_runtime: KeeperRuntimeLensLane
  memory_context: KeeperRuntimeLensLane
}

export interface KeeperRuntimeLensGap {
  code: string
  severity: string
  lane: string
  detail: string | null
}

export interface KeeperRuntimeLensClockEdgeLinks {
  receipt_path: string | null
  checkpoint_path: string | null
  tool_call_log_path: string | null
}

export interface KeeperRuntimeLensClockEdge {
  edge_id: string
  lane: string
  event: string
  status: string
  observed_at: string
  source_clock: string
  started_at: string | null
  finished_at: string | null
  trace_id: string
  keeper_turn_id: number | null
  oas_turn_count: number | null
  provider_attempt_id: string | null
  tool_batch_id: string | null
  checkpoint_id: string | null
  compaction_id: string | null
  event_bus_correlation_id: string | null
  event_bus_run_id: string | null
  event_bus_event_count: number | null
  event_bus_payload_kinds: string[]
  parent_event_id: string | null
  caused_by: string | null
  links: KeeperRuntimeLensClockEdgeLinks
}

export interface KeeperRuntimeLensClockGroup {
  group_type: string
  group_id: string
  edge_count: number
  edge_ids: string[]
  lanes: string[]
  events: string[]
  statuses: string[]
  first_observed_at: string | null
  last_observed_at: string | null
  closed: boolean
  terminal_events: string[]
  parent_event_ids: string[]
  caused_by: string[]
  event_bus_event_count: number
  event_bus_payload_kinds: string[]
}

export interface KeeperRuntimeLens {
  turn_clock: KeeperRuntimeLensTurnClock
  axes: KeeperRuntimeLensAxes
  swimlanes: KeeperRuntimeLensSwimlanes
  clock_edges: KeeperRuntimeLensClockEdge[]
  clock_groups: KeeperRuntimeLensClockGroup[]
  gaps: KeeperRuntimeLensGap[]
}

export interface KeeperRuntimeTraceLinkedArtifact {
  kind: string
  path: string
  present: boolean
  file_stat: Record<string, unknown> | null
}

export interface KeeperRuntimeTraceLinkedArtifacts {
  receipts: KeeperRuntimeTraceLinkedArtifact[]
  checkpoints: KeeperRuntimeTraceLinkedArtifact[]
  tool_call_logs: KeeperRuntimeTraceLinkedArtifact[]
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
  runtime_lens: KeeperRuntimeLens
  linked_artifacts: KeeperRuntimeTraceLinkedArtifacts
  manifest_rows: Record<string, unknown>[]
  receipts: Record<string, unknown>[]
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

function nullableBooleanField(raw: Record<string, unknown>, key: string): boolean | null {
  const value = raw[key]
  return typeof value === 'boolean' ? value : null
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

function recordListField(raw: Record<string, unknown>, key: string): Record<string, unknown>[] {
  const value = raw[key]
  if (!Array.isArray(value)) return []
  return value.filter(isRecord)
}

function parseRuntimeTraceLinkedArtifact(raw: unknown): KeeperRuntimeTraceLinkedArtifact {
  const obj = isRecord(raw) ? raw : {}
  return {
    kind: stringField(obj, 'kind'),
    path: stringField(obj, 'path'),
    present: obj.present === true,
    file_stat: isRecord(obj.file_stat) ? obj.file_stat : null,
  }
}

function parseRuntimeTraceLinkedArtifacts(raw: unknown): KeeperRuntimeTraceLinkedArtifacts {
  const obj = isRecord(raw) ? raw : {}
  const parseList = (key: string) => {
    const value = obj[key]
    return Array.isArray(value) ? value.map(parseRuntimeTraceLinkedArtifact) : []
  }
  return {
    receipts: parseList('receipts'),
    checkpoints: parseList('checkpoints'),
    tool_call_logs: parseList('tool_call_logs'),
  }
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
    runtime_id: nullableStringField(obj, 'runtime_id'),
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
    terminal_error: nullableStringField(obj, 'terminal_error'),
    terminal_exception_kind: nullableStringField(obj, 'terminal_exception_kind'),
    attempts,
  }
}

function parseRuntimeLensTurnClock(raw: unknown, fallbackTraceId: string): KeeperRuntimeLensTurnClock {
  const obj = isRecord(raw) ? raw : {}
  return {
    trace_id: stringField(obj, 'trace_id') || fallbackTraceId,
    keeper_turn_id: nullableNumberField(obj, 'keeper_turn_id'),
    max_oas_turn_count: nullableNumberField(obj, 'max_oas_turn_count'),
    terminal_event_present: obj.terminal_event_present === true,
    terminal_event: nullableStringField(obj, 'terminal_event'),
    manifest_total_rows: numberField(obj, 'manifest_total_rows'),
  }
}

function parseRuntimeLensLifecycleAxis(raw: unknown): KeeperRuntimeLensLifecycleAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    turn_started_count: numberField(obj, 'turn_started_count'),
    phase_gate_decided_count: numberField(obj, 'phase_gate_decided_count'),
    pre_dispatch_blocked_count: numberField(obj, 'pre_dispatch_blocked_count'),
    receipt_appended_count: numberField(obj, 'receipt_appended_count'),
    turn_finished_count: numberField(obj, 'turn_finished_count'),
    terminal_status: stringField(obj, 'terminal_status') || 'unknown',
  }
}

function parseRuntimeLensProviderLaneAxis(raw: unknown): KeeperRuntimeLensProviderLaneAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    resolved: obj.resolved === true,
    status: nullableStringField(obj, 'status'),
    resolved_lane: nullableStringField(obj, 'resolved_lane'),
  }
}

function parseRuntimeLensProviderAttemptAxis(raw: unknown): KeeperRuntimeLensProviderAttemptAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    started_count: numberField(obj, 'started_count'),
    finished_count: numberField(obj, 'finished_count'),
    terminal_status: nullableStringField(obj, 'terminal_status'),
  }
}

function parseRuntimeLensPayloadRoleAxis(raw: unknown): KeeperRuntimeLensPayloadRoleAxis {
  const obj = isRecord(raw) ? raw : {}
  const counts: Record<string, number> = {}
  if (isRecord(obj)) {
    for (const key of Object.keys(obj)) {
      const value = obj[key]
      if (typeof value === 'number') {
        counts[key] = value
      }
    }
  }
  return { counts }
}

function parseRuntimeLensSourceClockAxis(raw: unknown): KeeperRuntimeLensSourceClockAxis {
  const obj = isRecord(raw) ? raw : {}
  const counts: Record<string, number> = {}
  if (isRecord(obj)) {
    for (const key of Object.keys(obj)) {
      const value = obj[key]
      if (typeof value === 'number') {
        counts[key] = value
      }
    }
  }
  return { counts }
}

function parseRuntimeLensClaimScopeAxis(raw: unknown): KeeperRuntimeLensClaimScopeAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    present: obj.present === true,
    source: stringField(obj, 'source') || '(unknown source)',
    status: stringField(obj, 'status') || 'not_observed',
    result: nullableStringField(obj, 'result'),
    mode: nullableStringField(obj, 'mode'),
    scoped: nullableBooleanField(obj, 'scoped'),
    active_goal_ids: stringListField(obj, 'active_goal_ids'),
    effective_goal_ids: stringListField(obj, 'effective_goal_ids'),
    fallback_reason: nullableStringField(obj, 'fallback_reason'),
    matched_goal_id: nullableStringField(obj, 'matched_goal_id'),
    excluded_count: nullableNumberField(obj, 'excluded_count'),
    claimed_task_id: nullableStringField(obj, 'claimed_task_id'),
    claimed_goal_id: nullableStringField(obj, 'claimed_goal_id'),
  }
}

function parseRuntimeLensConfigDriftAxis(raw: unknown): KeeperRuntimeLensConfigDriftAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    present: obj.present === true,
    status: stringField(obj, 'status') || 'unknown',
    error: nullableStringField(obj, 'error'),
    has_live_override: obj.has_live_override === true,
    runtime_override: obj.runtime_override === true,
    override_fields: stringListField(obj, 'override_fields'),
    default_runtime_id: nullableStringField(obj, 'default_runtime_id'),
    live_runtime_id: nullableStringField(obj, 'live_runtime_id'),
    active_config_root: nullableStringField(obj, 'active_config_root'),
    active_config_root_source: nullableStringField(obj, 'active_config_root_source'),
    default_manifest_path: nullableStringField(obj, 'default_manifest_path'),
  }
}

function parseRuntimeLensContextAxis(raw: unknown): KeeperRuntimeLensContextAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    context_injected_count: numberField(obj, 'context_injected_count'),
    context_compacted_event_count: numberField(obj, 'context_compacted_event_count'),
    event_bus_correlated_count: numberField(obj, 'event_bus_correlated_count'),
    context_compact_started_count: numberField(obj, 'context_compact_started_count'),
    context_compacted_count: numberField(obj, 'context_compacted_count'),
    checkpoint_loaded_count: numberField(obj, 'checkpoint_loaded_count'),
    checkpoint_saved_count: numberField(obj, 'checkpoint_saved_count'),
    state_snapshot_sidecar_saved_count: numberField(obj, 'state_snapshot_sidecar_saved_count'),
    active_open_loop_count: numberField(obj, 'active_open_loop_count'),
    last_compaction: obj.last_compaction ?? null,
  }
}

function parseRuntimeLensAxes(raw: unknown): KeeperRuntimeLensAxes {
  const obj = isRecord(raw) ? raw : {}
  return {
    lifecycle: parseRuntimeLensLifecycleAxis(obj.lifecycle),
    provider_lane: parseRuntimeLensProviderLaneAxis(obj.provider_lane),
    provider_attempt: parseRuntimeLensProviderAttemptAxis(obj.provider_attempt),
    payload_role: parseRuntimeLensPayloadRoleAxis(obj.payload_role),
    source_clock: parseRuntimeLensSourceClockAxis(obj.source_clock),
    claim_scope: parseRuntimeLensClaimScopeAxis(obj.claim_scope),
    config_drift: parseRuntimeLensConfigDriftAxis(obj.config_drift),
    context: parseRuntimeLensContextAxis(obj.context),
    memory: parseRuntimeTraceMemory(obj.memory),
  }
}

function parseRuntimeLensLaneEvent(raw: unknown): KeeperRuntimeLensLaneEvent {
  const obj = isRecord(raw) ? raw : {}
  return {
    event: stringField(obj, 'event'),
    count: numberField(obj, 'count'),
  }
}

function parseRuntimeLensLane(raw: unknown, lane: string, label: string): KeeperRuntimeLensLane {
  const obj = isRecord(raw) ? raw : {}
  const events = Array.isArray(obj.events)
    ? obj.events.map(parseRuntimeLensLaneEvent).filter(event => event.event !== '')
    : []
  return {
    lane: stringField(obj, 'lane') || lane,
    label: stringField(obj, 'label') || label,
    event_count: numberField(obj, 'event_count'),
    terminal_status: stringField(obj, 'terminal_status') || 'unknown',
    completeness: stringField(obj, 'completeness') || 'unknown',
    gap_codes: stringListField(obj, 'gap_codes'),
    gap_badge: nullableStringField(obj, 'gap_badge'),
    events,
  }
}

function parseRuntimeLensSwimlanes(raw: unknown): KeeperRuntimeLensSwimlanes {
  const obj = isRecord(raw) ? raw : {}
  return {
    keeper: parseRuntimeLensLane(obj.keeper, 'keeper', 'Keeper'),
    masc_policy_runtime: parseRuntimeLensLane(obj.masc_policy_runtime, 'masc_policy_runtime', 'MASC Runtime'),
    oas_agent: parseRuntimeLensLane(obj.oas_agent, 'oas_agent', 'OAS'),
    provider: parseRuntimeLensLane(obj.provider, 'provider', 'Provider'),
    tool_runtime: parseRuntimeLensLane(obj.tool_runtime, 'tool_runtime', 'Tool Runtime'),
    memory_context: parseRuntimeLensLane(obj.memory_context, 'memory_context', 'Memory/Context'),
  }
}

function parseRuntimeLensGap(raw: unknown): KeeperRuntimeLensGap {
  const obj = isRecord(raw) ? raw : {}
  return {
    code: stringField(obj, 'code') || 'unknown_gap',
    severity: stringField(obj, 'severity') || '(unknown severity)',
    lane: stringField(obj, 'lane') || 'unknown',
    detail: nullableStringField(obj, 'detail'),
  }
}

function parseRuntimeLensClockEdgeLinks(raw: unknown): KeeperRuntimeLensClockEdgeLinks {
  const obj = isRecord(raw) ? raw : {}
  return {
    receipt_path: nullableStringField(obj, 'receipt_path'),
    checkpoint_path: nullableStringField(obj, 'checkpoint_path'),
    tool_call_log_path: nullableStringField(obj, 'tool_call_log_path'),
  }
}

function parseRuntimeLensClockEdge(raw: unknown): KeeperRuntimeLensClockEdge {
  const obj = isRecord(raw) ? raw : {}
  return {
    edge_id: stringField(obj, 'edge_id') || 'unknown_edge',
    lane: stringField(obj, 'lane') || 'unknown',
    event: stringField(obj, 'event') || 'unknown_event',
    status: stringField(obj, 'status') || 'unknown',
    observed_at: stringField(obj, 'observed_at'),
    source_clock: stringField(obj, 'source_clock') || 'unknown',
    started_at: nullableStringField(obj, 'started_at'),
    finished_at: nullableStringField(obj, 'finished_at'),
    trace_id: stringField(obj, 'trace_id'),
    keeper_turn_id: nullableNumberField(obj, 'keeper_turn_id'),
    oas_turn_count: nullableNumberField(obj, 'oas_turn_count'),
    provider_attempt_id: nullableStringField(obj, 'provider_attempt_id'),
    tool_batch_id: nullableStringField(obj, 'tool_batch_id'),
    checkpoint_id: nullableStringField(obj, 'checkpoint_id'),
    compaction_id: nullableStringField(obj, 'compaction_id'),
    event_bus_correlation_id: nullableStringField(obj, 'event_bus_correlation_id'),
    event_bus_run_id: nullableStringField(obj, 'event_bus_run_id'),
    event_bus_event_count: nullableNumberField(obj, 'event_bus_event_count'),
    event_bus_payload_kinds: stringListField(obj, 'event_bus_payload_kinds'),
    parent_event_id: nullableStringField(obj, 'parent_event_id'),
    caused_by: nullableStringField(obj, 'caused_by'),
    links: parseRuntimeLensClockEdgeLinks(obj.links),
  }
}

function parseRuntimeLensClockGroup(raw: unknown): KeeperRuntimeLensClockGroup {
  const obj = isRecord(raw) ? raw : {}
  return {
    group_type: stringField(obj, 'group_type') || 'unknown',
    group_id: stringField(obj, 'group_id') || 'unknown_group',
    edge_count: numberField(obj, 'edge_count'),
    edge_ids: stringListField(obj, 'edge_ids'),
    lanes: stringListField(obj, 'lanes'),
    events: stringListField(obj, 'events'),
    statuses: stringListField(obj, 'statuses'),
    first_observed_at: nullableStringField(obj, 'first_observed_at'),
    last_observed_at: nullableStringField(obj, 'last_observed_at'),
    closed: nullableBooleanField(obj, 'closed') ?? false,
    terminal_events: stringListField(obj, 'terminal_events'),
    parent_event_ids: stringListField(obj, 'parent_event_ids'),
    caused_by: stringListField(obj, 'caused_by'),
    event_bus_event_count: numberField(obj, 'event_bus_event_count'),
    event_bus_payload_kinds: stringListField(obj, 'event_bus_payload_kinds'),
  }
}

function parseRuntimeLens(raw: unknown, fallbackTraceId: string): KeeperRuntimeLens {
  const obj = isRecord(raw) ? raw : {}
  const gaps = Array.isArray(obj.gaps) ? obj.gaps.map(parseRuntimeLensGap) : []
  const clockEdges = Array.isArray(obj.clock_edges)
    ? obj.clock_edges.map(parseRuntimeLensClockEdge)
    : []
  const clockGroups = Array.isArray(obj.clock_groups)
    ? obj.clock_groups.map(parseRuntimeLensClockGroup)
    : []
  return {
    turn_clock: parseRuntimeLensTurnClock(obj.turn_clock, fallbackTraceId),
    axes: parseRuntimeLensAxes(obj.axes),
    swimlanes: parseRuntimeLensSwimlanes(obj.swimlanes),
    clock_edges: clockEdges,
    clock_groups: clockGroups,
    gaps,
  }
}

export function parseKeeperRuntimeTrace(raw: unknown): KeeperRuntimeTraceResponse {
  if (!isRecord(raw)) throw new Error('runtime trace response is not a record')
  const traceId = stringField(raw, 'trace_id')
  return {
    keeper: stringField(raw, 'keeper'),
    trace_id: traceId,
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
    runtime_lens: parseRuntimeLens(raw.runtime_lens, traceId),
    linked_artifacts: parseRuntimeTraceLinkedArtifacts(raw.linked_artifacts),
    manifest_rows: recordListField(raw, 'manifest_rows'),
    receipts: recordListField(raw, 'receipts'),
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
