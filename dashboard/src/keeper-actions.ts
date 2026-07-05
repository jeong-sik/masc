import { callMcpTool } from './api/mcp'
import { runOperatorAction } from './api/core'
import {
  cancelQueuedKeeperMessage,
  fetchKeeperChatHistory,
  fetchQueuedKeeperMessageResult,
  isTerminalQueuedKeeperMessage,
  queuedKeeperMessageError,
  queuedKeeperMessageToReply,
  streamKeeperMessage,
} from './api/keeper'
import { fetchKeeperToolCalls } from './api/dashboard'
import {
  markToolCallOutputsHydrated,
  markToolCallOutputsHydrating,
  markToolCallOutputsHydrationFailed,
  recordToolCallOutputs,
} from './tool-call-output-store'
import { asString, isRecord } from './components/common/normalize'
import { keeperTurnOutcomeSuppressesReply } from './keeper-message'
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
  activeStreamEntryId,
  activeStreamRequestId,
  appendThreadEntry,
  attachKeeperAudioClip,
  chatHistoryEntriesFromRest,
  clearActiveStream,
  clearActiveStreamRequestId,
  finalizeAssistantEntry,
  keeperClientObservedSseStreamContract,
  keeperStreamContract,
  releaseActiveStreamRequestId,
  mergeServerHistoryEntries,
  normalizeKeeperProbeResult,
  normalizeKeeperRecoverResult,
  normalizeStatusDetail,
  removeThreadEntries,
  liveSendOwnsRequest,
  releaseLiveSendRequest,
  setActiveStream,
  setActiveStreamRequestId,
  setRecordValue,
  setStatusDetail,
} from './keeper-state'
import {
  abortKeeperThreadMessage,
  applyKeeperStreamEvent,
  flushPendingKeeperStreamDeltas,
  TERMINAL_REQUEST_STATUSES,
} from './keeper-stream'
import {
  KEEPER_HISTORY_TAIL_MESSAGES,
} from './config/constants'
import {
  hasPendingKeeperChatRequest,
  pendingKeeperChatRequestsForKeeper,
  removePendingKeeperChatRequest,
  type PendingKeeperChatRequest,
  upsertPendingKeeperChatRequest,
} from './keeper-chat-pending'

type KeeperInterjectActionKind = 'send' | 'approve' | 'pause' | 'drain'

const TOOL_ONLY_EMPTY_REPLY_TEXT = 'Tool-only turn ended without a final reply.'
const EMPTY_VISIBLE_REPLY_TEXT =
  'Keeper가 thinking만 반환하고 표시할 답변을 만들지 못했습니다. 다시 보내주세요.'
const pendingKeeperThreadCancels = new Map<string, Promise<boolean>>()
const KEEPER_THREAD_CANCEL_TIMEOUT_MS = 5_000
const KEEPER_THREAD_CANCEL_SETTLE_GRACE_MS = 500
const KEEPER_STREAM_SIGNAL_THROTTLE_MS = 1_000
const keeperStreamSignalWrites = new Map<string, number>()

interface KeeperInterjectCommand {
  readonly kind: KeeperInterjectActionKind
  readonly keeperName: string
  readonly message?: string
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

function keeperThreadCancelSignal(): AbortSignal {
  return AbortSignal.timeout(KEEPER_THREAD_CANCEL_TIMEOUT_MS)
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

function cancelTrackingTimeoutMs(): number {
  return KEEPER_THREAD_CANCEL_TIMEOUT_MS + KEEPER_THREAD_CANCEL_SETTLE_GRACE_MS
}

function withCancelTrackingTimeout<T>(requestId: string, promise: Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`cancel request ${requestId} did not settle within ${cancelTrackingTimeoutMs()}ms`))
    }, cancelTrackingTimeoutMs()) as ReturnType<typeof setTimeout> & { unref?: () => void }
    timeout.unref?.()
    promise.then(resolve, reject).finally(() => clearTimeout(timeout))
  })
}

export function cancelKeeperThreadRequest(
  keeperName: string,
  requestId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<boolean> {
  const name = keeperName.trim()
  const id = requestId.trim()
  if (!name || !id) return Promise.resolve(false)
  const existing = pendingKeeperThreadCancels.get(id)
  if (existing) return existing
  const promise = withCancelTrackingTimeout(
    id,
    opts.signal
      ? cancelQueuedKeeperMessage(id, { signal: opts.signal })
      : cancelQueuedKeeperMessage(id),
  )
    .then(() => {
      removePendingKeeperChatRequest(id)
      releaseActiveStreamRequestId(id)
      setRecordValue(keeperActionErrors, name, null)
      return true
    })
    .catch((err) => {
      const message = keeperThreadCancelFailureMessage(name, id, err)
      console.warn('[keeper] server cancel failed', message)
      setRecordValue(keeperActionErrors, name, message)
      return false
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
    void cancelKeeperThreadRequest(keeperName, requestId, {
      signal: keeperThreadCancelSignal(),
    })
  }
  if (!requestIdBeforeAbort && !requestId && !locallyAborted) {
    // Nothing was in flight; treat as a successful no-op.
    return true
  }
  return locallyAborted
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
    await sendKeeperThreadMessage(keeperName, message)
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
      include_memory_bank: false,
      include_history_tail: false,
      include_compaction_history: false,
      tail_turns: 0,
      tail_messages: 0,
    })
    let parsed: unknown = null
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
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
    const history = await fetchKeeperChatHistory(keeperName)
    // Tool outputs are stored on a separate durable endpoint. Hydrate even
    // when chat history is empty so a keeper panel can still join recently
    // fetched tool rows from the rail/inspector.
    void hydrateKeeperToolOutputs(keeperName)
    if (history.length === 0) return
    mergeServerHistoryEntries(keeperName, chatHistoryEntriesFromRest(keeperName, history))
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
async function hydrateKeeperToolOutputs(keeperName: string): Promise<void> {
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
const STREAM_FAILURE_HISTORY_SKEW_MS = 30_000

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function entryTimeMs(entry: KeeperConversationEntry): number | null {
  if (!entry.timestamp) return null
  const ms = Date.parse(entry.timestamp)
  return Number.isFinite(ms) ? ms : null
}

function hasServerAssistantAfterLocalMessage(
  entries: readonly KeeperConversationEntry[],
  message: string,
  sentAtMs: number | null,
): boolean {
  const expectedText = message.trim()
  if (!expectedText) return false
  let matchedUser = false

  for (const entry of entries) {
    const tsMs = entryTimeMs(entry)
    if (
      sentAtMs !== null
      && tsMs !== null
      && tsMs < sentAtMs - STREAM_FAILURE_HISTORY_SKEW_MS
    ) {
      continue
    }

    if (entry.role === 'user' && entry.text.trim() === expectedText) {
      matchedUser = true
      continue
    }

    if (matchedUser && entry.role === 'assistant' && entry.text.trim() !== '') {
      return true
    }
  }

  return false
}

async function reconcileStreamFailureFromServerHistory(
  keeperName: string,
  message: string,
  localUserId: string,
  localAssistantId: string,
): Promise<boolean> {
  const localUser = (keeperThreads.value[keeperName] ?? [])
    .find(entry => entry.id === localUserId) ?? null
  const sentAtMs = localUser ? entryTimeMs(localUser) : null
  const history = await fetchKeeperChatHistory(keeperName)
  const historyEntries = chatHistoryEntriesFromRest(keeperName, history)
  if (!hasServerAssistantAfterLocalMessage(historyEntries, message, sentAtMs)) {
    return false
  }

  mergeServerHistoryEntries(keeperName, historyEntries)
  removeThreadEntries(keeperName, [localUserId, localAssistantId])
  return true
}

function pendingUserEntryId(requestId: string): string {
  return `pending-user-${requestId}`
}

function pendingAssistantEntryId(requestId: string): string {
  return `pending-assistant-${requestId}`
}

function isMissingQueuedKeeperRequestError(err: unknown): boolean {
  const record = isRecord(err) ? err : null
  const method = asString(record?.method, '').trim().toUpperCase()
  const status = typeof record?.status === 'number' ? record.status : null
  const path = asString(record?.path, '').trim()
  const message = err instanceof Error ? err.message : ''
  if (method === 'GET' && status === 404 && path.startsWith('/api/v1/gate/message/requests/')) {
    return message.includes('request_id not found')
  }
  return message.includes('/api/v1/gate/message/requests/')
    && message.includes('request_id not found')
}

function ensurePendingThreadEntries(request: PendingKeeperChatRequest): string {
  const existing = keeperThreads.value[request.keeperName] ?? []
  const userId = pendingUserEntryId(request.requestId)
  const assistantId = pendingAssistantEntryId(request.requestId)
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
      streamContract: keeperStreamContract('pending_request_store', 'client_placeholder', {
        requestId: request.requestId,
        deliveryReceipt: 'no_delivery_receipt',
        reason: 'restored pending queued request from browser storage',
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
      text: '',
      rawText: '',
      timestamp: null,
      delivery: 'queued',
      streamState: 'opening',
      streamContract: keeperStreamContract('pending_request_store', 'client_placeholder', {
        requestId: request.requestId,
        deliveryReceipt: 'no_delivery_receipt',
        reason: 'awaiting queued request poll result',
      }),
      details: null,
    })
  }
  return assistantId
}

let localIdCounter = 0

const resumingKeeperChatRequests = new Set<string>()
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

async function resumePendingKeeperChatRequest(request: PendingKeeperChatRequest): Promise<void> {
  // A live in-session send stream still owns this request (e.g. the panel
  // remounted on an SPA route change while the reply was pending). Defer to
  // it rather than minting a duplicate pending entry + a second poll loop.
  // After a full page reload this map is empty, so cold-start resume runs.
  if (liveSendOwnsRequest(request.requestId)) return
  const key = `${request.keeperName}:${request.requestId}`
  if (resumingKeeperChatRequests.has(key)) return
  resumingKeeperChatRequests.add(key)
  const assistantId = ensurePendingThreadEntries(request)
  setRecordValue(keeperSending, request.keeperName, true)
  setRecordValue(keeperActionErrors, request.keeperName, null)
  setRecordValue(keeperStreamStartedAt, request.keeperName, request.submittedAt)
  markKeeperStreamSignal(request.keeperName, { force: true })
  try {
    for (;;) {
      const result = await fetchQueuedKeeperMessageResult(request.requestId)
      markKeeperStreamSignal(request.keeperName)
      if (!isTerminalQueuedKeeperMessage(result)) {
        await sleep(PENDING_KEEPER_CHAT_POLL_MS)
        continue
      }

      const reply = queuedKeeperMessageToReply(result)
      const isCheckpoint = reply.details?.turnOutcome === 'continuation_checkpoint'
      const isNoVisibleReply = reply.details?.turnOutcome === 'no_visible_reply'
      const suppressReply = keeperTurnOutcomeSuppressesReply(reply.details?.turnOutcome)
      const isCancelled = result.status === 'cancelled'
      const isError = !isCancelled && (isNoVisibleReply || result.status !== 'done' || result.ok === false)
      let errorMessage: string | null = null
      if (isNoVisibleReply) {
        errorMessage = EMPTY_VISIBLE_REPLY_TEXT
      } else if (isError) {
        errorMessage = queuedKeeperMessageError(result)
      }
      let userDelivery: KeeperConversationDelivery = 'delivered'
      if (isCancelled) {
        userDelivery = 'cancelled'
      } else if (isError) {
        userDelivery = 'error'
      }
      let assistantDelivery: KeeperConversationDelivery = 'delivered'
      if (isCancelled) {
        assistantDelivery = 'cancelled'
      } else if (isCheckpoint) {
        assistantDelivery = 'queued'
      } else if (isNoVisibleReply) {
        assistantDelivery = 'error'
      } else if (isError) {
        assistantDelivery = 'error'
      }
      finalizeAssistantEntry(request.keeperName, pendingUserEntryId(request.requestId), {
        delivery: userDelivery,
        error: errorMessage,
        streamContract: keeperStreamContract('queue_poll', 'queue_poll_result', {
          requestId: request.requestId,
          deliveryReceipt: 'no_delivery_receipt',
          reason: errorMessage,
        }),
      })
      let assistantText = reply.text
      let assistantRawText = reply.details?.replyText ?? reply.text
      if (isNoVisibleReply) {
        assistantText = EMPTY_VISIBLE_REPLY_TEXT
        assistantRawText = EMPTY_VISIBLE_REPLY_TEXT
      } else if (suppressReply) {
        assistantText = ''
      }
      finalizeAssistantEntry(request.keeperName, assistantId, {
        text: assistantText,
        rawText: assistantRawText,
        delivery: assistantDelivery,
        streamState: null,
        timestamp: new Date().toISOString(),
        details: reply.details,
        error: errorMessage,
        streamContract: keeperStreamContract('queue_poll', 'queue_poll_result', {
          requestId: request.requestId,
          deliveryReceipt: 'no_delivery_receipt',
          reason: errorMessage,
        }),
      })
      if (errorMessage) setRecordValue(keeperActionErrors, request.keeperName, errorMessage)
      removePendingKeeperChatRequest(request.requestId)
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      return
    }
  } catch (err) {
    if (isMissingQueuedKeeperRequestError(err)) {
      removePendingKeeperChatRequest(request.requestId)
      finalizeAssistantEntry(request.keeperName, pendingUserEntryId(request.requestId), {
        delivery: 'error',
        error: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        streamContract: keeperStreamContract('queue_poll', 'contract_gap', {
          requestId: request.requestId,
          deliveryReceipt: 'no_delivery_receipt',
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
        streamContract: keeperStreamContract('queue_poll', 'contract_gap', {
          requestId: request.requestId,
          deliveryReceipt: 'no_delivery_receipt',
          reason: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        }),
      })
      setRecordValue(keeperActionErrors, request.keeperName, QUEUED_KEEPER_REQUEST_LOST_MESSAGE)
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      return
    }
    const detail = err instanceof Error ? err.message : `Failed to resume ${request.keeperName} chat request`
    const message = `${PENDING_KEEPER_CHAT_RESUME_FAILED_MESSAGE} (${detail})`
    removePendingKeeperChatRequest(request.requestId)
    finalizeAssistantEntry(request.keeperName, pendingUserEntryId(request.requestId), {
      delivery: 'error',
      error: message,
      streamContract: keeperStreamContract('queue_poll', 'contract_gap', {
        requestId: request.requestId,
        deliveryReceipt: 'no_delivery_receipt',
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
      streamContract: keeperStreamContract('queue_poll', 'contract_gap', {
        requestId: request.requestId,
        deliveryReceipt: 'no_delivery_receipt',
        reason: message,
      }),
    })
    setRecordValue(keeperActionErrors, request.keeperName, message)
    await hydrateKeeperChatHistory(request.keeperName, { force: true })
  } finally {
    resumingKeeperChatRequests.delete(key)
    if (!hasPendingKeeperChatRequest(request.keeperName)) {
      setRecordValue(keeperSending, request.keeperName, false)
      setRecordValue(keeperStreamStartedAt, request.keeperName, null)
      clearKeeperStreamSignal(request.keeperName)
    }
  }
}

export async function resumePendingKeeperChatRequests(name: string): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  await Promise.all(pendingKeeperChatRequestsForKeeper(keeperName).map(resumePendingKeeperChatRequest))
}

/** React to a server `keeper_chat_appended` push: re-merge the
 *  persisted transcript so messages arriving through other connectors
 *  (Discord, Slack, agent MCP) appear without a page reload.
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
 *  [blocks] is accepted so the live SSE path can carry server-parsed
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
    void hydrateKeeperChatHistory(keeperName, { force: true })
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
      include_memory_bank: false,
      include_history_tail: true,
      include_compaction_history: false,
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
  if (attachment.type === 'image') return 'image'
  if (attachment.mimeType.startsWith('audio/')) return 'audio'
  return 'document'
}

function attachmentToUserInputBlock(attachment: KeeperConversationAttachment): KeeperUserInputBlock {
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
    .map(block => block.name.trim())
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
  const hadActiveStream =
    activeStreamEntryId(keeperName) !== null || activeStreamRequestId(keeperName) !== null
  let previousCancelled = false
  try {
    previousCancelled = await cancelActiveKeeperThreadMessage(keeperName)
  } catch (err) {
    sendKeys.forEach(key => sendingKeeperThreadMessages.delete(key))
    throw err
  }
  if (hadActiveStream && !previousCancelled) {
    sendKeys.forEach(key => sendingKeeperThreadMessages.delete(key))
    return
  }
  const localId = `local-${++localIdCounter}-${Date.now()}`
  const assistantId = `reply-${++localIdCounter}-${Date.now()}`
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
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
    blocks,
    details: null,
  })
  appendThreadEntry(keeperName, {
    id: assistantId,
    role: 'assistant',
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
  setActiveStream(keeperName, assistantId, controller)
  let requestId: string | null = null
  let requestTerminalSeen = false
  let toolCallEnded = false
  try {
    finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered' })

    const outcome = await streamKeeperMessage(keeperName, message, {
      signal: controller.signal,
      attachments,
      userBlocks,
      onEvent: event => {
        markKeeperStreamSignal(keeperName)
        if (event.type === 'CUSTOM' && event.name === 'KEEPER_QUEUE_REQUEST') {
          const nextRequestId = isRecord(event.value)
            ? asString(event.value.request_id, '').trim()
            : ''
          if (!nextRequestId) {
            const message = 'Keeper queue request event missing request_id; server cancel unavailable.'
            console.warn(`[keeper] ${message}`)
            setRecordValue(keeperActionErrors, keeperName, message)
          } else if (controller.signal.aborted) {
            requestId = nextRequestId
            void cancelKeeperThreadRequest(keeperName, nextRequestId, {
              signal: keeperThreadCancelSignal(),
            })
          } else {
            requestId = nextRequestId
            // This live send now owns the request; resume must defer to it
            // (and not mint a duplicate pending entry) until handoff/finally.
            setActiveStreamRequestId(keeperName, requestId)
            upsertPendingKeeperChatRequest({
              requestId,
              keeperName,
              message,
              submittedAt: Date.now(),
              ...(attachments ? { attachments } : {}),
            })
          }
        }
        if (event.type === 'CUSTOM' && event.name === 'KEEPER_REQUEST_TERMINAL' && isRecord(event.value)) {
          const terminalRequestId = asString(event.value.request_id, '').trim()
          const status = asString(event.value.status, '').trim()
          const matchesActiveRequest =
            Boolean(terminalRequestId) && requestId !== null && terminalRequestId === requestId
          if (matchesActiveRequest && TERMINAL_REQUEST_STATUSES.has(status)) {
            requestTerminalSeen = true
            removePendingKeeperChatRequest(terminalRequestId)
          }
        }
        const error = applyKeeperStreamEvent(keeperName, assistantId, event)
        if (error) {
          throw new Error(error)
        }
        if (event.type === 'TOOL_CALL_END') {
          toolCallEnded = true
          void hydrateKeeperToolOutputs(keeperName)
        }
      },
    })

    flushPendingKeeperStreamDeltas(keeperName, assistantId)
    const finalEntry =
      (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId) ?? null
    const finalText = finalEntry?.text.trim() ?? ''

    if (!outcome.terminal) {
      if (requestId) {
        removeThreadEntries(keeperName, [localId, assistantId])
        // Hand off to resume: release ownership FIRST so our own resume
        // call below is not blocked by the guard we just set.
        releaseLiveSendRequest(requestId)
        releaseActiveStreamRequestId(requestId)
        await resumePendingKeeperChatRequest({
          requestId,
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
        streamContract: keeperStreamContract('client_reconciliation', 'contract_gap', {
          deliveryReceipt: 'no_delivery_receipt',
          reason: cutMessage,
        }),
      })
      setRecordValue(keeperActionErrors, keeperName, cutMessage)
      if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
      clearActiveStreamRequestId(keeperName)
      return
    }

    const finalDelivery =
      !finalText && finalEntry?.delivery === 'queued'
        ? 'queued' as KeeperConversationDelivery
        : 'delivered' as KeeperConversationDelivery
    if (!finalText && finalDelivery !== 'queued' && !toolCallEnded) {
      finalizeAssistantEntry(keeperName, assistantId, {
        text: EMPTY_VISIBLE_REPLY_TEXT,
        rawText: finalEntry?.rawText || EMPTY_VISIBLE_REPLY_TEXT,
        delivery: 'error',
        streamState: null,
        timestamp: new Date().toISOString(),
        error: EMPTY_VISIBLE_REPLY_TEXT,
        streamContract: keeperStreamContract('client_reconciliation', 'contract_gap', {
          deliveryReceipt: 'no_delivery_receipt',
          reason: EMPTY_VISIBLE_REPLY_TEXT,
        }),
      })
      setRecordValue(keeperActionErrors, keeperName, EMPTY_VISIBLE_REPLY_TEXT)
      if (requestId) {
        removePendingKeeperChatRequest(requestId)
        releaseActiveStreamRequestId(requestId)
      }
      return
    }
    let emptyTerminalText = ''
    if (toolCallEnded) {
      emptyTerminalText = TOOL_ONLY_EMPTY_REPLY_TEXT
    }

    finalizeAssistantEntry(keeperName, assistantId, {
      text: finalText || emptyTerminalText,
      delivery: finalDelivery,
      streamState: null,
      timestamp: new Date().toISOString(),
      error: null,
      streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_terminal_event', {
        eventName: 'RUN_FINISHED',
      }),
    })
    if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
    if (requestId) {
      removePendingKeeperChatRequest(requestId)
      releaseActiveStreamRequestId(requestId)
    }
  } catch (err) {
    flushPendingKeeperStreamDeltas(keeperName, assistantId)
    if (isAbortError(err)) {
      const shouldAttemptServerCancel = Boolean(requestId && liveSendOwnsRequest(requestId))
      const serverCancelAlreadyFinalized = Boolean(
        requestId
        && !liveSendOwnsRequest(requestId)
        && !pendingKeeperChatRequestsForKeeper(keeperName).some(r => r.requestId === requestId),
      )
      let cancelSucceeded = serverCancelAlreadyFinalized
      if (shouldAttemptServerCancel && requestId) {
        cancelSucceeded = await cancelKeeperThreadRequest(keeperName, requestId, {
          signal: keeperThreadCancelSignal(),
        })
      }
      finalizeAssistantEntry(keeperName, localId, {
        delivery: 'cancelled',
        error: null,
        streamContract: keeperStreamContract('client_reconciliation', 'contract_gap', {
          deliveryReceipt: 'no_delivery_receipt',
          requestId: requestId ?? undefined,
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
        streamContract: keeperStreamContract('client_reconciliation', 'contract_gap', {
          deliveryReceipt: 'no_delivery_receipt',
          requestId: requestId ?? undefined,
          reason: KEEPER_MESSAGE_CANCELLED_TEXT,
        }),
      })
      if (cancelSucceeded) setRecordValue(keeperActionErrors, keeperName, null)
      throw err
    }

    const errorMessage =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    finalizeAssistantEntry(keeperName, assistantId, {
      delivery: 'error' as KeeperConversationDelivery,
      streamState: null,
      error: errorMessage,
      timestamp: new Date().toISOString(),
      streamContract: keeperStreamContract('client_reconciliation', 'contract_gap', {
        deliveryReceipt: 'no_delivery_receipt',
        requestId: requestId ?? undefined,
        reason: errorMessage,
      }),
    })
    finalizeAssistantEntry(keeperName, localId, {
      delivery: 'error' as KeeperConversationDelivery,
      error: errorMessage,
      streamContract: keeperStreamContract('client_reconciliation', 'contract_gap', {
        deliveryReceipt: 'no_delivery_receipt',
        requestId: requestId ?? undefined,
        reason: errorMessage,
      }),
    })
    if (requestTerminalSeen && requestId) {
      removePendingKeeperChatRequest(requestId)
      releaseActiveStreamRequestId(requestId)
    }
    try {
      const reconciled = await reconcileStreamFailureFromServerHistory(
        keeperName,
        message,
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
    // Release ownership on every exit (success/abort/error). Idempotent:
    // the non-terminal handoff above already released, so this is a no-op
    // there; Map.delete of an absent key is harmless.
    if (requestId) {
      releaseLiveSendRequest(requestId)
      releaseKeeperThreadCancelTracking(requestId)
    }
    sendKeys.forEach(key => sendingKeeperThreadMessages.delete(key))
    if (activeStreamEntryId(keeperName) === assistantId) {
      clearActiveStream(keeperName)
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
