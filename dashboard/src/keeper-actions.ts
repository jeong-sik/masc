import { keeperStreamContract } from './keeper-stream-contract'
import {
  newKeeperChatOperationId,
  operationDeliveryProvenance,
  sameDeliveryProvenance,
} from './keeper-delivery-provenance'
import { callMcpTool } from './api/mcp'
import { runOperatorAction } from './api/core'
import {
  cancelKeeperChatOperation,
  fetchKeeperChatOperation,
  fetchKeeperChatHistory,
  fetchKeeperToolApprovals,
  interruptKeeperTurn as apiInterruptKeeperTurn,
  streamKeeperMessage,
} from './api/keeper'
import type { KeeperStreamSurfaceContext } from './api/keeper'
import { answerKeeperToolApproval } from './api/keeper'
import { fetchKeeperToolCalls } from './api/dashboard'
import {
  markToolCallOutputsHydrated,
  markToolCallOutputsHydrating,
  markToolCallOutputsHydrationFailed,
  recordToolCallOutputs,
} from './tool-call-output-store'
import { asString, isRecord } from './components/common/normalize'
import { invalidateDashboardCache, refreshDashboard } from './store'
import { isAbortError } from './lib/async-state'
import type {
  ChatBlock,
  KeeperConversationAttachment,
  KeeperConversationDelivery,
  KeeperConversationEntry,
  KeeperDiagnostic,
  KeeperStatusDetail,
  KeeperUserInputBlock,
} from './types'
import {
  activeKeeperName,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperStreamLastEventAt,
  keeperThreads,
  keeperToolApprovals,
  activeStreamEntryId,
  activeStreamRequestId,
  appendThreadEntry,
  attachKeeperAudioClip,
  chatHistoryEntriesFromRest,
  clearActiveStream,
  finalizeAssistantEntry,
  mergeServerHistoryEntries,
  normalizeKeeperProbeResult,
  normalizeKeeperRecoverResult,
  normalizeStatusDetail,
  removeThreadEntries,
  liveSendOwnsRequest,
  markLiveSendRequestAccepted,
  releaseLiveSendRequest,
  setActiveStream,
  setRecordValue,
  setStatusDetail,
  settleKeeperToolApproval,
  updateKeeperToolApproval,
  upsertKeeperToolApproval,
} from './keeper-state'
import {
  abortKeeperThreadMessage,
  applyKeeperStreamEvent,
  flushPendingKeeperStreamDeltas,
} from './keeper-stream'
import {
  KEEPER_HISTORY_TAIL_MESSAGES,
} from './config/constants'
import {
  hasTrackedKeeperChatOperation,
  trackedKeeperChatOperationsForKeeper,
  trackedKeeperChatAssistantDraftFromEntry,
  removeTrackedKeeperChatOperation,
  type TrackedKeeperChatOperation,
  updateTrackedKeeperChatAssistantDraft,
  upsertTrackedKeeperChatOperation,
} from './keeper-chat-operations-local'

type KeeperInterjectActionKind = 'send' | 'approve' | 'pause' | 'drain'

const TOOL_ONLY_EMPTY_REPLY_TEXT = 'Tool-only turn ended without a final reply.'
const EMPTY_VISIBLE_REPLY_TEXT =
  'Keeper가 thinking만 반환하고 표시할 답변을 만들지 못했습니다. 다시 보내주세요.'
type KeeperThreadCancelOutcome = 'cancelling' | 'cancelled'

const pendingKeeperThreadCancels = new Map<
  string,
  Promise<KeeperThreadCancelOutcome | null>
>()
const KEEPER_STREAM_SIGNAL_THROTTLE_MS = 1_000
const keeperStreamSignalWrites = new Map<string, number>()

interface KeeperInterjectCommand {
  readonly kind: KeeperInterjectActionKind
  readonly keeperName: string
  readonly message?: string
  /** Wire shape of `surface_context` on /api/v1/keepers/chat/stream; rendered
   *  into the keeper prompt by keeper_turn.surface_context_fields. */
  readonly surfaceContext?: KeeperStreamSurfaceContext
}

async function refreshDashboardState(): Promise<void> {
  invalidateDashboardCache()
  try {
    await refreshDashboard({ force: true })
  } catch (err) {
    console.warn(
      '[keeper-runtime] dashboard refresh failed',
      err instanceof Error ? err.message : err,
    )
  }
}

function keeperThreadCancelFailureMessage(keeperName: string, requestId: string, err: unknown): string {
  const cause = err instanceof Error ? err.message : String(err)
  return `Keeper request cancel failed for ${keeperName} (${requestId}): ${cause}`
}

export function _resetCancelledKeeperThreadRequestsForTests(): void {
  pendingKeeperThreadCancels.clear()
  keeperStreamSignalWrites.clear()
}

function releaseKeeperThreadCancelTracking(requestId: string): void {
  pendingKeeperThreadCancels.delete(requestId)
}

function markKeeperStreamSignal(keeperName: string, opts: { force?: boolean } = {}): void {
  const name = keeperName.trim()
  if (!name) return
  const now = Date.now()
  const previous = keeperStreamSignalWrites.get(name)
  if (
    !opts.force
    && previous !== undefined
    && now >= previous
    && now - previous < KEEPER_STREAM_SIGNAL_THROTTLE_MS
  ) {
    return
  }
  keeperStreamSignalWrites.set(name, now)
  setRecordValue(keeperStreamLastEventAt, name, now)
}

function clearKeeperStreamSignal(keeperName: string): void {
  const name = keeperName.trim()
  if (!name) return
  keeperStreamSignalWrites.delete(name)
  setRecordValue(keeperStreamLastEventAt, name, null)
}

export function cancelKeeperThreadRequest(
  keeperName: string,
  requestId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperThreadCancelOutcome | null> {
  const name = keeperName.trim()
  const id = requestId.trim()
  if (!name || !id) return Promise.resolve(null)
  const existing = pendingKeeperThreadCancels.get(id)
  if (existing) return existing
  const promise = (opts.signal
    ? cancelKeeperChatOperation(name, id, { signal: opts.signal })
    : cancelKeeperChatOperation(name, id))
    .then(result => {
      if (result.state.kind === 'cancelled') {
        removeTrackedKeeperChatOperation(id)
        releaseLiveSendRequest(id)
      }
      setRecordValue(keeperActionErrors, name, null)
      return 'cancelled' as const
    })
    .catch((err) => {
      const message = keeperThreadCancelFailureMessage(name, id, err)
      console.warn('[keeper] server cancel failed', message)
      setRecordValue(keeperActionErrors, name, message)
      return null
    })
    .finally(() => {
      pendingKeeperThreadCancels.delete(id)
    })
  pendingKeeperThreadCancels.set(id, promise)
  return promise
}

export async function cancelActiveKeeperThreadMessage(name: string): Promise<boolean> {
  const keeperName = name.trim()
  if (!keeperName) return false
  const requestIdBeforeAbort = activeStreamRequestId(keeperName)
  const abortResult = abortKeeperThreadMessage(keeperName)
  const requestId = requestIdBeforeAbort ?? abortResult?.requestId ?? null
  const locallyAborted = Boolean(abortResult?.controllerAborted || abortResult?.entryId)
  if (requestId) {
    void cancelKeeperThreadRequest(keeperName, requestId)
  }
  if (!requestIdBeforeAbort && !requestId && !locallyAborted) {
    // Nothing was in flight; treat as a successful no-op.
    return true
  }
  return locallyAborted
}

export async function interruptKeeperTurn(keeperName: string): Promise<boolean> {
  const name = keeperName.trim()
  if (!name) return false
  await cancelActiveKeeperThreadMessage(name)
  try {
    const result = await apiInterruptKeeperTurn(name)
    setRecordValue(keeperActionErrors, name, null)
    return result.signalled
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.warn('[keeper] interrupt turn failed', { keeperName: name, message })
    setRecordValue(keeperActionErrors, name, message)
    throw err
  }
}

// --- Held tool approvals (task-343) ---

// Re-hydrates waits whose REQUESTED event this view never saw: the listing is
// public-read, so a dashboard opened after the gate fired still draws the
// card instead of discovering the wait only as a 180s timeout.
export async function hydrateKeeperToolApprovals(): Promise<void> {
  let rows
  try {
    rows = await fetchKeeperToolApprovals()
  } catch {
    // Listing is best-effort hydration; the REQUESTED stream event remains
    // the primary source. A failed poll must not surface as an error row.
    return
  }
  for (const row of rows) {
    // A row the stream already drew carries fresher askedAt semantics; only
    // fill gaps, never overwrite an in-flight answer with a re-hydration.
    if (keeperToolApprovals.value[row.keeper]?.[row.tool_call_id]) continue
    upsertKeeperToolApproval(row.keeper, {
      toolCallId: row.tool_call_id,
      toolName: row.tool,
      args: row.args,
      question: row.question,
      because: row.because,
      askedAtMs: row.asked_at !== null ? row.asked_at * 1000 : null,
      timeoutSec: row.timeout_sec,
      answering: false,
      answeredDecision: null,
      answeredOutcome: null,
      settled: false,
    })
  }
}

export async function answerHeldKeeperToolApproval(
  keeperName: string,
  toolCallId: string,
  decision: 'approve' | 'deny',
): Promise<boolean> {
  const existing = keeperToolApprovals.value[keeperName]?.[toolCallId]
  if (!existing || existing.settled) return false
  if (existing.answering) return false
  updateKeeperToolApproval(keeperName, toolCallId, approval => ({
    ...approval,
    answering: true,
    answeredDecision: decision,
  }))
  try {
    const result = await answerKeeperToolApproval(keeperName, toolCallId, decision)
    // settled=false (late answer) still retires the card: the call is gone,
    // and the row would otherwise promise an interaction that no longer
    // exists. The SETTLED stream event, when it comes, is a no-op drop.
    settleKeeperToolApproval(keeperName, toolCallId, result.decision)
    setRecordValue(keeperActionErrors, keeperName, null)
    return result.settled
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.warn('[keeper] tool approval answer failed', { keeperName, toolCallId, message })
    updateKeeperToolApproval(keeperName, toolCallId, approval => ({
      ...approval,
      answering: false,
      answeredDecision: null,
    }))
    setRecordValue(keeperActionErrors, keeperName, message)
    return false
  }
}

export function selectKeeper(name: string): void {
  activeKeeperName.value = name.trim()
}

export async function dispatchKeeperInterjectAction(command: KeeperInterjectCommand): Promise<void> {
  const keeperName = command.keeperName.trim()
  if (!keeperName) throw new Error('INTERJECT requires an active keeper.')

  if (command.kind === 'send') {
    const message = command.message?.trim() ?? ''
    if (!message) throw new Error('INTERJECT send requires a message.')
    await sendKeeperThreadMessage(keeperName, message, {
      surfaceContext: command.surfaceContext,
    })
    return
  }

  throw new Error(
    `INTERJECT ${command.kind} requires a keeper-scoped backend operator action before dispatch.`,
  )
}

export async function hydrateKeeperStatus(name: string, force = false): Promise<KeeperStatusDetail | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  if (!force && keeperStatusDetails.value[keeperName]) return keeperStatusDetails.value[keeperName]
  setRecordValue(keeperHydrating, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const text = await callMcpTool('masc_keeper_status', {
      name: keeperName,
      fast: true,
      include_context: false,
      include_metrics_overview: false,
      include_history_tail: false,
      tail_turns: 0,
      tail_messages: 0,
    })
    let parsed: unknown = null
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
    const { normalizeKeeperStatusPayloadDeliveryProvenance } = await import(
      './api/schemas/keeper-chat-delivery-provenance'
    )
    parsed = normalizeKeeperStatusPayloadDeliveryProvenance(parsed)
    const detail = normalizeStatusDetail(keeperName, text, parsed)
    setStatusDetail(keeperName, detail)
    return detail
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to inspect ${keeperName}`
    console.warn(`[keeper] hydration failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    return null
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

// Keepers whose persisted chat history was already merged this page
// lifetime. Hydration is once-per-keeper: live entries appended after
// the merge are the fresher copy, and re-merging mid-session would
// race the in-flight stream entries.
const hydratedChatKeepers = new Set<string>()

/** Test-only: reset the once-per-keeper hydration guard. */
export function _resetChatHydrationForTests(): void {
  hydratedChatKeepers.clear()
}

async function fetchAndMergeKeeperChatHistory(keeperName: string): Promise<void> {
  const history = await fetchKeeperChatHistory(keeperName)
  if (history.length > 0) {
    mergeServerHistoryEntries(keeperName, chatHistoryEntriesFromRest(keeperName, history))
  }
}

/** Merge the server-persisted chat transcript
 *  (`GET /api/v1/keepers/:name/chat/history`, backed by
 *  `.masc/keeper_chat/<name>.jsonl`) into the in-memory thread.
 *  Called on conversation-panel mount so the transcript survives full
 *  page reloads — the server file is the cross-connector SSOT
 *  (dashboard / Discord / Slack all append to it). */
export async function hydrateKeeperChatHistory(
  name: string,
  options: { force?: boolean } = {},
): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  if (!options.force && hydratedChatKeepers.has(keeperName)) return
  hydratedChatKeepers.add(keeperName)
  setRecordValue(keeperHydrating, keeperName, true)
  try {
    await fetchAndMergeKeeperChatHistory(keeperName)
    // Tool outputs are stored on a separate durable endpoint. Hydrate even
    // when chat history is empty so a keeper panel can still join recently
    // fetched tool rows from the rail/inspector.
    void hydrateKeeperToolOutputs(keeperName)
  } catch (err) {
    // Allow a later mount to retry instead of caching the failure.
    hydratedChatKeepers.delete(keeperName)
    const message = err instanceof Error ? err.message : `Failed to load chat history for ${keeperName}`
    console.warn(`[keeper] chat history hydration failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, `이전 대화 불러오기 실패: ${message}`)
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

// Match the visible chat history window. A keeper that calls many tools can
// easily have >100 tool rows inside the 200-row transcript; using the same
// horizon keeps every visible recent row eligible for output join.
const TOOL_OUTPUT_FETCH_LIMIT = KEEPER_HISTORY_TAIL_MESSAGES

function toolOutputCoveredSinceMs(entries: readonly { ts: number }[]): number {
  const oldestMs = entries.reduce((oldest, entry) => {
    const ms = entry.ts * 1000
    return Number.isFinite(ms) ? Math.min(oldest, ms) : oldest
  }, Number.POSITIVE_INFINITY)
  // The backend filters a global recent tool-call tail by keeper, so a short
  // response is not proof that no older matching keeper rows exist. Only the
  // timestamp span actually returned by this fetch is safe to mark covered.
  return Number.isFinite(oldestMs) ? oldestMs : Number.POSITIVE_INFINITY
}

/** Best-effort hydration of tool-call outputs into the shared store so the
 *  chat ToolCallBubble can join results onto transcript rows by tool_use_id.
 *  Failures are swallowed (logged): the transcript must render with or without
 *  tool outputs. */
export async function hydrateKeeperToolOutputs(keeperName: string): Promise<void> {
  const coveredThroughMs = markToolCallOutputsHydrating(keeperName)
  try {
    const response = await fetchKeeperToolCalls(keeperName, TOOL_OUTPUT_FETCH_LIMIT)
    recordToolCallOutputs(response.entries)
    markToolCallOutputsHydrated(
      keeperName,
      coveredThroughMs,
      toolOutputCoveredSinceMs(response.entries),
    )
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    markToolCallOutputsHydrationFailed(keeperName, message)
    console.warn(`[keeper] tool-call output hydration failed for ${keeperName}:`, message)
  }
}

// Trailing per-keeper debounce for keeper_chat_appended pushes so a
// burst of turns (queue drain, multi-connector traffic) coalesces into
// one history refetch instead of one round-trip per message.
const chatRefreshTimers = new Map<string, ReturnType<typeof setTimeout>>()
const CHAT_APPENDED_REFRESH_DELAY_MS = 400
const PENDING_KEEPER_CHAT_POLL_MS = 2_000
const QUEUED_KEEPER_REQUEST_LOST_MESSAGE =
  '서버 재시작으로 대기 중이던 요청을 찾을 수 없습니다. 메시지를 다시 보내주세요.'
const PENDING_KEEPER_CHAT_RESUME_FAILED_MESSAGE =
  '응답을 확인할 수 없어 메시지 복구를 중단했습니다. 다시 보내주세요.'
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function hasCanonicalOperationTurn(
  entries: readonly KeeperConversationEntry[],
  operationId: string,
): boolean {
  const expectedUser = operationDeliveryProvenance(operationId, 'accepted_user')
  const expectedAssistant = operationDeliveryProvenance(operationId, 'terminal_assistant')
  const hasUser = entries.some(entry => (
    entry.deliveryProvenance != null
    && sameDeliveryProvenance(entry.deliveryProvenance, expectedUser)
  ))
  const hasAssistant = entries.some(entry => (
    entry.deliveryProvenance != null
    && sameDeliveryProvenance(entry.deliveryProvenance, expectedAssistant)
  ))
  return hasUser && hasAssistant
}

async function reconcileStreamFailureFromServerHistory(
  keeperName: string,
  operationId: string,
  localUserId: string,
  localAssistantId: string,
): Promise<boolean> {
  const history = await fetchKeeperChatHistory(keeperName)
  const historyEntries = chatHistoryEntriesFromRest(keeperName, history)
  if (!hasCanonicalOperationTurn(historyEntries, operationId)) {
    return false
  }

  mergeServerHistoryEntries(keeperName, historyEntries)
  removeThreadEntries(keeperName, [localUserId, localAssistantId])
  return true
}

function operationUserEntryId(operationId: string): string {
  return `pending-user-${operationId}`
}

function operationAssistantEntryId(operationId: string): string {
  return `pending-assistant-${operationId}`
}

function isUnknownKeeperChatOperationError(err: unknown): boolean {
  const record = isRecord(err) ? err : null
  const method = asString(record?.method, '').trim().toUpperCase()
  const status = typeof record?.status === 'number' ? record.status : null
  const path = asString(record?.path, '').trim()
  const message = err instanceof Error ? err.message : ''
  if (method === 'GET' && status === 404 && path.includes('/chat/operations/')) return true
  return message.includes('/chat/operations/') && message.includes('unknown_operation')
}

function ensureTrackedOperationThreadEntries(request: TrackedKeeperChatOperation): string {
  const existing = keeperThreads.value[request.keeperName] ?? []
  const userId = operationUserEntryId(request.operationId)
  const assistantId = operationAssistantEntryId(request.operationId)
  const assistantDraft = request.assistantDraft
  if (!existing.some(entry => entry.id === userId)) {
    appendThreadEntry(request.keeperName, {
      id: userId,
      role: 'user',
      source: 'direct_user',
      label: 'You',
      text: request.message,
      timestamp: new Date(request.submittedAt).toISOString(),
      delivery: 'delivered',
      streamState: null,
      deliveryProvenance: operationDeliveryProvenance(request.operationId, 'accepted_user'),
      streamContract: keeperStreamContract('client_operation_store', 'client_placeholder', {
        requestId: request.operationId,
        reason: 'restored accepted operation from browser storage',
      }),
      attachments: request.attachments,
      details: null,
    })
  }
  if (!existing.some(entry => entry.id === assistantId)) {
    appendThreadEntry(request.keeperName, {
      id: assistantId,
      role: 'assistant',
      source: 'direct_assistant',
      label: request.keeperName,
      text: assistantDraft?.text ?? '',
      rawText: assistantDraft?.rawText ?? '',
      timestamp: assistantDraft?.timestamp ?? null,
      delivery: assistantDraft?.delivery ?? 'queued',
      streamState: assistantDraft ? assistantDraft.streamState : 'opening',
      deliveryProvenance: operationDeliveryProvenance(request.operationId, 'terminal_assistant'),
      streamContract: keeperStreamContract('client_operation_store', 'client_placeholder', {
        requestId: request.operationId,
        reason: 'awaiting durable operation terminal state',
      }),
      traceSteps: assistantDraft?.traceSteps,
      error: assistantDraft?.error ?? null,
      details: null,
    })
  }
  return assistantId
}

function persistTrackedOperationAssistantDraft(
  keeperName: string,
  requestId: string | null,
  assistantEntryId: string,
): void {
  if (!requestId) return
  const entry = (keeperThreads.value[keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return
  updateTrackedKeeperChatAssistantDraft(requestId, entry)
}

function withCurrentTrackedOperationAssistantDraft(
  request: TrackedKeeperChatOperation,
  assistantEntryId: string,
): TrackedKeeperChatOperation {
  const entry = (keeperThreads.value[request.keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return request
  const assistantDraft = trackedKeeperChatAssistantDraftFromEntry(entry)
  return assistantDraft ? { ...request, assistantDraft } : request
}

let localIdCounter = 0

const hydratingKeeperChatOperations = new Set<string>()
const sendingKeeperThreadMessages = new Set<string>()
const KEEPER_MESSAGE_CANCELLED_TEXT = '요청이 취소되었습니다.'

function keeperThreadMessageSendKey(
  keeperName: string,
  clientActionId: string | undefined,
): string | null {
  const actionId = clientActionId?.trim() ?? ''
  return actionId ? `${keeperName}\u0000${actionId}` : null
}

function keeperThreadMessageSendKeys(
  keeperName: string,
  clientActionIds: readonly (string | undefined)[],
): string[] {
  const keys = new Set<string>()
  for (const clientActionId of clientActionIds) {
    const key = keeperThreadMessageSendKey(keeperName, clientActionId)
    if (key) keys.add(key)
  }
  return Array.from(keys)
}

export function _resetKeeperThreadMessageSendGuardsForTests(): void {
  sendingKeeperThreadMessages.clear()
}

export function isKeeperThreadMessageSendInFlight(
  keeperName: string,
  clientActionId: string | undefined,
): boolean {
  const sendKey = keeperThreadMessageSendKey(keeperName, clientActionId)
  return sendKey ? sendingKeeperThreadMessages.has(sendKey) : false
}

async function hydrateTrackedKeeperChatOperation(request: TrackedKeeperChatOperation): Promise<void> {
  // A live in-session send stream still owns this request (e.g. the panel
  // remounted on an SPA route change while the reply was pending). Defer to
  // it rather than minting a duplicate pending entry + a second poll loop.
  // After a full page reload this map is empty, so cold-start resume runs.
  if (liveSendOwnsRequest(request.operationId)) return
  const key = `${request.keeperName}:${request.operationId}`
  if (hydratingKeeperChatOperations.has(key)) return
  hydratingKeeperChatOperations.add(key)
  const assistantId = ensureTrackedOperationThreadEntries(request)
  setRecordValue(keeperSending, request.keeperName, true)
  setRecordValue(keeperActionErrors, request.keeperName, null)
  setRecordValue(keeperStreamStartedAt, request.keeperName, request.submittedAt)
  markKeeperStreamSignal(request.keeperName, { force: true })
  try {
    for (;;) {
      const operation = await fetchKeeperChatOperation(
        request.keeperName,
        request.operationId,
      )
      markKeeperStreamSignal(request.keeperName)
      if (operation.state.kind === 'queued' || operation.state.kind === 'running') {
        await sleep(PENDING_KEEPER_CHAT_POLL_MS)
        continue
      }
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      const isCancelled = operation.state.kind === 'cancelled'
      const failure = operation.state.kind === 'failed' ? operation.state : null
      const interrupted =
        failure?.failureKind === 'Interrupted_by_restart'
      let errorMessage: string | null = null
      if (failure) {
        errorMessage = interrupted
          ? 'Interrupted'
          : `${failure.failureKind}: ${failure.detail}`
      }
      let userDelivery: KeeperConversationDelivery = 'delivered'
      if (isCancelled) userDelivery = 'cancelled'
      else if (failure) userDelivery = 'error'
      const assistantDelivery: KeeperConversationDelivery = userDelivery
      finalizeAssistantEntry(request.keeperName, operationUserEntryId(request.operationId), {
        delivery: userDelivery,
        error: errorMessage,
        streamContract: keeperStreamContract('client_operation_lookup', 'client_operation_terminal', {
          requestId: request.operationId,
          reason: errorMessage,
        }),
      })
      const assistantStillLocal = (keeperThreads.value[request.keeperName] ?? [])
        .some(entry => entry.id === assistantId)
      if (assistantStillLocal) {
        const terminalText = isCancelled ? 'Cancelled' : errorMessage ?? ''
        finalizeAssistantEntry(request.keeperName, assistantId, {
          text: terminalText,
          rawText: terminalText,
          delivery: assistantDelivery,
          streamState: null,
          timestamp: new Date().toISOString(),
          error: errorMessage,
          streamContract: keeperStreamContract('client_operation_lookup', 'client_operation_terminal', {
            requestId: request.operationId,
            reason: errorMessage,
          }),
        })
      }
      if (errorMessage) setRecordValue(keeperActionErrors, request.keeperName, errorMessage)
      removeTrackedKeeperChatOperation(request.operationId)
      return
    }
  } catch (err) {
    if (isUnknownKeeperChatOperationError(err)) {
      removeTrackedKeeperChatOperation(request.operationId)
      finalizeAssistantEntry(request.keeperName, operationUserEntryId(request.operationId), {
        delivery: 'error',
        error: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
          requestId: request.operationId,
          reason: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        }),
      })
      finalizeAssistantEntry(request.keeperName, assistantId, {
        text: '',
        rawText: '',
        delivery: 'error',
        streamState: null,
        timestamp: new Date().toISOString(),
        error: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
          requestId: request.operationId,
          reason: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        }),
      })
      setRecordValue(keeperActionErrors, request.keeperName, QUEUED_KEEPER_REQUEST_LOST_MESSAGE)
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      return
    }
    const detail = err instanceof Error ? err.message : `Failed to resume ${request.keeperName} chat request`
    const message = `${PENDING_KEEPER_CHAT_RESUME_FAILED_MESSAGE} (${detail})`
    removeTrackedKeeperChatOperation(request.operationId)
    finalizeAssistantEntry(request.keeperName, operationUserEntryId(request.operationId), {
      delivery: 'error',
      error: message,
      streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
        requestId: request.operationId,
        reason: message,
      }),
    })
    finalizeAssistantEntry(request.keeperName, assistantId, {
      text: '',
      rawText: '',
      delivery: 'error',
      streamState: null,
      timestamp: new Date().toISOString(),
      error: message,
      streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
        requestId: request.operationId,
        reason: message,
      }),
    })
    setRecordValue(keeperActionErrors, request.keeperName, message)
    await hydrateKeeperChatHistory(request.keeperName, { force: true })
  } finally {
    hydratingKeeperChatOperations.delete(key)
    if (!hasTrackedKeeperChatOperation(request.keeperName)) {
      setRecordValue(keeperSending, request.keeperName, false)
      setRecordValue(keeperStreamStartedAt, request.keeperName, null)
      clearKeeperStreamSignal(request.keeperName)
    }
  }
}

export async function hydrateTrackedKeeperChatOperations(name: string): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  await Promise.all(trackedKeeperChatOperationsForKeeper(keeperName).map(hydrateTrackedKeeperChatOperation))
}

async function handoffCancelledStreamToOperationHydration(
  request: TrackedKeeperChatOperation,
  localEntryIds: readonly string[],
): Promise<void> {
  removeThreadEntries(request.keeperName, localEntryIds)
  releaseLiveSendRequest(request.operationId)
  await hydrateTrackedKeeperChatOperation(request)
}

/** React to a server `keeper_chat_appended` push: re-merge the
 *  persisted transcript so messages arriving through other connectors
 *  (Discord, Slack, agent MCP), plus committed autonomous turns, appear
 *  without a page reload.
 *
 *  A keeper that is not in `hydratedChatKeepers` reaches the guard below
 *  for one of two reasons: (a) its panel was never opened — mount
 *  hydration fetches the full window on first open, so skipping is
 *  correct; (b) an earlier hydration FAILED and rolled the keeper back
 *  out of the set (see the catch in `hydrateKeeperChatHistory`). Case (b)
 *  leaves an OPEN panel blank and, before this branch, dropped every
 *  subsequent append until the panel remounted. When the un-hydrated
 *  keeper is the one the operator is viewing (`activeKeeperName`), we
 *  re-trigger hydration so a recovered server transcript converges into
 *  the panel instead of being dropped. `hydrateKeeperChatHistory` adds
 *  the keeper to `hydratedChatKeepers` before its fetch await, so a burst
 *  of appends collapses into the single in-flight fetch rather than
 *  fanning out one fetch per event.
 *
 *  If the event carries an RFC-0235 audio clip, we first try to attach
 *  it to the matching assistant bubble that is already streaming. A
 *  failed match still falls back to the history re-merge (the clip is
 *  persisted server-side too).
 *
 *  [blocks] is accepted so the live push path can carry server-parsed
 *  rich blocks; the current implementation refreshes history (which now
 *  persists blocks) so the dashboard's normalizeHistoryEntry path prefers
 *  them automatically. */
export function noteKeeperChatAppended(name: string, audio?: unknown, _blocks?: unknown): void {
  const keeperName = name.trim()
  if (!keeperName) return
  if (!hydratedChatKeepers.has(keeperName)) {
    if (keeperName === activeKeeperName.value.trim()) {
      void hydrateKeeperChatHistory(keeperName, { force: true })
    }
    return
  }
  // Try to attach an RFC-0235 audio clip to the streaming assistant bubble,
  // but always fall through to the history re-merge so the transcript stays
  // current even if the clip had no matching text or no content text was
  // generated.
  if (audio != null) {
    attachKeeperAudioClip(keeperName, audio)
  }
  const pending = chatRefreshTimers.get(keeperName)
  if (pending) clearTimeout(pending)
  chatRefreshTimers.set(keeperName, setTimeout(() => {
    chatRefreshTimers.delete(keeperName)
    void (async () => {
      await hydrateKeeperChatHistory(keeperName, { force: true })
    })()
  }, CHAT_APPENDED_REFRESH_DELAY_MS))
}

/** Re-hydrate the chat transcript for the keeper whose conversation panel
 *  is currently open (`activeKeeperName`). No-op when no panel is open.
 *
 *  Two callers:
 *   - The `keepers` route refresh plan calls this WITHOUT `force`, so the
 *     once-per-page `hydratedChatKeepers` guard makes it a no-op while the
 *     transcript is already loaded (route visits and the periodic refresh
 *     must not poll the history endpoint). It only fetches when a prior
 *     hydration failed and left the keeper un-hydrated.
 *   - The SSE reconnect path calls this WITH `force` to recover
 *     `keeper_chat_appended` events that fell outside the server replay
 *     buffer while the connection was down — those are unrecoverable
 *     through the live stream, so the open panel must re-fetch the window. */
export function refreshActiveKeeperChatHistory(options: { force?: boolean } = {}): void {
  const keeperName = activeKeeperName.value.trim()
  if (!keeperName) return
  void hydrateKeeperChatHistory(keeperName, options)
}

export async function loadFullKeeperHistory(name: string): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  setRecordValue(keeperHydrating, keeperName, true)
  try {
    const text = await callMcpTool('masc_keeper_status', {
      name: keeperName,
      fast: false,
      include_context: false,
      include_metrics_overview: false,
      include_history_tail: true,
      tail_turns: 0,
      tail_messages: KEEPER_HISTORY_TAIL_MESSAGES,
    })
    let parsed: unknown = null
    try {
      parsed = JSON.parse(text)
    } catch (err) {
      // P2 silent-failure fix: malformed status response previously
      // produced an empty detail UI indistinguishable from "no data
      // yet."  Logging surfaces the parse failure to DevTools while
      // normalizeStatusDetail still degrades gracefully (uses raw
      // text + null parsed).
      console.warn(
        `[keeper] masc_keeper_status response parse failed for ${keeperName}:`,
        err instanceof Error ? err.message : err,
      )
      parsed = null
    }
    const { normalizeKeeperStatusPayloadDeliveryProvenance } = await import(
      './api/schemas/keeper-chat-delivery-provenance'
    )
    parsed = normalizeKeeperStatusPayloadDeliveryProvenance(parsed)
    const detail = normalizeStatusDetail(keeperName, text, parsed)
    setStatusDetail(keeperName, detail)
  } catch (err) {
    console.warn(`[keeper] full history load failed for ${keeperName}`, err instanceof Error ? err.message : err)
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

function userInputMediaKindForAttachment(
  attachment: KeeperConversationAttachment,
): Exclude<KeeperUserInputBlock['type'], 'text'> {
  if (attachment.kind === 'url' || attachment.kind === 'file_id') return 'image'
  if (attachment.type === 'image') return 'image'
  if (attachment.mimeType.startsWith('audio/')) return 'audio'
  return 'document'
}

function attachmentToUserInputBlock(attachment: KeeperConversationAttachment): KeeperUserInputBlock {
  // A reference crosses as its native carrier (#33728): the server's parse
  // accepts exactly one of attachment_id / url / file_id per image block.
  if (attachment.kind === 'url') {
    return { type: 'image', url: attachment.url, ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}) }
  }
  if (attachment.kind === 'file_id') {
    return { type: 'image', fileId: attachment.fileId, ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}) }
  }
  return {
    type: userInputMediaKindForAttachment(attachment),
    attachmentId: attachment.id,
    name: attachment.name,
    mimeType: attachment.mimeType,
    size: attachment.size,
  }
}

function deriveUserBlocks(
  prompt: string,
  attachments: KeeperConversationAttachment[] | undefined,
): KeeperUserInputBlock[] | undefined {
  const blocks = attachments?.map(attachmentToUserInputBlock) ?? []
  const text = prompt.trim()
  if (text) blocks.push({ type: 'text', text })
  return blocks.length > 0 ? blocks : undefined
}

function fallbackMessageForUserBlocks(blocks: KeeperUserInputBlock[]): string {
  const text = blocks
    .filter((block): block is Extract<KeeperUserInputBlock, { type: 'text' }> => block.type === 'text')
    .map(block => block.text.trim())
    .filter(Boolean)
    .join('\n\n')
  if (text) return text

  const media = blocks.filter(block => block.type !== 'text')
  if (media.length === 0) return ''
  const names = media
    .slice(0, 3)
    .map(block => ('url' in block ? block.url : 'fileId' in block ? `file_id ${block.fileId}` : block.name).trim())
    .filter(Boolean)
    .join(', ')
  const suffix = media.length > 3 ? ` 외 ${media.length - 3}개` : ''
  return names
    ? `[첨부 ${media.length}개: ${names}${suffix}]`
    : `[첨부 ${media.length}개]`
}

export async function sendKeeperThreadMessage(
  name: string,
  prompt: string,
  options: {
    attachments?: KeeperConversationAttachment[]
    clientActionId?: string
    clientActionIds?: readonly string[]
    blocks?: ChatBlock[]
    userBlocks?: KeeperUserInputBlock[]
    surfaceContext?: KeeperStreamSurfaceContext
  } = {},
): Promise<void> {
  const keeperName = name.trim()
  const attachments =
    options.attachments && options.attachments.length > 0 ? options.attachments : undefined
  const userBlocks =
    options.userBlocks && options.userBlocks.length > 0
      ? options.userBlocks
      : deriveUserBlocks(prompt, attachments)
  const blocks = options.blocks && options.blocks.length > 0 ? options.blocks : undefined
  const message = prompt.trim() || fallbackMessageForUserBlocks(userBlocks ?? [])
  if (!keeperName || !message) return
  const sendKeys = keeperThreadMessageSendKeys(keeperName, [
    options.clientActionId,
    ...(options.clientActionIds ?? []),
  ])
  if (sendKeys.some(key => sendingKeeperThreadMessages.has(key))) return
  sendKeys.forEach(key => sendingKeeperThreadMessages.add(key))
  const localId = `local-${++localIdCounter}-${Date.now()}`
  const assistantId = `reply-${++localIdCounter}-${Date.now()}`
  const operationId = newKeeperChatOperationId()
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
    deliveryProvenance: operationDeliveryProvenance(operationId, 'accepted_user'),
    source: 'direct_user',
    label: 'You',
    text: message,
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: null,
    streamContract: keeperStreamContract('client_local_send', 'client_placeholder', {
      reason: 'local optimistic user row before server history confirmation',
    }),
    attachments,
    userBlocks,
    blocks,
    details: null,
  })
  appendThreadEntry(keeperName, {
    id: assistantId,
    role: 'assistant',
    deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_assistant'),
    source: 'direct_assistant',
    label: keeperName,
    text: '',
    rawText: '',
    timestamp: null,
    delivery: 'sending',
    streamState: 'opening',
    streamContract: keeperStreamContract('client_local_send', 'client_placeholder', {
      reason: 'local assistant placeholder before stream event',
    }),
    details: null,
  })
  setRecordValue(keeperSending, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  setRecordValue(keeperStreamStartedAt, keeperName, Date.now())
  const controller = new AbortController()
  setActiveStream(keeperName, operationId, assistantId, controller)
  let operationAccepted = false
  let toolCallEnded = false
  try {
    finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered' })

    const outcome = await streamKeeperMessage(keeperName, message, {
      operationId,
      signal: controller.signal,
      attachments,
      userBlocks,
      surfaceContext: options.surfaceContext,
      onEvent: event => {
        markKeeperStreamSignal(keeperName)
        if (
          event.type === 'CUSTOM'
          && event.name === 'KEEPER_CHAT_OPERATION_ACCEPTED'
        ) {
          const acceptedOperationId = event.value.operation_id.trim()
          if (!acceptedOperationId || acceptedOperationId !== operationId) {
            throw new Error('Keeper operation acceptance identity mismatch')
          }
          operationAccepted = true
          markLiveSendRequestAccepted(acceptedOperationId)
          upsertTrackedKeeperChatOperation({
            operationId: acceptedOperationId,
            keeperName,
            message,
            submittedAt: Date.now(),
            ...(attachments ? { attachments } : {}),
          })
        }
        const error = applyKeeperStreamEvent(
          keeperName,
          assistantId,
          event,
          { kind: 'operation', operationId },
        )
        if (error) {
          throw new Error(error)
        }
        persistTrackedOperationAssistantDraft(
          keeperName,
          operationAccepted ? operationId : null,
          assistantId,
        )
        if (event.type === 'TOOL_CALL_END') {
          toolCallEnded = true
        }
        if (event.type === 'CUSTOM' && event.name === 'KEEPER_TOOL_RESULT_READY') {
          void hydrateKeeperToolOutputs(keeperName)
        }
      },
    })

    flushPendingKeeperStreamDeltas(keeperName, assistantId)
    const finalEntry =
      (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId) ?? null
    const finalText = finalEntry?.text.trim() ?? ''

    if (!outcome.terminal) {
      if (operationAccepted) {
        removeThreadEntries(keeperName, [localId, assistantId])
        // Hand off to resume: release ownership FIRST so our own resume
        // call below is not blocked by the guard we just set.
        releaseLiveSendRequest(operationId)
        await hydrateTrackedKeeperChatOperation({
          operationId,
          keeperName,
          message,
          submittedAt: Date.now(),
          ...(attachments ? { attachments } : {}),
        })
        return
      }
      // The SSE connection closed without RUN_FINISHED / RUN_ERROR —
      // keep the partial text but mark the entry so the operator can
      // tell a cut stream from a completed reply.
      const cutMessage = '스트림이 종료 신호 없이 끊겼습니다. 응답이 불완전할 수 있습니다.'
      finalizeAssistantEntry(keeperName, assistantId, {
        text: finalText,
        delivery: 'interrupted',
        streamState: null,
        timestamp: new Date().toISOString(),
        error: cutMessage,
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          reason: cutMessage,
        }),
      })
      setRecordValue(keeperActionErrors, keeperName, cutMessage)
      if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
      return
    }

    const finalDelivery = 'delivered' as KeeperConversationDelivery
    const hasContinuationStatus = (
      finalEntry?.details?.turnOutcome === 'continuation_checkpoint'
      && finalEntry.blocks?.some(block => (
        block.t === 'status' && block.kind === 'continuation_checkpoint'
      )) === true
    )
    if (
      !finalText
      && !toolCallEnded
      && !hasContinuationStatus
    ) {
      finalizeAssistantEntry(keeperName, assistantId, {
        text: EMPTY_VISIBLE_REPLY_TEXT,
        rawText: finalEntry?.rawText || EMPTY_VISIBLE_REPLY_TEXT,
        delivery: 'error',
        streamState: null,
        timestamp: new Date().toISOString(),
        error: EMPTY_VISIBLE_REPLY_TEXT,
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          reason: EMPTY_VISIBLE_REPLY_TEXT,
        }),
      })
      setRecordValue(keeperActionErrors, keeperName, EMPTY_VISIBLE_REPLY_TEXT)
      if (operationAccepted) {
        removeTrackedKeeperChatOperation(operationId)
      }
      return
    }
    let emptyTerminalText = ''
    if (toolCallEnded && !hasContinuationStatus) {
      emptyTerminalText = TOOL_ONLY_EMPTY_REPLY_TEXT
    }

    finalizeAssistantEntry(keeperName, assistantId, {
      text: finalText || emptyTerminalText,
      delivery: finalDelivery,
      streamState: null,
      timestamp: new Date().toISOString(),
      error: null,
      streamContract: keeperStreamContract('sse_event', 'backend_terminal_event', {
        eventName: 'RUN_FINISHED',
      }),
    })
    if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
    if (operationAccepted) {
      removeTrackedKeeperChatOperation(operationId)
    }
  } catch (err) {
    flushPendingKeeperStreamDeltas(keeperName, assistantId)
    if (isAbortError(err)) {
      const durablePendingRequest = operationAccepted
        ? trackedKeeperChatOperationsForKeeper(keeperName)
          .find(candidate => candidate.operationId === operationId) ?? null
        : null
      const hasDurablePendingRequest = durablePendingRequest !== null
      const shouldAttemptServerCancel = Boolean(
        operationAccepted && (liveSendOwnsRequest(operationId) || hasDurablePendingRequest),
      )
      const serverCancelAlreadyFinalized = Boolean(
        operationAccepted
        && !liveSendOwnsRequest(operationId)
        && !hasDurablePendingRequest,
      )
      if (shouldAttemptServerCancel) {
        const pendingRequest = withCurrentTrackedOperationAssistantDraft(durablePendingRequest ?? {
          operationId,
          keeperName,
          message,
          submittedAt: Date.now(),
          ...(attachments ? { attachments } : {}),
        }, assistantId)
        upsertTrackedKeeperChatOperation(pendingRequest)
        void cancelKeeperThreadRequest(keeperName, operationId).then(outcome => {
          if (outcome === 'cancelling') {
            return handoffCancelledStreamToOperationHydration(
              pendingRequest,
              [localId, assistantId],
            )
          }
          return undefined
        })
      }
      finalizeAssistantEntry(keeperName, localId, {
        delivery: 'cancelled',
        error: null,
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          requestId: operationAccepted ? operationId : undefined,
          reason: KEEPER_MESSAGE_CANCELLED_TEXT,
        }),
      })
      finalizeAssistantEntry(keeperName, assistantId, {
        text: KEEPER_MESSAGE_CANCELLED_TEXT,
        rawText: KEEPER_MESSAGE_CANCELLED_TEXT,
        delivery: 'cancelled',
        streamState: null,
        error: null,
        timestamp: new Date().toISOString(),
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          requestId: operationAccepted ? operationId : undefined,
          reason: KEEPER_MESSAGE_CANCELLED_TEXT,
        }),
      })
      if (serverCancelAlreadyFinalized) setRecordValue(keeperActionErrors, keeperName, null)
      throw err
    }

    const errorMessage =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    finalizeAssistantEntry(keeperName, assistantId, {
      delivery: 'error' as KeeperConversationDelivery,
      streamState: null,
      error: errorMessage,
      timestamp: new Date().toISOString(),
      streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
        requestId: operationAccepted ? operationId : undefined,
        reason: errorMessage,
      }),
    })
    // The assistant placeholder is the single transcript owner of a stream
    // failure. Keep the optimistic user message as a delivered input row;
    // marking both rows as errors produced two identical red error cards for
    // one failed HTTP request.
    finalizeAssistantEntry(keeperName, localId, {
      delivery: 'delivered',
      error: null,
      streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
        requestId: operationAccepted ? operationId : undefined,
        reason: errorMessage,
      }),
    })
    try {
      const reconciled = await reconcileStreamFailureFromServerHistory(
        keeperName,
        operationId,
        localId,
        assistantId,
      )
      if (reconciled) {
        setRecordValue(keeperActionErrors, keeperName, null)
        return
      }
    } catch (reconcileErr) {
      console.warn(
        `[keeper] stream failure history reconciliation failed for ${keeperName}`,
        reconcileErr instanceof Error ? reconcileErr.message : reconcileErr,
      )
    }
    setRecordValue(keeperActionErrors, keeperName, errorMessage)
    throw err
  } finally {
    // Release cancellation bookkeeping on every accepted exit. The exact
    // operation ownership is released once by clearActiveStream below; the
    // non-terminal handoff released it early so its own resume was not blocked.
    if (operationAccepted) {
      releaseKeeperThreadCancelTracking(operationId)
    }
    sendKeys.forEach(key => sendingKeeperThreadMessages.delete(key))
    clearActiveStream(keeperName, operationId)
    if (activeStreamEntryId(keeperName) === null) {
      setRecordValue(keeperSending, keeperName, false)
      setRecordValue(keeperStreamStartedAt, keeperName, null)
      clearKeeperStreamSignal(keeperName)
    }
    // No refreshDashboardState() here: forcing a full dashboard
    // refetch after every chat message re-rendered every panel and was
    // the main "the screen keeps refreshing" complaint. Keeper status
    // updates arrive through the WS/SSE live path instead.
  }
}

export async function probeKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperProbing, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperProbeResult(response.result)
    const diagnostic = result?.diagnostic ?? null
    if (diagnostic) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return diagnostic
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to probe ${keeperName}`
    console.warn(`[keeper] probe failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperProbing, keeperName, false)
  }
}

export async function recoverKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperRecovering, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_recover',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperRecoverResult(response.result)
    const after = result?.after ?? null
    if (after) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic: after,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return after
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to recover ${keeperName}`
    console.warn(`[keeper] recovery failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperRecovering, keeperName, false)
  }
}
