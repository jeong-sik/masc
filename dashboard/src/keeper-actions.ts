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
import { asString, isRecord } from './components/common/normalize'
import { invalidateDashboardCache, refreshDashboard } from './store'
import { isAbortError } from './lib/async-state'
import type {
  KeeperConversationAttachment,
  KeeperConversationDelivery,
  KeeperDiagnostic,
  KeeperStatusDetail,
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
  appendThreadEntry,
  chatHistoryEntriesFromRest,
  clearActiveStream,
  finalizeAssistantEntry,
  mergeServerHistoryEntries,
  normalizeKeeperProbeResult,
  normalizeKeeperRecoverResult,
  normalizeStatusDetail,
  removeThreadEntries,
  setActiveStream,
  setRecordValue,
  setStatusDetail,
} from './keeper-state'
import { abortKeeperThreadMessage, applyKeeperStreamEvent } from './keeper-stream'
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

// Trailing per-keeper debounce for keeper_chat_appended pushes so a
// burst of turns (queue drain, multi-connector traffic) coalesces into
// one history refetch instead of one round-trip per message.
const chatRefreshTimers = new Map<string, ReturnType<typeof setTimeout>>()
const CHAT_APPENDED_REFRESH_DELAY_MS = 400
const PENDING_KEEPER_CHAT_POLL_MS = 2_000

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
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
      details: null,
    })
  }
  return assistantId
}

const resumingKeeperChatRequests = new Set<string>()

async function resumePendingKeeperChatRequest(request: PendingKeeperChatRequest): Promise<void> {
  const key = `${request.keeperName}:${request.requestId}`
  if (resumingKeeperChatRequests.has(key)) return
  resumingKeeperChatRequests.add(key)
  const assistantId = ensurePendingThreadEntries(request)
  setRecordValue(keeperSending, request.keeperName, true)
  setRecordValue(keeperActionErrors, request.keeperName, null)
  setRecordValue(keeperStreamStartedAt, request.keeperName, request.submittedAt)
  setRecordValue(keeperStreamLastEventAt, request.keeperName, Date.now())
  try {
    for (;;) {
      const result = await fetchQueuedKeeperMessageResult(request.requestId)
      setRecordValue(keeperStreamLastEventAt, request.keeperName, Date.now())
      if (!isTerminalQueuedKeeperMessage(result)) {
        await sleep(PENDING_KEEPER_CHAT_POLL_MS)
        continue
      }

      const reply = queuedKeeperMessageToReply(result)
      const isCheckpoint = reply.details?.turnOutcome === 'continuation_checkpoint'
      const isError = result.status !== 'done' || result.ok === false
      const errorMessage = isError ? queuedKeeperMessageError(result) : null
      let assistantDelivery: KeeperConversationDelivery = 'delivered'
      if (isCheckpoint) {
        assistantDelivery = 'queued'
      } else if (isError) {
        assistantDelivery = 'error'
      }
      finalizeAssistantEntry(request.keeperName, pendingUserEntryId(request.requestId), {
        delivery: isError ? 'error' : 'delivered',
        error: errorMessage,
      })
      finalizeAssistantEntry(request.keeperName, assistantId, {
        text: isCheckpoint ? '' : reply.text,
        rawText: reply.details?.replyText ?? reply.text,
        delivery: assistantDelivery,
        streamState: null,
        timestamp: new Date().toISOString(),
        details: reply.details,
        error: errorMessage,
      })
      if (errorMessage) setRecordValue(keeperActionErrors, request.keeperName, errorMessage)
      removePendingKeeperChatRequest(request.requestId)
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      return
    }
  } catch (err) {
    if (isMissingQueuedKeeperRequestError(err)) {
      removePendingKeeperChatRequest(request.requestId)
      removeThreadEntries(request.keeperName, [
        pendingUserEntryId(request.requestId),
        assistantId,
      ])
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      return
    }
    const message = err instanceof Error ? err.message : `Failed to resume ${request.keeperName} chat request`
    setRecordValue(keeperActionErrors, request.keeperName, `대기 중 메시지 복구 실패: ${message}`)
  } finally {
    resumingKeeperChatRequests.delete(key)
    if (!hasPendingKeeperChatRequest(request.keeperName)) {
      setRecordValue(keeperSending, request.keeperName, false)
      setRecordValue(keeperStreamStartedAt, request.keeperName, null)
      setRecordValue(keeperStreamLastEventAt, request.keeperName, null)
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
 *  (Discord, Slack, agent MCP) appear without a page reload. Keepers
 *  whose transcript was never hydrated are skipped — the mount
 *  hydration fetches the full window when the panel first opens. */
export function noteKeeperChatAppended(name: string): void {
  const keeperName = name.trim()
  if (!keeperName) return
  if (!hydratedChatKeepers.has(keeperName)) return
  const pending = chatRefreshTimers.get(keeperName)
  if (pending) clearTimeout(pending)
  chatRefreshTimers.set(keeperName, setTimeout(() => {
    chatRefreshTimers.delete(keeperName)
    void hydrateKeeperChatHistory(keeperName, { force: true })
  }, CHAT_APPENDED_REFRESH_DELAY_MS))
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

export async function sendKeeperThreadMessage(
  name: string,
  prompt: string,
  options: { attachments?: KeeperConversationAttachment[] } = {},
): Promise<void> {
  const keeperName = name.trim()
  const message = prompt.trim()
  if (!keeperName || !message) return
  const attachments =
    options.attachments && options.attachments.length > 0 ? options.attachments : undefined
  abortKeeperThreadMessage(keeperName)
  const localId = `local-${Date.now()}`
  const assistantId = `reply-${Date.now()}`
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
    source: 'direct_user',
    label: 'You',
    text: message,
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: null,
    attachments,
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
    details: null,
  })
  setRecordValue(keeperSending, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  setRecordValue(keeperStreamStartedAt, keeperName, Date.now())
  const controller = new AbortController()
  setActiveStream(keeperName, assistantId, controller)
  let requestId: string | null = null
  let requestTerminalSeen = false
  try {
    finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered' })

    const outcome = await streamKeeperMessage(keeperName, message, {
      signal: controller.signal,
      attachments,
      onEvent: event => {
        setRecordValue(keeperStreamLastEventAt, keeperName, Date.now())
        if (event.type === 'CUSTOM' && event.name === 'KEEPER_QUEUE_REQUEST' && isRecord(event.value)) {
          requestId = asString(event.value.request_id, '').trim() || requestId
          if (requestId) {
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
          requestTerminalSeen = true
          const terminalRequestId = asString(event.value.request_id, '').trim()
          if (terminalRequestId) removePendingKeeperChatRequest(terminalRequestId)
        }
        const error = applyKeeperStreamEvent(keeperName, assistantId, event)
        if (error) {
          throw new Error(error)
        }
      },
    })

    const finalEntry =
      (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId) ?? null
    const finalText = finalEntry?.text.trim() ?? ''

    if (!outcome.terminal) {
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
      })
      setRecordValue(keeperActionErrors, keeperName, cutMessage)
      return
    }

    const finalDelivery =
      !finalText && finalEntry?.delivery === 'queued'
        ? 'queued' as KeeperConversationDelivery
        : 'delivered' as KeeperConversationDelivery

    finalizeAssistantEntry(keeperName, assistantId, {
      text: finalText || (finalDelivery === 'queued' ? '' : '(empty reply)'),
      delivery: finalDelivery,
      streamState: null,
      timestamp: new Date().toISOString(),
      error: null,
    })
    if (requestId) removePendingKeeperChatRequest(requestId)
  } catch (err) {
    if (isAbortError(err)) {
      if (requestId) {
        try {
          await cancelQueuedKeeperMessage(requestId)
        } catch (cancelErr) {
          console.warn(`[keeper] queue cancel failed for ${keeperName}`, cancelErr instanceof Error ? cancelErr.message : cancelErr)
        }
        removePendingKeeperChatRequest(requestId)
      }
      finalizeAssistantEntry(keeperName, assistantId, {
        delivery: 'timeout',
        streamState: null,
        error: '요청 취소됨',
        timestamp: new Date().toISOString(),
      })
      setRecordValue(keeperActionErrors, keeperName, '요청 취소됨')
      throw err
    }

    const errorMessage =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    finalizeAssistantEntry(keeperName, assistantId, {
      delivery: 'error' as KeeperConversationDelivery,
      streamState: null,
      error: errorMessage,
      timestamp: new Date().toISOString(),
    })
    finalizeAssistantEntry(keeperName, localId, {
      delivery: 'error' as KeeperConversationDelivery,
      error: errorMessage,
    })
    if (requestTerminalSeen && requestId) removePendingKeeperChatRequest(requestId)
    setRecordValue(keeperActionErrors, keeperName, errorMessage)
    throw err
  } finally {
    clearActiveStream(keeperName)
    setRecordValue(keeperSending, keeperName, false)
    setRecordValue(keeperStreamStartedAt, keeperName, null)
    setRecordValue(keeperStreamLastEventAt, keeperName, null)
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
