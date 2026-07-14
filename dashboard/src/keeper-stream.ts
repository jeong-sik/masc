import {
  formatKeeperVisibleReply,
  keeperTurnOutcomeSuppressesReply,
  normalizeKeeperConversationDetails,
} from './keeper-message'
import { parseTextToChatBlocks } from './lib/chat-blocks'
import type { KeeperChatStreamEvent } from './api'
import type { KeeperConversationDetails } from './types'
import {
  appendAssistantDelta,
  promoteAssistantTextToProgress,
  appendAssistantToolTraceArgsDelta,
  setAssistantToolTraceArgsSnapshot,
  appendAssistantToolTraceStep,
  setAssistantThinkingSnapshot,
  setAssistantStreamState,
  updateThreadEntry,
  insertThreadEntryBefore,
  finalizeAssistantEntry,
  markAssistantToolTraceEnded,
  markAssistantToolTraceErrored,
  clearActiveStream,
  clearActiveStreamRequestId,
  releaseActiveStreamRequestId,
  activeStreamEntryId,
  activeStreamRequestId,
  getStreamController,
  keeperClientObservedSseStreamContract,
  keeperThreads,
  keeperSending,
  keeperStreamStartedAt,
  setRecordValue,
} from './keeper-state'
import { isRecord, asNumber, asString } from './components/common/normalize'
import { toolEntryIdFromCallId } from './tool-call-output-store'
import { STREAMING_THINKING_PREVIEW_CHARS } from './config/constants'
import { updatePendingKeeperChatAssistantDraft } from './keeper-chat-pending'
import { isKeeperChatReceiptId, parseKeeperQueueRevision } from './lib/keeper-chat-receipt'

const KEEPER_MESSAGE_CANCELLED_TEXT = '요청이 취소되었습니다.'
export const TERMINAL_REQUEST_STATUSES = new Set(['done', 'error', 'lost', 'cancelled'])
export const KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS = 100

const pendingOasToolBlockIndexes = new Map<string, number>()
const pendingOasTextBlockIndexes = new Map<string, number>()
type ScheduledFlushHandle = ReturnType<typeof setTimeout>
interface PendingThinkingState {
  chunks: string[]
  preview: string
  oasBlockIndex?: number
  flushHandle: ScheduledFlushHandle | null
}

const pendingThinkingDeltas = new Map<string, PendingThinkingState>()

function streamEntryKey(keeperName: string, assistantEntryId: string): string {
  return `${keeperName}\u0000${assistantEntryId}`
}

function scheduleThinkingFlush(callback: () => void): ScheduledFlushHandle {
  return setTimeout(callback, KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
}

function cancelStreamFlush(handle: ScheduledFlushHandle): void {
  clearTimeout(handle)
}

function sameOasBlockIndex(left: number | undefined, right: number | undefined): boolean {
  return left === undefined ? right === undefined : left === right
}

function nextThinkingPreview(current: string, delta: string): string {
  const next = `${current}${delta}`
  if (next.length <= STREAMING_THINKING_PREVIEW_CHARS) return next
  const marker = '...\n'
  return `${marker}${next.slice(-(STREAMING_THINKING_PREVIEW_CHARS - marker.length))}`
}

function fullPendingThinkingText(pending: PendingThinkingState): string {
  return pending.chunks.join('')
}

function persistActiveAssistantDraft(keeperName: string, assistantEntryId: string): void {
  const requestId = activeStreamRequestId(keeperName)
  if (!requestId) return
  const entry = (keeperThreads.value[keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return
  updatePendingKeeperChatAssistantDraft(requestId, entry)
}

function flushPendingThinkingDeltas(
  keeperName: string,
  assistantEntryId: string,
  mode: 'commit' | 'preview' = 'commit',
): void {
  const key = streamEntryKey(keeperName, assistantEntryId)
  const pending = pendingThinkingDeltas.get(key)
  if (!pending) return
  if (pending.flushHandle !== null) {
    cancelStreamFlush(pending.flushHandle)
    pending.flushHandle = null
  }
  if (mode === 'preview') {
    setAssistantThinkingSnapshot(keeperName, assistantEntryId, pending.preview, {
      oasBlockIndex: pending.oasBlockIndex,
    })
    persistActiveAssistantDraft(keeperName, assistantEntryId)
    return
  }
  pendingThinkingDeltas.delete(key)
  setAssistantThinkingSnapshot(keeperName, assistantEntryId, fullPendingThinkingText(pending), {
    oasBlockIndex: pending.oasBlockIndex,
  })
  persistActiveAssistantDraft(keeperName, assistantEntryId)
}

function dropPendingThinkingDeltas(keeperName: string, assistantEntryId: string): void {
  const key = streamEntryKey(keeperName, assistantEntryId)
  const pending = pendingThinkingDeltas.get(key)
  if (!pending) return
  pendingThinkingDeltas.delete(key)
  if (pending.flushHandle !== null) {
    cancelStreamFlush(pending.flushHandle)
  }
}

function flushAllPendingThinkingDeltas(): void {
  for (const key of Array.from(pendingThinkingDeltas.keys())) {
    const [keeperName, assistantEntryId] = key.split('\u0000')
    if (keeperName && assistantEntryId) {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
    }
  }
}

function enqueueThinkingDelta(
  keeperName: string,
  assistantEntryId: string,
  delta: string,
  meta: { oasBlockIndex?: number } = {},
): void {
  if (!delta.trim()) return
  const key = streamEntryKey(keeperName, assistantEntryId)
  let pending = pendingThinkingDeltas.get(key)
  if (pending && !sameOasBlockIndex(pending.oasBlockIndex, meta.oasBlockIndex)) {
    flushPendingThinkingDeltas(keeperName, assistantEntryId)
    pending = undefined
  }
  if (!pending) {
    const text = delta.trimStart()
    pending = {
      chunks: [text],
      preview: text,
      oasBlockIndex: meta.oasBlockIndex,
      flushHandle: null,
    }
    pendingThinkingDeltas.set(key, pending)
  } else {
    pending.chunks.push(delta)
    pending.preview = nextThinkingPreview(pending.preview, delta)
  }
  if (pending.flushHandle !== null) return
  pending.flushHandle = scheduleThinkingFlush(() => {
    flushPendingThinkingDeltas(keeperName, assistantEntryId, 'preview')
  })
}

export function _flushPendingKeeperStreamDeltasForTests(): void {
  flushAllPendingThinkingDeltas()
}

export function flushPendingKeeperStreamDeltas(keeperName: string, assistantEntryId: string): void {
  flushPendingThinkingDeltas(keeperName, assistantEntryId)
}

export function _resetKeeperStreamBuffersForTests(): void {
  for (const pending of pendingThinkingDeltas.values()) {
    if (pending.flushHandle !== null) {
      cancelStreamFlush(pending.flushHandle)
    }
  }
  pendingThinkingDeltas.clear()
  pendingOasToolBlockIndexes.clear()
  pendingOasTextBlockIndexes.clear()
}

export interface KeeperThreadAbortResult {
  readonly keeperName: string
  readonly entryId: string | null
  readonly requestId: string | null
  readonly controllerAborted: boolean
}

function streamProtocolMessage(value: unknown, fallback: string): string {
  if (!isRecord(value)) return fallback
  const kind = asString(value.kind, '').trim()
  const reason = asString(value.reason, '').trim()
  const eventType = asString(value.event_type, '').trim()
  const toolCallId = asString(value.tool_call_id, '').trim()
  const index = typeof value.index === 'number' ? `index=${value.index}` : ''
  return [
    kind || fallback,
    eventType ? `event=${eventType}` : '',
    index,
    toolCallId ? `tool_call_id=${toolCallId}` : '',
    reason,
  ]
    .filter(part => part.trim() !== '')
    .join(' | ')
}

function recordStreamProtocolError(
  keeperName: string,
  assistantEntryId: string,
  message: string,
  toolCallId?: string,
): void {
  updateThreadEntry(keeperName, assistantEntryId, entry => {
    const line = `[stream protocol] ${message}`
    return {
      ...entry,
      rawText: entry.rawText?.trim() ? `${entry.rawText}\n${line}` : line,
      error: message,
    }
  })
  const id = toolCallId?.trim()
  if (id) {
    markAssistantToolTraceErrored(keeperName, assistantEntryId, id)
    updateThreadEntry(keeperName, toolEntryIdFromCallId(id), entry => ({
      ...entry,
      delivery: 'error',
      streamState: null,
      error: message,
    }))
  }
}

function oasToolBlockKey(keeperName: string, assistantEntryId: string, toolCallId: string): string {
  return `${keeperName}\u0000${assistantEntryId}\u0000${toolCallId}`
}

function rememberOasToolBlockIndex(
  keeperName: string,
  assistantEntryId: string,
  toolCallId: string,
  index: number | undefined,
): void {
  const id = toolCallId.trim()
  if (!id || index === undefined) return
  pendingOasToolBlockIndexes.set(oasToolBlockKey(keeperName, assistantEntryId, id), index)
}

function takeOasToolBlockIndex(
  keeperName: string,
  assistantEntryId: string,
  toolCallId: string,
): number | undefined {
  const key = oasToolBlockKey(keeperName, assistantEntryId, toolCallId)
  const index = pendingOasToolBlockIndexes.get(key)
  pendingOasToolBlockIndexes.delete(key)
  return index
}

function forgetOasToolBlockIndexByIndex(
  keeperName: string,
  assistantEntryId: string,
  index: number | undefined,
): void {
  if (index === undefined) return
  const prefix = `${keeperName}\u0000${assistantEntryId}\u0000`
  for (const [key, value] of pendingOasToolBlockIndexes.entries()) {
    if (key.startsWith(prefix) && value === index) pendingOasToolBlockIndexes.delete(key)
  }
}

function clearPendingOasToolBlockIndexesForEntry(keeperName: string, assistantEntryId: string): void {
  const prefix = `${keeperName}\u0000${assistantEntryId}\u0000`
  for (const key of pendingOasToolBlockIndexes.keys()) {
    if (key.startsWith(prefix)) pendingOasToolBlockIndexes.delete(key)
  }
}

function rememberOasTextBlockIndex(
  keeperName: string,
  assistantEntryId: string,
  index: number | undefined,
): void {
  if (index === undefined) return
  pendingOasTextBlockIndexes.set(streamEntryKey(keeperName, assistantEntryId), index)
}

function takeOasTextBlockIndex(keeperName: string, assistantEntryId: string): number | undefined {
  const key = streamEntryKey(keeperName, assistantEntryId)
  const index = pendingOasTextBlockIndexes.get(key)
  pendingOasTextBlockIndexes.delete(key)
  return index
}

function clearPendingOasTextBlockIndex(keeperName: string, assistantEntryId: string): void {
  pendingOasTextBlockIndexes.delete(streamEntryKey(keeperName, assistantEntryId))
}

function normalizeStreamUsage(raw: unknown): NonNullable<KeeperConversationDetails['usage']> | null {
  if (!isRecord(raw)) return null
  const usage: NonNullable<KeeperConversationDetails['usage']> = {
    inputTokens: asNumber(raw.input_tokens) ?? null,
    outputTokens: asNumber(raw.output_tokens) ?? null,
    totalTokens: asNumber(raw.total_tokens) ?? null,
  }
  const cacheCreationInputTokens = asNumber(raw.cache_creation_input_tokens)
  const cacheReadInputTokens = asNumber(raw.cache_read_input_tokens)
  const costUsd = asNumber(raw.cost_usd)
  if (cacheCreationInputTokens !== undefined) {
    usage.cacheCreationInputTokens = cacheCreationInputTokens
  }
  if (cacheReadInputTokens !== undefined) {
    usage.cacheReadInputTokens = cacheReadInputTokens
  }
  if (costUsd !== undefined) usage.costUsd = costUsd
  return usage
}

function mergeAssistantStreamDetails(
  keeperName: string,
  assistantEntryId: string,
  patch: Partial<KeeperConversationDetails>,
): void {
  updateThreadEntry(keeperName, assistantEntryId, entry => ({
    ...entry,
    details: {
      ...(entry.details ?? {}),
      ...patch,
      usage: patch.usage ?? entry.details?.usage ?? null,
      rawPayload: entry.details?.rawPayload,
    },
  }))
}

export function abortKeeperThreadMessage(name: string): KeeperThreadAbortResult | null {
  const keeperName = name.trim()
  if (!keeperName) return null
  const controller = getStreamController(keeperName)
  const entryId = activeStreamEntryId(keeperName)
  const requestId = activeStreamRequestId(keeperName)
  console.debug(`[keeper-stream] aborting stream for ${keeperName}${entryId ? ` (entry=${entryId})` : ''}${requestId ? ` request=${requestId}` : ''}`)
  if (controller) controller.abort()
  if (entryId) {
    dropPendingThinkingDeltas(keeperName, entryId)
    finalizeAssistantEntry(keeperName, entryId, {
      text: KEEPER_MESSAGE_CANCELLED_TEXT,
      rawText: KEEPER_MESSAGE_CANCELLED_TEXT,
      delivery: 'cancelled',
      streamState: null,
      error: null,
      timestamp: new Date().toISOString(),
    })
    clearPendingOasToolBlockIndexesForEntry(keeperName, entryId)
    clearPendingOasTextBlockIndex(keeperName, entryId)
  }
  clearActiveStream(keeperName)
  setRecordValue(keeperSending, keeperName, false)
  setRecordValue(keeperStreamStartedAt, keeperName, null)
  return {
    keeperName,
    entryId,
    requestId,
    controllerAborted: Boolean(controller),
  }
}

export function applyKeeperStreamEvent(
  keeperName: string,
  assistantEntryId: string,
  event: KeeperChatStreamEvent,
): string | null {
  const applyTextDelta = (payload: unknown): void => {
    if (typeof payload !== 'string') return
    if (payload) {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      appendAssistantDelta(keeperName, assistantEntryId, payload)
    }
  }
  const markFinalizingIfLive = (eventName: string): void => {
    updateThreadEntry(keeperName, assistantEntryId, entry => {
      if (entry.streamState === null) return entry
      if (entry.delivery !== 'sending' && entry.delivery !== 'streaming') return entry
      return {
        ...entry,
        streamState: 'finalizing',
        delivery: 'streaming',
        streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName }),
      }
    })
  }

  switch (event.type) {
    case 'RUN_STARTED':
      setAssistantStreamState(
        keeperName,
        assistantEntryId,
        'opening',
        'sending',
        keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'RUN_STARTED' }),
      )
      return null
    case 'TEXT_MESSAGE_START':
      // Flush any buffered thinking deltas before entering the text phase so a
      // pending scheduled flush cannot run later and revert streamState to
      // 'thinking' after text streaming has begun. Mirrors TEXT_MESSAGE_END and
      // TOOL_CALL_START, which flush at their phase boundaries.
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      setAssistantStreamState(
        keeperName,
        assistantEntryId,
        'streaming',
        'streaming',
        keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'TEXT_MESSAGE_START' }),
      )
      return null
    case 'TEXT_MESSAGE_CONTENT': {
      applyTextDelta(event.delta)
      return null
    }
    case 'TEXT_MESSAGE_END':
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      clearPendingOasToolBlockIndexesForEntry(keeperName, assistantEntryId)
      markFinalizingIfLive('TEXT_MESSAGE_END')
      return null
    case 'TOOL_CALL_START': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = event.toolCallId?.trim()
      const toolName = (event.toolCallName ?? event.name)?.trim()
      if (!toolCallId || !toolName) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_START missing toolCallId or toolCallName',
        )
        return null
      }
      promoteAssistantTextToProgress(keeperName, assistantEntryId, {
        oasBlockIndex: takeOasTextBlockIndex(keeperName, assistantEntryId),
      })
      appendAssistantToolTraceStep(keeperName, assistantEntryId, {
        toolCallId,
        name: toolName,
        oasBlockIndex: takeOasToolBlockIndex(keeperName, assistantEntryId, toolCallId),
      })
      // Insert above the live assistant bubble so the final reply text
      // stays the last entry in the transcript.
      insertThreadEntryBefore(keeperName, assistantEntryId, {
        id: toolEntryIdFromCallId(toolCallId),
        role: 'tool',
        source: 'tool_result',
        label: toolName,
        text: '',
        rawText: '',
        timestamp: new Date().toISOString(),
        delivery: 'streaming',
        streamState: 'streaming',
        streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'TOOL_CALL_START' }),
        details: null,
      })
      return null
    }
    case 'TOOL_CALL_ARGS': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = event.toolCallId?.trim()
      if (!toolCallId) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_ARGS missing toolCallId',
        )
        return null
      }
      const snapshot = event.snapshot
      if (toolCallId && typeof snapshot === 'string') {
        setAssistantToolTraceArgsSnapshot(keeperName, assistantEntryId, toolCallId, snapshot)
        updateThreadEntry(keeperName, toolEntryIdFromCallId(toolCallId), entry => ({
          ...entry,
          text: snapshot,
          rawText: snapshot,
        }))
      } else if (toolCallId && typeof event.delta === 'string' && event.delta) {
        appendAssistantToolTraceArgsDelta(keeperName, assistantEntryId, toolCallId, event.delta)
        updateThreadEntry(keeperName, toolEntryIdFromCallId(toolCallId), entry => ({
          ...entry,
          text: `${entry.text}${event.delta}`,
          rawText: `${entry.rawText ?? entry.text}${event.delta}`,
        }))
      }
      return null
    }
    case 'TOOL_CALL_END': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = event.toolCallId?.trim()
      if (!toolCallId) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_END missing toolCallId',
        )
        return null
      }
      if (toolCallId) {
        markAssistantToolTraceEnded(keeperName, assistantEntryId, toolCallId)
        updateThreadEntry(keeperName, toolEntryIdFromCallId(toolCallId), entry => ({
          ...entry,
          delivery: 'delivered',
          streamState: null,
          streamContract: keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'TOOL_CALL_END' }),
        }))
      }
      return null
    }
    case 'CUSTOM':
      if (event.name === 'KEEPER_STREAM_MESSAGE_START') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        const patch: Partial<KeeperConversationDetails> = {}
        const providerMessageId = asString(value?.provider_message_id)
        const modelUsed = asString(value?.model)
        const usage = normalizeStreamUsage(value?.usage)
        if (providerMessageId) patch.providerMessageId = providerMessageId
        if (modelUsed) patch.modelUsed = modelUsed
        if (usage) patch.usage = usage
        if (usage?.costUsd !== undefined) patch.costUsd = usage.costUsd
        if (Object.keys(patch).length > 0) mergeAssistantStreamDetails(keeperName, assistantEntryId, patch)
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_STREAM_MESSAGE_START' }),
        )
        return null
      }
      if (event.name === 'KEEPER_STREAM_MESSAGE_DELTA') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        const patch: Partial<KeeperConversationDetails> = {}
        const stopReason = asString(value?.stop_reason)
        const usage = normalizeStreamUsage(value?.usage)
        if (stopReason) patch.stopReason = stopReason
        if (usage) patch.usage = usage
        if (usage?.costUsd !== undefined) patch.costUsd = usage.costUsd
        if (Object.keys(patch).length > 0) mergeAssistantStreamDetails(keeperName, assistantEntryId, patch)
        if (stopReason) markFinalizingIfLive('KEEPER_STREAM_MESSAGE_DELTA')
        return null
      }
      if (event.name === 'KEEPER_STREAM_MESSAGE_STOP') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        clearPendingOasToolBlockIndexesForEntry(keeperName, assistantEntryId)
        markFinalizingIfLive('KEEPER_STREAM_MESSAGE_STOP')
        return null
      }
      if (event.name === 'KEEPER_STREAM_PING') {
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_STREAM_PING' }),
        )
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_START') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        const oasBlockIndex = asNumber(value?.index) ?? asNumber(value?.block_index)
        const contentType = asString(value?.content_type)
        const toolCallId = asString(value?.tool_call_id)
        const toolName = asString(value?.tool_call_name)
        if (contentType === 'text') {
          rememberOasTextBlockIndex(keeperName, assistantEntryId, oasBlockIndex)
        }
        if (toolCallId && toolName) {
          rememberOasToolBlockIndex(keeperName, assistantEntryId, toolCallId, oasBlockIndex)
        }
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_CONTENT_BLOCK_START' }),
        )
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_STOP') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        forgetOasToolBlockIndexByIndex(
          keeperName,
          assistantEntryId,
          asNumber(value?.index) ?? asNumber(value?.block_index),
        )
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_CONTENT_BLOCK_STOP' }),
        )
        return null
      }
      if (event.name === 'KEEPER_THINKING_DELTA') {
        const value = isRecord(event.value) ? event.value : null
        const delta = value
          ? (typeof value.delta === 'string'
              ? value.delta
              : typeof value.text === 'string'
                ? value.text
                : undefined)
          : typeof event.value === 'string'
            ? event.value
            : undefined
        const oasBlockIndex = value
          ? asNumber(value.index) ?? asNumber(value.block_index)
          : undefined
        if (delta) enqueueThinkingDelta(keeperName, assistantEntryId, delta, { oasBlockIndex })
        else {
          setAssistantStreamState(
            keeperName,
            assistantEntryId,
            'thinking',
            'streaming',
            keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_THINKING_DELTA' }),
          )
        }
        return null
      }
      if (event.name === 'KEEPER_STREAM_PROTOCOL_ERROR') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        forgetOasToolBlockIndexByIndex(
          keeperName,
          assistantEntryId,
          asNumber(value?.index) ?? asNumber(value?.block_index),
        )
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          streamProtocolMessage(event.value, 'stream protocol error'),
          asString(value?.tool_call_id),
        )
        return null
      }
      if (event.name === 'KEEPER_THINKING_SIGNATURE_DELTA') {
        if (!pendingThinkingDeltas.has(streamEntryKey(keeperName, assistantEntryId))) {
          setAssistantStreamState(
            keeperName,
            assistantEntryId,
            'thinking',
            'streaming',
            keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_THINKING_SIGNATURE_DELTA' }),
          )
        }
        return null
      }
      if (event.name === 'KEEPER_MEDIA_DELTA') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperClientObservedSseStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_MEDIA_DELTA' }),
        )
        return null
      }
      if (event.name === 'KEEPER_QUEUE_REQUEST') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'opening',
          'queued',
          keeperClientObservedSseStreamContract('queue_event', 'queue_request_event', { eventName: 'KEEPER_QUEUE_REQUEST' }),
        )
        return null
      }
      if (event.name === 'KEEPER_CHAT_QUEUED') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const queued = isRecord(event.value) ? event.value : null
        const receiptId = asString(queued?.receipt_id, '').trim()
        const revision = parseKeeperQueueRevision(queued?.queue_revision)
        const pendingCount = asNumber(queued?.pending_count)
        const inflightCount = asNumber(queued?.inflight_count)
        const recoveryRequiredCount = asNumber(queued?.recovery_required_count)
        const shutdownOperationId = (() => {
          const raw = queued?.shutdown_operation_id
          if (raw === null) return null
          if (typeof raw !== 'string') return undefined
          const normalized = raw.trim()
          return normalized.length > 0 ? normalized : undefined
        })()
        if (
          !isKeeperChatReceiptId(receiptId)
          || revision === undefined
          || typeof pendingCount !== 'number'
          || !Number.isSafeInteger(pendingCount)
          || pendingCount < 1
          || typeof inflightCount !== 'number'
          || !Number.isSafeInteger(inflightCount)
          || inflightCount < 0
          || typeof recoveryRequiredCount !== 'number'
          || !Number.isSafeInteger(recoveryRequiredCount)
          || recoveryRequiredCount < 0
        ) {
          return 'Keeper queue acceptance is missing its durable receipt metadata.'
        }
        if (shutdownOperationId === undefined) {
          return 'Keeper queue acceptance has invalid shutdown operation metadata.'
        }
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          delivery: 'queued',
          streamState: null,
          details: {
            ...(entry.details ?? {}),
            queueReceiptId: receiptId,
            queueShutdownOperationId: shutdownOperationId,
            queueRevision: revision,
            queuePendingCount: pendingCount,
            queueInflightCount: inflightCount,
            queueRecoveryRequiredCount: recoveryRequiredCount,
            queueState: 'pending',
          },
          streamContract: keeperClientObservedSseStreamContract('queue_event', 'queue_request_event', {
            eventName: 'KEEPER_CHAT_QUEUED',
            reason: `durable receipt ${receiptId}`,
          }),
        }))
        return null
      }
      if (event.name === 'KEEPER_CONTINUATION_CHECKPOINT') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const rawText = isRecord(event.value)
          ? asString(event.value.message, '')
          : ''
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          details: {
            ...(entry.details ?? {}),
            turnOutcome: 'continuation_checkpoint',
          },
          text: '',
          rawText: rawText || entry.rawText,
          delivery: 'queued',
          streamState: null,
          streamContract: keeperClientObservedSseStreamContract('queue_event', 'queue_request_event', {
            eventName: 'KEEPER_CONTINUATION_CHECKPOINT',
          }),
        }))
        return null
      }
      if (event.name === 'KEEPER_REQUEST_TERMINAL') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const terminal = isRecord(event.value) ? event.value : null
        const terminalRequestId = asString(terminal?.request_id, '').trim()
        const currentRequestId = activeStreamRequestId(keeperName)
        const status = asString(terminal?.status, '').trim()
        if (currentRequestId && terminalRequestId !== currentRequestId) {
          return null
        }
        if (!TERMINAL_REQUEST_STATUSES.has(status)) {
          return null
        }
        clearPendingOasToolBlockIndexesForEntry(keeperName, assistantEntryId)
        if (terminalRequestId) releaseActiveStreamRequestId(terminalRequestId)
        else clearActiveStreamRequestId(keeperName)
        const ok = terminal?.ok === true
        if (status === 'cancelled') {
          const message =
            asString(terminal?.message, '').trim() || KEEPER_MESSAGE_CANCELLED_TEXT
          updateThreadEntry(keeperName, assistantEntryId, entry => ({
            ...entry,
            text: KEEPER_MESSAGE_CANCELLED_TEXT,
            rawText: message,
            delivery: 'cancelled',
            streamState: null,
            error: null,
            streamContract: keeperClientObservedSseStreamContract('queue_event', 'backend_terminal_event', {
              eventName: 'KEEPER_REQUEST_TERMINAL',
              requestId: terminalRequestId,
            }),
          }))
          return null
        }
        const failed =
          !ok && ['error', 'lost'].includes(status)
        if (failed) {
          const message =
            asString(terminal?.message, '').trim() || 'Keeper request failed'
          updateThreadEntry(keeperName, assistantEntryId, entry => ({
            ...entry,
            text: entry.text || `Keeper request failed: ${message}`,
            rawText: entry.rawText || message,
            delivery: 'error',
            streamState: null,
            error: message,
            streamContract: keeperClientObservedSseStreamContract('queue_event', 'backend_terminal_event', {
              eventName: 'KEEPER_REQUEST_TERMINAL',
              requestId: terminalRequestId,
              reason: message,
            }),
          }))
          return message
        }
        if (status === 'done' && terminal?.ok !== false) {
          updateThreadEntry(keeperName, assistantEntryId, entry => {
            const delivery =
              entry.delivery === 'no_reply'
                || (entry.delivery === 'queued'
                  && keeperTurnOutcomeSuppressesReply(entry.details?.turnOutcome))
                ? entry.delivery
                : 'delivered'
            return {
              ...entry,
              delivery,
              streamState: null,
              error: null,
              streamContract: keeperClientObservedSseStreamContract('queue_event', 'backend_terminal_event', {
                eventName: 'KEEPER_REQUEST_TERMINAL',
                requestId: terminalRequestId,
              }),
            }
          })
        }
        return null
      }
      if (event.name === 'KEEPER_REPLY_DETAILS') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const details = normalizeKeeperConversationDetails(event.value)
        if (details) {
          updateThreadEntry(keeperName, assistantEntryId, entry => {
            const mergedDetails: KeeperConversationDetails = {
              ...(entry.details ?? {}),
              ...details,
              providerMessageId: details.providerMessageId ?? entry.details?.providerMessageId ?? null,
              modelUsed: details.modelUsed ?? entry.details?.modelUsed ?? null,
              stopReason: details.stopReason ?? entry.details?.stopReason ?? null,
              costUsd: details.costUsd ?? entry.details?.costUsd ?? null,
              usage: details.usage ?? entry.details?.usage ?? null,
            }
            const rawText = mergedDetails.replyText ?? entry.rawText ?? entry.text
            if (keeperTurnOutcomeSuppressesReply(mergedDetails.turnOutcome)) {
              return {
                ...entry,
                details: mergedDetails,
                turnRef: mergedDetails.turnRef ?? entry.turnRef,
                rawText,
                text: '',
                delivery: mergedDetails.turnOutcome === 'no_visible_reply' ? 'no_reply' : 'queued',
                streamState: null,
              }
            }
            const text = formatKeeperVisibleReply(rawText)
            const blocks = entry.blocks?.length ? entry.blocks : parseTextToChatBlocks(text)
            return {
              ...entry,
              details: mergedDetails,
              turnRef: mergedDetails.turnRef ?? entry.turnRef,
              rawText,
              text,
              blocks,
            }
          })
        }
      }
      return null
    case 'RUN_FINISHED':
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      clearPendingOasToolBlockIndexesForEntry(keeperName, assistantEntryId)
      clearPendingOasTextBlockIndex(keeperName, assistantEntryId)
      return null
    case 'RUN_ERROR':
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      clearPendingOasToolBlockIndexesForEntry(keeperName, assistantEntryId)
      clearPendingOasTextBlockIndex(keeperName, assistantEntryId)
      return typeof event.value === 'string'
        ? event.value
        : (isRecord(event.value) ? asString(event.value.message) : null) ?? 'Keeper stream failed'
    default:
      return null
  }
}
