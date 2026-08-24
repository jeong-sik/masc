import { keeperStreamContract } from './keeper-stream-contract'
import {
  operationDeliveryProvenance,
  isOperationDeliveryProvenance,
  toolCallDeliveryProvenance,
} from './keeper-delivery-provenance'
import {
  formatKeeperVisibleReply,
  keeperTurnOutcomeSuppressesReply,
  normalizeKeeperConversationDetails,
  normalizeKeeperExternalEffectTarget,
} from './keeper-message'
import { parseTextToChatBlocks } from './lib/chat-blocks'
import type { KeeperChatStreamEvent } from './api'
import type { KeeperConversationDetails } from './types'
import {
  appendAssistantDelta,
  appendThreadEntry,
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
  activeStreamEntryId,
  activeStreamOperationId,
  activeStreamRequestId,
  getStreamController,
  keeperThreads,
  keeperSending,
  keeperStreamStartedAt,
  liveSendOwnsRequest,
  setRecordValue,
} from './keeper-state'
import { isRecord, asNumber, asString } from './components/common/normalize'
import {
  nonBlankToolCallId,
  toolEntryIdFromCallId,
} from './tool-call-output-store'
import { STREAMING_THINKING_PREVIEW_CHARS } from './config/constants'
import { updateTrackedKeeperChatAssistantDraft } from './keeper-chat-operations-local'

const KEEPER_MESSAGE_CANCELLED_TEXT = '요청이 취소되었습니다.'
export const KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS = 100

const pendingAgentCoreToolBlockIndexes = new Map<string, number>()
const pendingAgentCoreTextBlockIndexes = new Map<string, number>()
type ScheduledFlushHandle = ReturnType<typeof setTimeout>
interface PendingThinkingState {
  chunks: string[]
  preview: string
  agentCoreBlockIndex?: number
  flushHandle: ScheduledFlushHandle | null
}

const pendingThinkingDeltas = new Map<string, PendingThinkingState>()

// AG-UI text messages are delivered at-least-once: a WS/SSE reconnect can
// replay a message's START/CONTENT/END, and an overlapping observer socket can
// re-deliver the same operation event. TEXT_MESSAGE_CONTENT carries a messageId
// but no per-chunk sequence, so the reducer keys idempotency on messageId — a
// completed message is never re-applied, and a re-START of the in-flight message
// restarts its buffer instead of appending on top. The terminal reply is an
// absolute snapshot (already idempotent), which is why only streaming text
// doubled before this guard.
interface TextMessageStreamState {
  activeMessageId: string | null
  endedMessageIds: Set<string>
}

const textMessageStreamStates = new Map<string, TextMessageStreamState>()

function streamEntryKey(keeperName: string, assistantEntryId: string): string {
  return `${keeperName}\u0000${assistantEntryId}`
}

function textMessageStreamState(keeperName: string, assistantEntryId: string): TextMessageStreamState {
  const key = streamEntryKey(keeperName, assistantEntryId)
  let state = textMessageStreamStates.get(key)
  if (!state) {
    state = { activeMessageId: null, endedMessageIds: new Set() }
    textMessageStreamStates.set(key, state)
  }
  return state
}

function textStreamMessageId(value: unknown): string | null {
  return typeof value === 'string' && value ? value : null
}

function clearTextMessageStreamState(keeperName: string, assistantEntryId: string): void {
  textMessageStreamStates.delete(streamEntryKey(keeperName, assistantEntryId))
}

function scheduleThinkingFlush(callback: () => void): ScheduledFlushHandle {
  return setTimeout(callback, KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS)
}

function cancelStreamFlush(handle: ScheduledFlushHandle): void {
  clearTimeout(handle)
}

function sameAgentCoreBlockIndex(left: number | undefined, right: number | undefined): boolean {
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
  const entry = (keeperThreads.value[keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return
  const deliveryKey = entry.deliveryProvenance?.delivery_key
  if (deliveryKey?.kind !== 'operation') return
  updateTrackedKeeperChatAssistantDraft(deliveryKey.operation_id, entry)
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
      agentCoreBlockIndex: pending.agentCoreBlockIndex,
    })
    persistActiveAssistantDraft(keeperName, assistantEntryId)
    return
  }
  pendingThinkingDeltas.delete(key)
  setAssistantThinkingSnapshot(keeperName, assistantEntryId, fullPendingThinkingText(pending), {
    agentCoreBlockIndex: pending.agentCoreBlockIndex,
  })
  persistActiveAssistantDraft(keeperName, assistantEntryId)
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
  meta: { agentCoreBlockIndex?: number } = {},
): void {
  if (!delta.trim()) return
  const key = streamEntryKey(keeperName, assistantEntryId)
  let pending = pendingThinkingDeltas.get(key)
  if (pending && !sameAgentCoreBlockIndex(pending.agentCoreBlockIndex, meta.agentCoreBlockIndex)) {
    flushPendingThinkingDeltas(keeperName, assistantEntryId)
    pending = undefined
  }
  if (!pending) {
    const text = delta.trimStart()
    pending = {
      chunks: [text],
      preview: text,
      agentCoreBlockIndex: meta.agentCoreBlockIndex,
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
  pendingAgentCoreToolBlockIndexes.clear()
  pendingAgentCoreTextBlockIndexes.clear()
  textMessageStreamStates.clear()
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
  const id = nonBlankToolCallId(toolCallId)
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

function agentCoreToolBlockKey(keeperName: string, assistantEntryId: string, toolCallId: string): string {
  return `${keeperName}\u0000${assistantEntryId}\u0000${toolCallId}`
}

function rememberAgentCoreToolBlockIndex(
  keeperName: string,
  assistantEntryId: string,
  toolCallId: string,
  index: number | undefined,
): void {
  const id = nonBlankToolCallId(toolCallId)
  if (!id || index === undefined) return
  pendingAgentCoreToolBlockIndexes.set(agentCoreToolBlockKey(keeperName, assistantEntryId, id), index)
}

function takeAgentCoreToolBlockIndex(
  keeperName: string,
  assistantEntryId: string,
  toolCallId: string,
): number | undefined {
  const key = agentCoreToolBlockKey(keeperName, assistantEntryId, toolCallId)
  const index = pendingAgentCoreToolBlockIndexes.get(key)
  pendingAgentCoreToolBlockIndexes.delete(key)
  return index
}

function forgetAgentCoreToolBlockIndexByIndex(
  keeperName: string,
  assistantEntryId: string,
  index: number | undefined,
): void {
  if (index === undefined) return
  const prefix = `${keeperName}\u0000${assistantEntryId}\u0000`
  for (const [key, value] of pendingAgentCoreToolBlockIndexes.entries()) {
    if (key.startsWith(prefix) && value === index) pendingAgentCoreToolBlockIndexes.delete(key)
  }
}

function clearPendingAgentCoreToolBlockIndexesForEntry(keeperName: string, assistantEntryId: string): void {
  const prefix = `${keeperName}\u0000${assistantEntryId}\u0000`
  for (const key of pendingAgentCoreToolBlockIndexes.keys()) {
    if (key.startsWith(prefix)) pendingAgentCoreToolBlockIndexes.delete(key)
  }
}

function rememberAgentCoreTextBlockIndex(
  keeperName: string,
  assistantEntryId: string,
  index: number | undefined,
): void {
  if (index === undefined) return
  pendingAgentCoreTextBlockIndexes.set(streamEntryKey(keeperName, assistantEntryId), index)
}

function takeAgentCoreTextBlockIndex(keeperName: string, assistantEntryId: string): number | undefined {
  const key = streamEntryKey(keeperName, assistantEntryId)
  const index = pendingAgentCoreTextBlockIndexes.get(key)
  pendingAgentCoreTextBlockIndexes.delete(key)
  return index
}

function clearPendingAgentCoreTextBlockIndex(keeperName: string, assistantEntryId: string): void {
  pendingAgentCoreTextBlockIndexes.delete(streamEntryKey(keeperName, assistantEntryId))
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

// Delta usage carries cumulative counters for only the fields the wire
// reported, and normalizeStreamUsage null-fills the base trio — so replacing
// the whole usage object would erase the start snapshot with nulls. Overlay
// the reported (non-null) counters onto what is already known, mirroring the
// producer-side replace-fold, and rederive the total from its parts.
function mergeStreamUsage(
  previous: KeeperConversationDetails['usage'],
  next: NonNullable<KeeperConversationDetails['usage']>,
): NonNullable<KeeperConversationDetails['usage']> {
  const merged: NonNullable<KeeperConversationDetails['usage']> = { ...(previous ?? {}) }
  for (const key of [
    'inputTokens',
    'outputTokens',
    'totalTokens',
    'cacheCreationInputTokens',
    'cacheReadInputTokens',
    'costUsd',
  ] as const) {
    const value = next[key]
    if (value !== null && value !== undefined) merged[key] = value
  }
  if (merged.inputTokens != null && merged.outputTokens != null) {
    merged.totalTokens = merged.inputTokens + merged.outputTokens
  }
  return merged
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
      usage: patch.usage
        ? mergeStreamUsage(entry.details?.usage, patch.usage)
        : entry.details?.usage ?? null,
      rawPayload: entry.details?.rawPayload,
    },
  }))
}

export function abortKeeperThreadMessage(name: string): KeeperThreadAbortResult | null {
  const keeperName = name.trim()
  if (!keeperName) return null
  const controller = getStreamController(keeperName)
  const entryId = activeStreamEntryId(keeperName)
  const operationId = activeStreamOperationId(keeperName)
  const requestId = activeStreamRequestId(keeperName)
  console.debug(`[keeper-stream] aborting stream for ${keeperName}${entryId ? ` (entry=${entryId})` : ''}${requestId ? ` request=${requestId}` : ''}`)
  if (controller) controller.abort()
  if (entryId) {
    flushPendingThinkingDeltas(keeperName, entryId)
    finalizeAssistantEntry(keeperName, entryId, {
      text: KEEPER_MESSAGE_CANCELLED_TEXT,
      rawText: KEEPER_MESSAGE_CANCELLED_TEXT,
      delivery: 'cancelled',
      streamState: null,
      error: null,
      timestamp: new Date().toISOString(),
    })
    clearPendingAgentCoreToolBlockIndexesForEntry(keeperName, entryId)
    clearPendingAgentCoreTextBlockIndex(keeperName, entryId)
  }
  if (operationId) clearActiveStream(keeperName, operationId)
  if (activeStreamEntryId(keeperName) === null) {
    setRecordValue(keeperSending, keeperName, false)
    setRecordValue(keeperStreamStartedAt, keeperName, null)
  }
  return {
    keeperName,
    entryId,
    requestId,
    controllerAborted: Boolean(controller),
  }
}

export interface KeeperOperationTurnEvent {
  operationId: string
  event: KeeperChatStreamEvent
}

type KeeperStreamEventSource =
  | { kind: 'direct' }
  | { kind: 'operation'; operationId: string }

/** Apply a server-pushed operation event only to the assistant bubble carrying
 * the exact operation id. Another browser can synthesize the bubble and later
 * fold it into the committed transcript using the same durable identity. */
export function applyKeeperOperationTurnEvent(
  name: string,
  operation: KeeperOperationTurnEvent,
): string | null {
  const keeperName = name.trim()
  const operationId = operation.operationId.trim()
  if (!keeperName || !operationId) return null

  // The server broadcasts every operation event to every session, including the
  // one that issued the send and is already applying the same turn off its own
  // response stream. [delivery] cannot tell the two apart: the direct stream
  // stamps the accepted operation id onto the bubble it is streaming into
  // (keeper-actions [stampPlaceholderRequestId]) and leaves it in 'streaming',
  // which is exactly the state this function treats as "still open, keep
  // writing". Both transports carry the same event: one Option.iter in
  // server_routes_http_keeper_stream hands a single AG-UI event to
  // Keeper_chat_broadcast.operation_event and publish_operation_live_event, so
  // the deltas are byte-identical and TEXT_MESSAGE_CONTENT has no per-chunk
  // sequence to dedupe on (messageId alone cannot: it is per message, not per
  // chunk). Applying both to one bubble appends twice, and the broadcast copy
  // starts after the direct stream has already written some deltas, so the two
  // runs sit out of phase and the operator reads interleaved fragments
  // ("오퍼레이터가 비" + "레이터가 비유/").
  // Live-send ownership already records which request this session is
  // streaming itself, so consult that rather than inferring it from state.
  if (liveSendOwnsRequest(operationId)) return null

  const entries = keeperThreads.value[keeperName] ?? []
  const matched = [...entries].reverse().find(
    entry => entry.role === 'assistant'
      && isOperationDeliveryProvenance(
        entry.deliveryProvenance,
        operationId,
        'terminal_assistant',
      ),
  )
  if (
    matched
    && matched.delivery !== 'queued'
    && matched.delivery !== 'sending'
    && matched.delivery !== 'streaming'
    && matched.delivery !== 'interrupted'
  ) {
    return null
  }
  const entryId = matched?.id ?? `operation-turn-${operationId}`

  if (!matched) {
    appendThreadEntry(keeperName, {
      id: entryId,
      role: 'assistant',
      source: 'direct_assistant',
      label: keeperName,
      text: '',
      rawText: null,
      timestamp: null,
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_assistant'),
      delivery: 'sending',
      streamState: 'opening',
      streamContract: keeperStreamContract(
        'sse_event',
        'backend_stream_event',
        { eventName: 'keeper_chat_operation_event', requestId: operationId },
      ),
      details: null,
    })
  } else if (matched.delivery === 'queued') {
    updateThreadEntry(keeperName, entryId, entry => ({
      ...entry,
      text: '',
      rawText: null,
      delivery: 'sending',
      streamState: 'opening',
    }))
  }

  const error = applyKeeperStreamEvent(
    keeperName,
    entryId,
    operation.event,
    { kind: 'operation', operationId },
  )
  if (error) {
    finalizeAssistantEntry(keeperName, entryId, {
      text: `Keeper request failed: ${error}`,
      rawText: error,
      delivery: 'error',
      streamState: null,
      error,
      timestamp: new Date().toISOString(),
    })
  }
  return error
}

export function applyKeeperStreamEvent(
  keeperName: string,
  assistantEntryId: string,
  event: KeeperChatStreamEvent,
  source: KeeperStreamEventSource = { kind: 'direct' },
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
        streamContract: keeperStreamContract('sse_event', 'backend_stream_event', { eventName }),
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
        keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'RUN_STARTED' }),
      )
      return null
    case 'TEXT_MESSAGE_START': {
      const messageId = textStreamMessageId(event.messageId)
      const streamState = textMessageStreamState(keeperName, assistantEntryId)
      if (messageId !== null && streamState.endedMessageIds.has(messageId)) {
        // Replay of a completed message: the transcript already holds its text.
        return null
      }
      if (messageId !== null && messageId === streamState.activeMessageId) {
        // Duplicate in-flight START (reconnect/observer replay): restart this
        // message's buffer so re-sent content re-accumulates identically instead
        // of appending on top of the partial text already shown.
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          text: '',
          rawText: '',
        }))
      }
      streamState.activeMessageId = messageId
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
        keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'TEXT_MESSAGE_START' }),
      )
      return null
    }
    case 'TEXT_MESSAGE_CONTENT': {
      const messageId = textStreamMessageId(event.messageId)
      if (messageId !== null) {
        const streamState = textMessageStreamState(keeperName, assistantEntryId)
        if (streamState.endedMessageIds.has(messageId)) {
          // Content re-delivered after the message ended: already rendered.
          return null
        }
        if (streamState.activeMessageId !== null && streamState.activeMessageId !== messageId) {
          // Content for a different message than the one in flight: stale copy.
          return null
        }
        // Adopt the id when START was coalesced away by the guards above.
        streamState.activeMessageId = messageId
      }
      applyTextDelta(event.delta)
      return null
    }
    case 'TEXT_MESSAGE_END': {
      const messageId = textStreamMessageId(event.messageId)
      if (messageId !== null) {
        const streamState = textMessageStreamState(keeperName, assistantEntryId)
        streamState.endedMessageIds.add(messageId)
        if (streamState.activeMessageId === messageId) streamState.activeMessageId = null
      }
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      clearPendingAgentCoreToolBlockIndexesForEntry(keeperName, assistantEntryId)
      markFinalizingIfLive('TEXT_MESSAGE_END')
      return null
    }
    case 'TOOL_CALL_START': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = nonBlankToolCallId(event.toolCallId)
      const toolName = event.toolCallName?.trim()
      if (!toolCallId || !toolName) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_START missing toolCallId or toolCallName',
        )
        return null
      }
      promoteAssistantTextToProgress(keeperName, assistantEntryId, {
        agentCoreBlockIndex: takeAgentCoreTextBlockIndex(keeperName, assistantEntryId),
      })
      const assistantEntry = (keeperThreads.value[keeperName] ?? [])
        .find(entry => entry.id === assistantEntryId)
      const toolSteps = assistantEntry?.traceSteps?.filter(step => step.kind === 'tool') ?? []
      const existingOrdinal = toolSteps.findIndex(step => step.toolCallId === toolCallId)
      const toolOrdinal = existingOrdinal >= 0 ? existingOrdinal : toolSteps.length
      const deliveryProvenance = toolCallDeliveryProvenance(
        assistantEntry?.deliveryProvenance,
        toolCallId,
        toolOrdinal,
      )
      appendAssistantToolTraceStep(keeperName, assistantEntryId, {
        toolCallId,
        name: toolName,
        agentCoreBlockIndex: takeAgentCoreToolBlockIndex(keeperName, assistantEntryId, toolCallId),
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
        deliveryProvenance,
        delivery: 'streaming',
        streamState: 'streaming',
        streamContract: keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'TOOL_CALL_START' }),
        details: null,
      })
      return null
    }
    case 'TOOL_CALL_ARGS': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = nonBlankToolCallId(event.toolCallId)
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
      const toolCallId = nonBlankToolCallId(event.toolCallId)
      if (!toolCallId) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_END missing toolCallId',
        )
        return null
      }
      if (toolCallId) {
        updateThreadEntry(keeperName, toolEntryIdFromCallId(toolCallId), entry => {
          if (entry.delivery === 'delivered') return entry
          return {
            ...entry,
            delivery: 'streaming',
            streamState: 'streaming',
            streamContract: keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'TOOL_CALL_END' }),
          }
        })
      }
      return null
    }
    case 'CUSTOM': {
      const customEventName: string = event.name
      if (event.name === 'KEEPER_TOOL_RESULT_READY') {
        const toolCallId = nonBlankToolCallId(event.value.tool_call_id)
        if (!toolCallId) return 'KEEPER_TOOL_RESULT_READY missing tool_call_id'
        markAssistantToolTraceEnded(keeperName, assistantEntryId, toolCallId)
        updateThreadEntry(keeperName, toolEntryIdFromCallId(toolCallId), entry => ({
          ...entry,
          delivery: 'delivered',
          streamState: null,
          streamContract: keeperStreamContract(
            'sse_event',
            'backend_stream_event',
            { eventName: 'KEEPER_TOOL_RESULT_READY' },
          ),
        }))
        return null
      }
      if (event.name === 'KEEPER_CHAT_OPERATION_ACCEPTED') {
        const operationId = event.value.operation_id.trim()
        if (!operationId) return 'Keeper operation acceptance is missing operation_id.'
        const queued = event.value.state === 'Queued'
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          deliveryProvenance: operationDeliveryProvenance(
            operationId,
            'terminal_assistant',
          ),
          text: queued ? 'Queued' : entry.text,
          rawText: queued ? 'Queued' : entry.rawText,
          delivery: queued ? 'queued' : 'sending',
          streamState: queued ? null : 'opening',
          streamContract: keeperStreamContract(
            'sse_event',
            'backend_stream_event',
            { eventName: 'KEEPER_CHAT_OPERATION_ACCEPTED', requestId: operationId },
          ),
        }))
        return null
      }
      if (event.name === 'KEEPER_CONNECTED') {
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_CONNECTED' }),
        )
        return null
      }
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
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_STREAM_MESSAGE_START' }),
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
        clearPendingAgentCoreToolBlockIndexesForEntry(keeperName, assistantEntryId)
        markFinalizingIfLive('KEEPER_STREAM_MESSAGE_STOP')
        return null
      }
      if (event.name === 'KEEPER_STREAM_PING') {
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_STREAM_PING' }),
        )
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_START') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        const agentCoreBlockIndex = asNumber(value?.index)
        const contentType = asString(value?.content_type)
        const toolCallId = asString(value?.tool_call_id)
        const toolName = asString(value?.tool_call_name)
        if (contentType === 'text') {
          rememberAgentCoreTextBlockIndex(keeperName, assistantEntryId, agentCoreBlockIndex)
        }
        if (toolCallId && toolName) {
          rememberAgentCoreToolBlockIndex(keeperName, assistantEntryId, toolCallId, agentCoreBlockIndex)
        }
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_CONTENT_BLOCK_START' }),
        )
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_STOP') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        forgetAgentCoreToolBlockIndexByIndex(
          keeperName,
          assistantEntryId,
          asNumber(value?.index),
        )
        setAssistantStreamState(
          keeperName,
          assistantEntryId,
          'streaming',
          'streaming',
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_CONTENT_BLOCK_STOP' }),
        )
        return null
      }
      if (event.name === 'KEEPER_THINKING_DELTA') {
        const value = isRecord(event.value) ? event.value : null
        const delta = value && typeof value.delta === 'string'
          ? value.delta
          : undefined
        const agentCoreBlockIndex = value ? asNumber(value.index) : undefined
        if (delta) enqueueThinkingDelta(keeperName, assistantEntryId, delta, { agentCoreBlockIndex })
        else {
          setAssistantStreamState(
            keeperName,
            assistantEntryId,
            'thinking',
            'streaming',
            keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_THINKING_DELTA' }),
          )
        }
        return null
      }
      if (event.name === 'KEEPER_STREAM_PROTOCOL_ERROR') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        forgetAgentCoreToolBlockIndexByIndex(
          keeperName,
          assistantEntryId,
          asNumber(value?.index),
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
            keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_THINKING_SIGNATURE_DELTA' }),
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
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_MEDIA_DELTA' }),
        )
        return null
      }
      if (event.name === 'KEEPER_CONTINUATION_CHECKPOINT') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const rawText = isRecord(event.value)
          ? asString(event.value.message, '')
          : ''
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          blocks: [
            ...(entry.blocks ?? []).filter(block => block.t !== 'status'),
            { t: 'status', kind: 'continuation_checkpoint' },
          ],
          details: {
            ...(entry.details ?? {}),
            turnOutcome: 'continuation_checkpoint',
          },
          text: '',
          rawText: rawText || entry.rawText,
          delivery: 'delivered',
          streamState: null,
          streamContract: keeperStreamContract('sse_event', 'backend_terminal_event', {
            eventName: 'KEEPER_CONTINUATION_CHECKPOINT',
          }),
        }))
        return null
      }
      if (event.name === 'KEEPER_EXTERNAL_EFFECT_COMPLETED') {
        // The reply was already delivered by a terminal surface post, so
        // there is no assistant text — finalize as a terminal control status
        // instead of leaving the entry streaming. The event value names the
        // real delivery target.
        const externalEffectTarget = normalizeKeeperExternalEffectTarget(
          event.value.target,
        )
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          details: {
            ...(entry.details ?? {}),
            turnOutcome: 'external_effect_completed',
            externalEffectTarget,
          },
          text: '',
          delivery: 'delivered',
          streamState: null,
          streamContract: keeperStreamContract('sse_event', 'backend_terminal_event', {
            eventName: 'KEEPER_EXTERNAL_EFFECT_COMPLETED',
          }),
        }))
        return null
      }
      if (event.name === 'KEEPER_REPLY_DETAILS') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const details = normalizeKeeperConversationDetails(event.value)
        if (
          !details
          || typeof event.value.reply !== 'string'
          || !details.turnOutcome
          || !details.turnRef
        ) {
          return 'Keeper reply details event is malformed.'
        }
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
        return null
      }
      // A name this build does not draw is not a reason to end the reply.
      // keeper-actions.ts throws on any string returned here, so a server that
      // adds an event the client has not learned yet stops the stream and the
      // answer never lands -- which is what KEEPER_TOOL_APPROVAL_REQUESTED did
      // on 2026-08-24, after #30059 added it on the server and here. The
      // events this file does draw each return null above; reaching this line
      // means the frame carried nothing this view renders, so it is dropped
      // and named once for whoever wires it next.
      console.debug('keeper stream: no view for custom event', customEventName)
      return null
    }
    case 'RUN_FINISHED':
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      clearPendingAgentCoreToolBlockIndexesForEntry(keeperName, assistantEntryId)
      clearPendingAgentCoreTextBlockIndex(keeperName, assistantEntryId)
      clearTextMessageStreamState(keeperName, assistantEntryId)
      if (source.kind !== 'operation') return null
      updateThreadEntry(keeperName, assistantEntryId, entry => {
        if (!isOperationDeliveryProvenance(
          entry.deliveryProvenance,
          source.operationId,
          'terminal_assistant',
        )) {
          return entry
        }
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
          streamContract: keeperStreamContract(
            'sse_event',
            'backend_terminal_event',
            { eventName: 'RUN_FINISHED', requestId: source.operationId },
          ),
        }
      })
      return null
    case 'RUN_ERROR':
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      clearPendingAgentCoreToolBlockIndexesForEntry(keeperName, assistantEntryId)
      clearPendingAgentCoreTextBlockIndex(keeperName, assistantEntryId)
      clearTextMessageStreamState(keeperName, assistantEntryId)
      return asString(event.message, '').trim() || 'Keeper stream failed'
    default:
      return 'Unsupported Keeper stream event'
  }
}
