// MASC Dashboard — Keeper messaging (operator-mediated queue, SSE streaming)

import { asNumber, asString, isRecord } from '../components/common/normalize'
import {
  formatKeeperVisibleReply,
  keeperTurnOutcomeSuppressesReply,
  normalizeKeeperConversationDetails,
} from '../keeper-message'
import type {
  KeeperConversationAttachment,
  KeeperConversationDetails,
  KeeperQueueReceiptFailureKind,
  KeeperUserInputBlock,
} from '../types'
import {
  currentDashboardActor,
  apiRequestErrorFromResponse,
  jsonHeaders,
  post,
  runOperatorAction,
  fetchControlPlane,
  fetchWithTimeout,
  fetchJsonWithTimeout,
  DEFAULT_GET_TIMEOUT_MS,
} from './core'
import { refreshDevTokenAfterAuthError } from './dev-token'
import { isKeeperChatReceiptId, parseKeeperQueueRevision } from '../lib/keeper-chat-receipt'
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
  KeeperTurnAttempt,
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
  KeeperCheckpointCurrentError,
  KeeperCheckpointHistoryError,
  KeeperCheckpointSummary,
  KeeperCheckpointInventory,
  BulkKeeperDirectiveAction,
  BulkKeeperDirectiveResult,
  BulkKeeperDirectiveResponse,
  BulkKeeperResumeTarget,
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
  | 'cancelling'
  | 'done'
  | 'error'
  | 'lost'
  | 'cancelled'
  | 'persistence_failed'

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
  status: 'cancelling' | 'cancelled'
  message?: string
}

const TERMINAL_QUEUED_KEEPER_MESSAGE_STATUSES = new Set<QueuedKeeperMessageStatus>([
  'done',
  'error',
  'lost',
  'cancelled',
  'persistence_failed',
])

function normalizeQueuedKeeperMessageStatus(value: unknown): QueuedKeeperMessageStatus {
  switch (asString(value, '').trim()) {
    case 'queued':
      return 'queued'
    case 'running':
      return 'running'
    case 'cancelling':
      return 'cancelling'
    case 'done':
      return 'done'
    case 'error':
      return 'error'
    case 'lost':
      return 'lost'
    case 'cancelled':
      return 'cancelled'
    case 'persistence_failed':
      return 'persistence_failed'
    default:
      throw new Error(`unsupported keeper message status: ${JSON.stringify(value)}`)
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
  const status = normalizeQueuedKeeperMessageStatus(record?.status)
  if (status !== 'cancelling' && status !== 'cancelled') {
    throw new Error(`keeper message cancel response has non-cancellation status: ${status}`)
  }
  return {
    requestId,
    status,
    message: asString(record?.message),
  }
}

export interface KeeperTurnInterruptResult {
  cancelled: boolean
  turn_id?: number
  reason?: string
}

export async function interruptKeeperTurn(
  keeperName: string,
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperTurnInterruptResult> {
  const path = '/api/v1/keepers/turn/interrupt'
  const resp = await fetchControlPlane(
    path,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({ name: keeperName.trim() }),
      signal: opts.signal,
    },
  )
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('POST', path, resp)
  }
  const data = (await resp.json()) as Record<string, unknown>
  return {
    cancelled: data.cancelled === true,
    turn_id: typeof data.turn_id === 'number' ? data.turn_id : undefined,
    reason: asString(data.reason),
  }
}

export function isTerminalQueuedKeeperMessage(result: QueuedKeeperMessageResult): boolean {
  return TERMINAL_QUEUED_KEEPER_MESSAGE_STATUSES.has(result.status)
}

// Server no longer enforces an external timeout for keeper_msg.
// Keeper turn/token/cost fields are observability data; lifecycle control is explicit.
// Client-side abort via AbortSignal is the recommended cancellation path.

export interface KeeperChatStreamEvent {
  type: string
  threadId?: string
  runId?: string
  messageId?: string
  role?: string
  delta?: string
  snapshot?: string
  message?: string
  code?: string
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
  const resp = await fetchControlPlane(
    path,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: '{}',
      signal: opts.signal,
    },
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

// A tool call the keeper is holding, as listed by the server registry. This is
// the re-hydration path for waits whose owning stream watcher is gone and the
// fallback when the REQUESTED event predates this view.
export interface KeeperToolApprovalRow {
  keeper: string
  tool_call_id: string
  tool: string
  args: string
  question: string
  asked_at: number | null
  timeout_sec: number | null
}

export async function fetchKeeperToolApprovals(
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperToolApprovalRow[]> {
  const path = '/api/v1/keepers/tool-approvals'
  const resp = await fetchControlPlane(path, { method: 'GET', signal: opts.signal })
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('GET', path, resp)
  }
  const data = (await resp.json()) as Record<string, unknown>
  const rows = Array.isArray(data.pending) ? data.pending : []
  return rows.map((row): KeeperToolApprovalRow => {
    const record = isRecord(row) ? row : {}
    return {
      keeper: asString(record.keeper) ?? '',
      tool_call_id: asString(record.tool_call_id) ?? '',
      tool: asString(record.tool) ?? '',
      args: asString(record.args) ?? '',
      question: asString(record.question) ?? '',
      asked_at: typeof record.asked_at === 'number' ? record.asked_at : null,
      timeout_sec: typeof record.timeout_sec === 'number' ? record.timeout_sec : null,
    }
  }).filter(row => row.keeper && row.tool_call_id)
}

// Answers a held tool call. `settled: false` on a 200 means the wait was
// already gone (timed out, or answered elsewhere) — the POST still succeeds,
// so the caller reads the flag rather than treating absence of a throw as
// "approved".
export async function answerKeeperToolApproval(
  keeperName: string,
  toolCallId: string,
  decision: 'approve' | 'deny',
  opts: { signal?: AbortSignal } = {},
): Promise<{ settled: boolean; decision: string }> {
  const path = '/api/v1/keepers/tool-approval'
  const resp = await fetchControlPlane(
    path,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({ name: keeperName.trim(), tool_call_id: toolCallId, decision }),
      signal: opts.signal,
    },
  )
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('POST', path, resp)
  }
  const data = (await resp.json()) as Record<string, unknown>
  return {
    settled: data.settled === true,
    decision: asString(data.decision) ?? decision,
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
  const streamPath = '/api/v1/keepers/chat/stream'
  const postStream = () => fetch(streamPath, {
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
    let requestError = await apiRequestErrorFromResponse('POST', streamPath, res)
    if (
      res.status === 401
      && await refreshDevTokenAfterAuthError(requestError.authErrorCode)
    ) {
      res = await postStream()
      if (!res.ok) {
        requestError = await apiRequestErrorFromResponse('POST', streamPath, res)
      }
    }
    if (!res.ok) {
      throw requestError
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

export type KeeperChatReceiptFailureKind = KeeperQueueReceiptFailureKind

export type KeeperChatReceiptState =
  | { kind: 'pending' }
  | { kind: 'inflight'; leaseId: string; startedAt: number }
  | {
      kind: 'recovery_required'
      leaseId: string
      startedAt: number
      dispatchable: false
    }
  | { kind: 'delivered'; completedAt: number; outcomeRef: string | null }
  | {
      kind: 'failed'
      failureKind: KeeperChatReceiptFailureKind
      detail: string
      completedAt: number
      outcomeRef: string | null
    }

export interface KeeperChatReceipt {
  keeperName: string
  receiptId: string
  revision: string
  state: KeeperChatReceiptState
}

export type KeeperChatRecoveryDecision =
  | { kind: 'requeue_unconfirmed' }
  | {
      kind: 'cancel_unconfirmed'
      detail: string
      outcomeRef: string | null
    }

export interface KeeperChatRecoveryResult {
  decision: KeeperChatRecoveryDecision['kind']
  receipt: KeeperChatReceipt
  audit: { recorded: true } | { recorded: false; error: string }
}

export interface KeeperChatPendingCancelResult {
  receipt: KeeperChatReceipt
  audit: { recorded: true } | { recorded: false; error: string }
}

export interface KeeperChatPendingAttachment {
  id: string
  type: KeeperConversationAttachment['type']
  name: string
  size: number
  mimeType: string
}

export type KeeperChatPendingSource =
  | { kind: 'dashboard'; threadId: string }
  | { kind: 'discord'; channelId: string; userId: string }
  | {
      kind: 'slack'
      channelId: string
      userId: string
      teamId: string | null
      threadTs: string | null
    }

export interface KeeperChatPendingInput {
  receipt: KeeperChatReceipt
  content: string
  source: KeeperChatPendingSource
  attachments: KeeperChatPendingAttachment[]
  userBlocks: KeeperUserInputBlock[]
  submittedAt: number
}

export interface KeeperChatPendingSnapshot {
  keeperName: string
  revision: string
  currentWork: { lane: string; startedAt: number } | null
  totalPending: number
  nextAfter: string | null
  pending: KeeperChatPendingInput[]
}

export interface KeeperChatPendingMutationResult {
  keeperName: string
  receiptId: string
  revision: string
  pendingIndex: number
  audit: { recorded: true } | { recorded: false; error: string }
}

export interface KeeperEventQueuePendingItem {
  queueIndex: number
  postId: string
  sourceRef: string
  sourceIncarnation: string
  urgency: 'immediate' | 'normal' | 'low'
  arrivedAt: number
  payloadKind: string
  /** Why a completion_authority_rejected stimulus exists. Only that kind
      carries it, and it is absent on a backend that predates the field —
      the projection deliberately does not emit raw payload content for the
      other kinds. */
  rejectionReason?: string
  rejectionTaskId?: string
  /** Cancellation of a Task this Keeper authored. `cancelledReason` is absent
      when the canceller gave none, which is a different fact from an empty
      one. Absent on a backend that predates the fields. */
  cancelledTaskId?: string
  cancelledBy?: string
  cancelledReason?: string
}

export interface KeeperEventQueuePendingSnapshot {
  keeperName: string
  revision: string
  totalPending: number
  nextAfter: string | null
  pending: KeeperEventQueuePendingItem[]
}

const KEEPER_CHAT_RECEIPT_FAILURE_KINDS = new Set<KeeperChatReceiptFailureKind>([
  'turn_failed',
  'no_visible_reply',
  'transcript_persist_failed',
  'connector_unavailable',
  'delivery_failed',
  'cancelled',
  'internal_error',
  'recovery_interrupted',
])

export function parseKeeperChatReceipt(value: unknown): KeeperChatReceipt {
  if (!isRecord(value) || value.schema !== 'keeper_chat_queue.receipt.v2') {
    throw new Error('Keeper chat receipt response has an unsupported schema')
  }
  const keeperName = asString(value.keeper_name, '').trim()
  const receiptId = asString(value.receipt_id, '').trim()
  const revision = parseKeeperQueueRevision(value.revision)
  const rawState = isRecord(value.state) ? value.state : null
  const kind = asString(rawState?.kind, '').trim()
  if (
    !keeperName
    || !isKeeperChatReceiptId(receiptId)
    || !rawState
    || revision === undefined
  ) {
    throw new Error('Keeper chat receipt response is missing identity or state')
  }
  let state: KeeperChatReceiptState
  const nullableString = (fieldName: string, fieldValue: unknown): string | null => {
    if (fieldValue === null || fieldValue === undefined) return null
    if (typeof fieldValue !== 'string') {
      throw new Error(`Keeper chat receipt ${fieldName} must be a string or null`)
    }
    const trimmed = fieldValue.trim()
    if (!trimmed) {
      throw new Error(`Keeper chat receipt ${fieldName} must not be empty`)
    }
    return trimmed
  }
  switch (kind) {
    case 'pending':
      state = { kind }
      break
    case 'inflight': {
      const leaseId = asString(rawState.lease_id, '').trim()
      const startedAt = asNumber(rawState.started_at)
      if (!leaseId || typeof startedAt !== 'number') {
        throw new Error('Keeper chat inflight receipt is missing lease metadata')
      }
      state = { kind, leaseId, startedAt }
      break
    }
    case 'recovery_required': {
      const leaseId = asString(rawState.lease_id, '').trim()
      const startedAt = asNumber(rawState.started_at)
      if (!leaseId || typeof startedAt !== 'number' || rawState.dispatchable !== false) {
        throw new Error('Keeper chat recovery-required receipt has invalid recovery evidence')
      }
      state = { kind, leaseId, startedAt, dispatchable: false }
      break
    }
    case 'delivered': {
      const completedAt = asNumber(rawState.completed_at)
      if (typeof completedAt !== 'number') {
        throw new Error('Keeper chat delivered receipt is missing completion time')
      }
      state = {
        kind,
        completedAt,
        outcomeRef: nullableString('outcome_ref', rawState.outcome_ref),
      }
      break
    }
    case 'failed': {
      const failureKind = asString(rawState.failure_kind, '') as KeeperChatReceiptFailureKind
      const detail = asString(rawState.detail, '').trim()
      const completedAt = asNumber(rawState.completed_at)
      if (!KEEPER_CHAT_RECEIPT_FAILURE_KINDS.has(failureKind) || !detail || typeof completedAt !== 'number') {
        throw new Error('Keeper chat failed receipt has invalid failure metadata')
      }
      state = {
        kind,
        failureKind,
        detail,
        completedAt,
        outcomeRef: nullableString('outcome_ref', rawState.outcome_ref),
      }
      break
    }
    default:
      throw new Error(`Keeper chat receipt has unknown state: ${kind || '<empty>'}`)
  }
  return { keeperName, receiptId, revision, state }
}

export async function fetchKeeperChatReceipt(
  keeperName: string,
  receiptId: string,
): Promise<KeeperChatReceipt> {
  const { response: resp, data } = await fetchJsonWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/receipts/${encodeURIComponent(receiptId)}`,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) {
    throw new Error(`fetchKeeperChatReceipt: HTTP ${resp.status} ${resp.statusText}`)
  }
  return parseKeeperChatReceipt(data)
}

function parsePendingAttachment(value: unknown): KeeperChatPendingAttachment {
  if (!isRecord(value)) {
    throw new Error('Keeper pending attachment must be an object')
  }
  const id = asString(value.id, '').trim()
  const type = asString(value.type, '').trim() === 'image' ? 'image' : 'file'
  const name = asString(value.name, '').trim()
  const size = asNumber(value.size)
  const mimeType = asString(value.mime_type, '').trim()
  if (
    !id
    || typeof size !== 'number'
    || !Number.isSafeInteger(size)
    || size < 0
  ) {
    throw new Error('Keeper pending attachment is invalid')
  }
  return { id, type, name, size, mimeType }
}

function parsePendingUserBlock(value: unknown): KeeperUserInputBlock {
  if (!isRecord(value)) {
    throw new Error('Keeper pending user block must be an object')
  }
  const type = asString(value.type, '').trim()
  if (type === 'text') {
    const text = asString(value.text, '')
    if (!text) throw new Error('Keeper pending text block is empty')
    return { type, text }
  }
  if (type !== 'image' && type !== 'document' && type !== 'audio') {
    throw new Error('Keeper pending user block has an unknown type')
  }
  const attachmentId = asString(value.attachment_id, '').trim()
  const name = asString(value.name, '').trim()
  const mimeType = asString(value.mime_type, '').trim()
  const size = asNumber(value.size) ?? 0
  if (
    !attachmentId
    || !Number.isSafeInteger(size)
    || size < 0
  ) {
    throw new Error('Keeper pending media block is invalid')
  }
  return { type, attachmentId, name, mimeType, size }
}

function parsePendingSource(value: unknown): KeeperChatPendingSource {
  if (!isRecord(value)) {
    throw new Error('Keeper pending source must be an object')
  }
  const kind = asString(value.kind, '').trim()
  const requiredString = (field: string): string => {
    const parsed = asString(value[field], '').trim()
    if (!parsed) throw new Error(`Keeper pending source ${field} is missing`)
    return parsed
  }
  const nullableString = (field: string): string | null => {
    const raw = value[field]
    if (raw === null) return null
    const parsed = asString(raw, '').trim()
    if (!parsed) throw new Error(`Keeper pending source ${field} is invalid`)
    return parsed
  }
  switch (kind) {
    case 'dashboard':
      return { kind, threadId: requiredString('thread_id') }
    case 'discord':
      return {
        kind,
        channelId: requiredString('channel_id'),
        userId: requiredString('user_id'),
      }
    case 'slack':
      return {
        kind,
        channelId: requiredString('channel_id'),
        userId: requiredString('user_id'),
        teamId: nullableString('team_id'),
        threadTs: nullableString('thread_ts'),
      }
    default:
      throw new Error(`Keeper pending source has unknown kind: ${kind || '<empty>'}`)
  }
}

export function parseKeeperChatPendingSnapshot(
  value: unknown,
): KeeperChatPendingSnapshot {
  if (
    !isRecord(value)
    || value.schema !== 'keeper_chat_queue.pending.v2'
    || value.ok !== true
  ) {
    throw new Error('Keeper pending response has an unsupported schema')
  }
  const keeperName = asString(value.keeper_name, '').trim()
  const revision = parseKeeperQueueRevision(value.revision)
  const totalPending = asNumber(value.total_pending)
  const nextAfter = value.next_after === null
    ? null
    : parseKeeperQueueRevision(value.next_after)
  if (
    !keeperName
    || revision === undefined
    || typeof totalPending !== 'number'
    || !Number.isSafeInteger(totalPending)
    || totalPending < 0
    || nextAfter === undefined
    || !Array.isArray(value.pending)
  ) {
    throw new Error('Keeper pending response is missing identity or entries')
  }
  const currentWork = (() => {
    if (value.current_work === null) return null
    if (!isRecord(value.current_work)) {
      throw new Error('Keeper pending current work must be an object or null')
    }
    const lane = asString(value.current_work.lane, '').trim()
    const startedAt = asNumber(value.current_work.started_at)
    if (
      !lane
      || typeof startedAt !== 'number'
      || !Number.isFinite(startedAt)
      || startedAt < 0
    ) {
      throw new Error('Keeper pending current work is invalid')
    }
    return { lane, startedAt }
  })()
  const pending = value.pending.map((raw): KeeperChatPendingInput => {
    if (!isRecord(raw)) {
      throw new Error('Keeper pending entry must be an object')
    }
    const receipt = parseKeeperChatReceipt(raw.receipt)
    const content = asString(raw.content, '')
    const source = parsePendingSource(raw.source)
    const submittedAt = asNumber(raw.submitted_at)
    if (
      receipt.keeperName !== keeperName
      || receipt.revision !== revision
      || receipt.state.kind !== 'pending'
      || typeof submittedAt !== 'number'
      || !Number.isFinite(submittedAt)
      || submittedAt < 0
      || !Array.isArray(raw.attachments)
      || !Array.isArray(raw.user_blocks)
    ) {
      throw new Error('Keeper pending entry has invalid identity or state')
    }
    const attachments = raw.attachments.map(parsePendingAttachment)
    const userBlocks = raw.user_blocks.map(parsePendingUserBlock)
    if (!content.trim() && attachments.length === 0) {
      throw new Error('Keeper pending entry has no input payload')
    }
    return { receipt, content, source, attachments, userBlocks, submittedAt }
  })
  if (pending.length > totalPending) {
    throw new Error('Keeper pending page exceeds its total count')
  }
  return {
    keeperName,
    revision,
    currentWork,
    totalPending,
    nextAfter,
    pending,
  }
}

async function fetchKeeperChatPendingPage(
  keeperName: string,
  after: string | null,
): Promise<KeeperChatPendingSnapshot> {
  const baseUrl = `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/pending`
  const url = `${baseUrl}?limit=100${after === null ? '' : `&after=${encodeURIComponent(after)}`}`
  const { response, data } = await fetchJsonWithTimeout(
    url,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!response.ok) {
    throw await apiRequestErrorFromResponse(
      'GET',
      url,
      response,
    )
  }
  const snapshot = parseKeeperChatPendingSnapshot(data)
  if (snapshot.keeperName !== keeperName) {
    throw new Error('fetchKeeperChatPending: response identity mismatch')
  }
  return snapshot
}

export async function fetchKeeperChatPending(
  keeperName: string,
): Promise<KeeperChatPendingSnapshot> {
  const pending: KeeperChatPendingInput[] = []
  const seenCursors = new Set<string>()
  let expectedRevision: string | null = null
  let currentWork: KeeperChatPendingSnapshot['currentWork'] = null
  let totalPending = 0
  let after: string | null = null
  do {
    const page = await fetchKeeperChatPendingPage(keeperName, after)
    if (expectedRevision === null) {
      expectedRevision = page.revision
      currentWork = page.currentWork
      totalPending = page.totalPending
    } else if (
      page.revision !== expectedRevision
      || page.totalPending !== totalPending
    ) {
      throw new Error('fetchKeeperChatPending: queue changed during pagination')
    }
    pending.push(...page.pending)
    after = page.nextAfter
    if (after !== null) {
      if (seenCursors.has(after)) {
        throw new Error('fetchKeeperChatPending: repeated page cursor')
      }
      seenCursors.add(after)
    }
  } while (after !== null)
  if (expectedRevision === null || pending.length !== totalPending) {
    throw new Error('fetchKeeperChatPending: incomplete queue snapshot')
  }
  return {
    keeperName,
    revision: expectedRevision,
    currentWork,
    totalPending,
    nextAfter: null,
    pending,
  }
}

export function parseKeeperEventQueuePendingSnapshot(
  value: unknown,
): KeeperEventQueuePendingSnapshot {
  if (
    !isRecord(value)
    || value.schema !== 'keeper_event_queue.pending.v2'
    || value.ok !== true
  ) {
    throw new Error('Keeper event pending response has an unsupported schema')
  }
  const keeperName = asString(value.keeper_name, '').trim()
  const revision = parseKeeperQueueRevision(value.revision)
  const totalPending = asNumber(value.total_pending)
  const nextAfter = value.next_after === null
    ? null
    : parseKeeperQueueRevision(value.next_after)
  if (
    !keeperName
    || revision === undefined
    || typeof totalPending !== 'number'
    || !Number.isSafeInteger(totalPending)
    || totalPending < 0
    || nextAfter === undefined
    || !Array.isArray(value.pending)
  ) {
    throw new Error('Keeper event pending response is missing identity or entries')
  }
  const pending = value.pending.map((raw): KeeperEventQueuePendingItem => {
    if (!isRecord(raw)) {
      throw new Error('Keeper event pending entry must be an object')
    }
    const queueIndex = asNumber(raw.queue_index)
    const postId = asString(raw.post_id, '').trim()
    const sourceRef = asString(raw.source_ref, '').trim()
    const sourceIncarnation = parseKeeperQueueRevision(raw.source_incarnation)
    const urgency = asString(raw.urgency, '').trim()
    const arrivedAt = asNumber(raw.arrived_at_unix)
    const payloadKind = asString(raw.payload_kind, '').trim()
    if (
      typeof queueIndex !== 'number'
      || !Number.isSafeInteger(queueIndex)
      || queueIndex < 0
      || !postId
      || !/^[0-9a-f]{64}$/.test(sourceRef)
      || sourceIncarnation === undefined
      || !['immediate', 'normal', 'low'].includes(urgency)
      || typeof arrivedAt !== 'number'
      || !Number.isFinite(arrivedAt)
      || arrivedAt < 0
      || !payloadKind
    ) {
      throw new Error('Keeper event pending entry has invalid source identity')
    }
    return {
      queueIndex,
      postId,
      sourceRef,
      sourceIncarnation,
      urgency: urgency as KeeperEventQueuePendingItem['urgency'],
      arrivedAt,
      payloadKind,
      ...(typeof raw.rejection_reason === 'string' && raw.rejection_reason.trim()
        ? { rejectionReason: raw.rejection_reason.trim() }
        : {}),
      ...(typeof raw.rejection_task_id === 'string' && raw.rejection_task_id.trim()
        ? { rejectionTaskId: raw.rejection_task_id.trim() }
        : {}),
      ...(typeof raw.cancelled_task_id === 'string' && raw.cancelled_task_id.trim()
        ? { cancelledTaskId: raw.cancelled_task_id.trim() }
        : {}),
      ...(typeof raw.cancelled_by === 'string' && raw.cancelled_by.trim()
        ? { cancelledBy: raw.cancelled_by.trim() }
        : {}),
      ...(typeof raw.cancelled_reason === 'string' && raw.cancelled_reason.trim()
        ? { cancelledReason: raw.cancelled_reason.trim() }
        : {}),
    }
  })
  if (pending.length > totalPending) {
    throw new Error('Keeper event pending page exceeds its total count')
  }
  return {
    keeperName,
    revision,
    totalPending,
    nextAfter,
    pending,
  }
}

async function fetchKeeperEventQueuePendingPage(
  keeperName: string,
  after: string | null,
): Promise<KeeperEventQueuePendingSnapshot> {
  const baseUrl = `/api/v1/keepers/${encodeURIComponent(keeperName)}/events/pending`
  const url = `${baseUrl}?limit=100${after === null ? '' : `&after=${encodeURIComponent(after)}`}`
  const { response, data } = await fetchJsonWithTimeout(
    url,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!response.ok) {
    throw await apiRequestErrorFromResponse('GET', url, response)
  }
  const snapshot = parseKeeperEventQueuePendingSnapshot(data)
  if (snapshot.keeperName !== keeperName) {
    throw new Error('fetchKeeperEventQueuePending: response identity mismatch')
  }
  return snapshot
}

export async function fetchKeeperEventQueuePending(
  keeperName: string,
): Promise<KeeperEventQueuePendingSnapshot> {
  const pending: KeeperEventQueuePendingItem[] = []
  const seenCursors = new Set<string>()
  let expectedRevision: string | null = null
  let totalPending = 0
  let after: string | null = null
  do {
    const page = await fetchKeeperEventQueuePendingPage(keeperName, after)
    if (expectedRevision === null) {
      expectedRevision = page.revision
      totalPending = page.totalPending
    } else if (
      page.revision !== expectedRevision
      || page.totalPending !== totalPending
    ) {
      throw new Error('fetchKeeperEventQueuePending: queue changed during pagination')
    }
    pending.push(...page.pending)
    after = page.nextAfter
    if (after !== null) {
      if (seenCursors.has(after)) {
        throw new Error('fetchKeeperEventQueuePending: repeated page cursor')
      }
      seenCursors.add(after)
    }
  } while (after !== null)
  if (expectedRevision === null || pending.length !== totalPending) {
    throw new Error('fetchKeeperEventQueuePending: incomplete queue snapshot')
  }
  return {
    keeperName,
    revision: expectedRevision,
    totalPending,
    nextAfter: null,
    pending,
  }
}

export async function cancelKeeperChatPendingReceipt(
  keeperName: string,
  receiptId: string,
): Promise<KeeperChatPendingCancelResult> {
  let raw: unknown
  try {
    raw = await post<unknown>(
      `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/receipts/${encodeURIComponent(receiptId)}/cancel`,
      {
        schema: 'keeper_chat_queue.pending_cancel.request.v1',
      },
    )
  } catch (error) {
    try {
      const receipt = await fetchKeeperChatReceipt(keeperName, receiptId)
      if (receipt.state.kind === 'failed' && receipt.state.failureKind === 'cancelled') {
        return {
          receipt,
          audit: {
            recorded: false,
            error: '취소 응답이 유실되어 audit 기록 여부를 확인할 수 없습니다.',
          },
        }
      }
    } catch {
      // Preserve the original mutation error when exact receipt recovery fails.
    }
    throw error
  }
  if (
    !isRecord(raw)
    || raw.schema !== 'keeper_chat_queue.pending_cancel.result.v1'
    || raw.ok !== true
    || !isRecord(raw.audit)
    || typeof raw.audit.recorded !== 'boolean'
  ) {
    throw new Error('cancelKeeperChatPendingReceipt: invalid response envelope')
  }
  const receipt = parseKeeperChatReceipt(raw.receipt)
  if (receipt.keeperName !== keeperName || receipt.receiptId !== receiptId) {
    throw new Error('cancelKeeperChatPendingReceipt: response identity mismatch')
  }
  if (receipt.state.kind !== 'failed' || receipt.state.failureKind !== 'cancelled') {
    throw new Error('cancelKeeperChatPendingReceipt: response is not cancelled')
  }
  const audit = raw.audit.recorded
    ? { recorded: true as const }
    : {
        recorded: false as const,
        error: asString(raw.audit.error, '').trim() || 'pending cancellation audit persistence failed',
      }
  return { receipt, audit }
}

async function mutateKeeperChatPendingReceipt(
  keeperName: string,
  receiptId: string,
  action: 'edit' | 'move-to-end',
  request: Record<string, unknown>,
): Promise<KeeperChatPendingMutationResult> {
  const raw = await post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/receipts/${encodeURIComponent(receiptId)}/${action}`,
    request,
  )
  if (
    !isRecord(raw)
    || raw.schema !== 'keeper_chat_queue.pending_mutation.result.v1'
    || raw.ok !== true
    || !isRecord(raw.audit)
    || typeof raw.audit.recorded !== 'boolean'
  ) {
    throw new Error(`mutateKeeperChatPendingReceipt(${action}): invalid response envelope`)
  }
  const responseKeeper = asString(raw.keeper_name, '').trim()
  const responseReceipt = asString(raw.receipt_id, '').trim()
  const revision = parseKeeperQueueRevision(raw.revision)
  const pendingIndex = asNumber(raw.pending_index)
  if (
    responseKeeper !== keeperName
    || responseReceipt !== receiptId
    || revision === undefined
    || typeof pendingIndex !== 'number'
    || !Number.isSafeInteger(pendingIndex)
    || pendingIndex < 0
  ) {
    throw new Error(`mutateKeeperChatPendingReceipt(${action}): response identity mismatch`)
  }
  const audit = raw.audit.recorded
    ? { recorded: true as const }
    : {
        recorded: false as const,
        error: asString(raw.audit.error, '').trim() || 'pending mutation audit persistence failed',
      }
  return {
    keeperName: responseKeeper,
    receiptId: responseReceipt,
    revision,
    pendingIndex,
    audit,
  }
}

export async function editKeeperChatPendingReceipt(
  keeperName: string,
  receiptId: string,
  expectedRevision: string,
  content: string,
): Promise<KeeperChatPendingMutationResult> {
  return mutateKeeperChatPendingReceipt(keeperName, receiptId, 'edit', {
    content,
    expected_revision: expectedRevision,
    schema: 'keeper_chat_queue.pending_edit.request.v1',
  })
}

export async function moveKeeperChatPendingReceiptToEnd(
  keeperName: string,
  receiptId: string,
  expectedRevision: string,
): Promise<KeeperChatPendingMutationResult> {
  return mutateKeeperChatPendingReceipt(keeperName, receiptId, 'move-to-end', {
    expected_revision: expectedRevision,
    schema: 'keeper_chat_queue.pending_move_to_end.request.v1',
  })
}

export type KeeperEventQueueOperatorAction =
  | { action: 'cancel'; sourceRef: string; sourceIncarnation: string; reason: string; operationId?: string }
  | { action: 'transfer'; sourceRef: string; sourceIncarnation: string; targetKeeper: string; operationId?: string }
  | { action: 'reprioritize'; sourceRef: string; sourceIncarnation: string; urgency: 'immediate' | 'normal' | 'low' }

export type KeeperEventQueueReplayableAction =
  | { action: 'cancel'; sourceRef: string; sourceIncarnation: string; reason: string; operationId: string }
  | { action: 'transfer'; sourceRef: string; sourceIncarnation: string; targetKeeper: string; operationId: string }

type PreparedKeeperEventQueueOperatorAction =
  | KeeperEventQueueReplayableAction
  | Extract<KeeperEventQueueOperatorAction, { action: 'reprioritize' }>

export class KeeperEventQueueOperationError extends Error {
  readonly operation: KeeperEventQueueReplayableAction
  readonly commitState: 'committed' | 'unknown'

  constructor(
    message: string,
    operation: KeeperEventQueueReplayableAction,
    commitState: 'committed' | 'unknown',
  ) {
    super(message)
    this.name = 'KeeperEventQueueOperationError'
    this.operation = operation
    this.commitState = commitState
  }
}

function prepareKeeperEventQueueOperatorAction(
  operation: KeeperEventQueueOperatorAction,
): PreparedKeeperEventQueueOperatorAction {
  switch (operation.action) {
    case 'cancel':
    case 'transfer':
      return {
        ...operation,
        operationId: operation.operationId ?? crypto.randomUUID(),
      }
    case 'reprioritize':
      return operation
  }
}

function keeperEventQueueOperationError(
  message: string,
  operation: PreparedKeeperEventQueueOperatorAction,
  commitState: 'committed' | 'unknown',
): Error {
  return operation.action === 'reprioritize'
    ? new Error(message)
    : new KeeperEventQueueOperationError(message, operation, commitState)
}

export async function operateKeeperEventQueue(
  keeperName: string,
  operation: KeeperEventQueueOperatorAction,
): Promise<void> {
  const prepared = prepareKeeperEventQueueOperatorAction(operation)
  const common = {
    schema: 'keeper_event_queue.operator.request.v2',
    action: prepared.action,
    source_incarnation: prepared.sourceIncarnation,
    source_ref: prepared.sourceRef,
  }
  const request = prepared.action === 'cancel'
    ? {
        ...common,
        operator_operation_id: prepared.operationId,
        reason: prepared.reason,
      }
    : prepared.action === 'transfer'
      ? {
          ...common,
          operator_operation_id: prepared.operationId,
          target_keeper: prepared.targetKeeper,
        }
      : { ...common, urgency: prepared.urgency }
  let raw: unknown
  try {
    raw = await post<unknown>(
      `/api/v1/keepers/${encodeURIComponent(keeperName)}/events/operator`,
      request,
    )
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw keeperEventQueueOperationError(message, prepared, 'unknown')
  }
  if (
    !isRecord(raw)
    || raw.schema !== 'keeper_event_queue.operator.result.v1'
    || raw.ok !== true
    || asString(raw.keeper_name, '').trim() !== keeperName
    || !isRecord(raw.result)
  ) {
    throw keeperEventQueueOperationError(
      'operateKeeperEventQueue: invalid response envelope',
      prepared,
      'unknown',
    )
  }
  const status = asString(raw.result.status, '').trim()
  if (status === 'committed_followup_failed') {
    const transitionId = asString(raw.result.transition_id, '').trim()
    const stage = asString(raw.result.stage, '').trim()
    const detail = asString(raw.result.detail, '').trim()
    if (
      !transitionId
      || !['checkpoint', 'wal_compaction', 'projection', 'target_projection'].includes(stage)
      || !detail
    ) {
      throw keeperEventQueueOperationError(
        'operateKeeperEventQueue: invalid committed failure evidence',
        prepared,
        'unknown',
      )
    }
    throw keeperEventQueueOperationError(
      `Event queue mutation committed, but ${stage} follow-up failed (${transitionId}): ${detail}`,
      prepared,
      'committed',
    )
  }
  if (status === 'applied' || status === 'already_applied') {
    const transitionId = asString(raw.result.transition_id, '').trim()
    const revision = parseKeeperQueueRevision(raw.result.revision)
    if (!transitionId && revision === undefined) {
      throw keeperEventQueueOperationError(
        'operateKeeperEventQueue: applied result lacks durable identity',
        prepared,
        'unknown',
      )
    }
    return
  }
  throw keeperEventQueueOperationError(
    'operateKeeperEventQueue: unknown result status',
    prepared,
    'unknown',
  )
}

export async function resolveKeeperChatRecovery(
  keeperName: string,
  receiptId: string,
  expectedRevision: string,
  leaseId: string,
  decision: KeeperChatRecoveryDecision,
): Promise<KeeperChatRecoveryResult> {
  const decisionPayload = decision.kind === 'requeue_unconfirmed'
    ? { kind: decision.kind }
    : {
        kind: decision.kind,
        detail: decision.detail,
        outcome_ref: decision.outcomeRef,
      }
  const raw = await post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/receipts/${encodeURIComponent(receiptId)}/recovery`,
    {
      schema: 'keeper_chat_queue.recovery.request.v1',
      expected_revision: expectedRevision,
      lease_id: leaseId,
      decision: decisionPayload,
    },
  )
  if (
    !isRecord(raw)
    || raw.schema !== 'keeper_chat_queue.recovery.result.v1'
    || raw.ok !== true
    || raw.decision !== decision.kind
    || !isRecord(raw.audit)
    || typeof raw.audit.recorded !== 'boolean'
  ) {
    throw new Error('resolveKeeperChatRecovery: invalid response envelope')
  }
  const receipt = parseKeeperChatReceipt(raw.receipt)
  if (receipt.keeperName !== keeperName || receipt.receiptId !== receiptId) {
    throw new Error('resolveKeeperChatRecovery: response identity mismatch')
  }
  const audit = raw.audit.recorded
    ? { recorded: true as const }
    : {
        recorded: false as const,
        error: asString(raw.audit.error, '').trim() || 'recovery audit persistence failed',
      }
  return { decision: decision.kind, receipt, audit }
}

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
  const { response: resp, data } = await fetchJsonWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/chat/history`,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) {
    throw new Error(`fetchKeeperChatHistory: HTTP ${resp.status} ${resp.statusText}`)
  }
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

export interface KeeperCatchupJudgmentResponse {
  ok: true
  status: 'fusion_started'
  runId: string
  ownerKeeper: string
  fusionRoute: string
  digest: KeeperCatchupDigest
}

export async function runKeeperCatchupJudgment(
  keeperName: string,
  sinceUnix: number,
): Promise<KeeperCatchupJudgmentResponse> {
  const raw = await post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/catchup-judge`,
    { since_unix: sinceUnix },
  )
  if (!isRecord(raw) || raw.ok !== true) {
    throw new Error('runKeeperCatchupJudgment: invalid response envelope')
  }
  const runId = asString(raw.run_id)
  const ownerKeeper = asString(raw.owner_keeper)
  const fusionRoute = asString(raw.fusion_route)
  if (!runId || !ownerKeeper || !fusionRoute) {
    throw new Error('runKeeperCatchupJudgment: missing run metadata')
  }
  const { parseKeeperCatchupDigest } = await import('./schemas/keeper-catchup-digest')
  const digest = parseKeeperCatchupDigest(raw.digest)
  if (!digest) {
    throw new Error('runKeeperCatchupJudgment: invalid digest payload')
  }
  return {
    ok: true,
    status: 'fusion_started',
    runId,
    ownerKeeper,
    fusionRoute,
    digest,
  }
}

// --- Keeper observability API ---

export interface KeeperStateDiagramResponse {
  keeper: string
  current_phase: string
  mermaid: string
  runtime_fsm_mermaid?: string
  compaction_submachine_mermaid?: string | null
  // Structured data for Cytoscape FSM rendering
  tool_count?: number
  runtime_models?: string[]
  last_provider_result?: string | null
  runtime_models_source?: string
  last_provider_result_source?: string
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

// Detail views need enough recent lifecycle entries to avoid silently truncating
// active keepers, while compact surfaces can still pass an explicit lower limit.
export const KEEPER_LIFECYCLE_DEFAULT_LIMIT = 200

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
  limit = KEEPER_LIFECYCLE_DEFAULT_LIMIT,
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
