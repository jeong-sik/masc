import { sameKeeperResponseOwner, type KeeperResponseOwner, initialKeeperResponseState, reduceKeeperResponse, acknowledgeKeeperResponseSequence, type KeeperResponseDecision, type KeeperResponseEvent } from './lib/keeper-response-state'
import { keeperStreamContract } from './keeper-stream-contract'
import {
  sameDeliveryKey,
  toolDeliveryBelongsToProducer,
  operationDeliveryProvenance,
  isOperationDeliveryProvenance,
} from './keeper-delivery-provenance'
import {
  keeperTurnOutcomeSuppressesReply,
  normalizeKeeperConversationDetails,
  normalizeKeeperExternalEffectTarget,
} from './keeper-message'
import { projectFinalReplyBlocks, producerReplyBlocks } from './lib/keeper-reply-block-projection'
import type { KeeperChatStreamEvent } from './api'
import type { KeeperConversationEntry, KeeperConversationDetails } from './types'
import {
  appendAssistantDelta,
  appendThreadEntry,
  mergeServerHistoryEntries,
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
  upsertKeeperToolApproval,
  dropKeeperToolApproval,
} from './keeper-state'
import { isRecord, asNumber, asString } from './components/common/normalize'
import {
  nonBlankToolCallId,
} from './tool-call-output-store'
import { updateTrackedKeeperChatAssistantDraft } from './keeper-chat-operations-local'

export const KEEPER_THINKING_DELTA_FLUSH_INTERVAL_MS = 100

const pendingAgentCoreTextBlockIndexes = new Map<string, number>()
type ScheduledFlushHandle = ReturnType<typeof setTimeout>
interface PendingThinkingState {
  responseOwner?: KeeperResponseOwner
  chunks: string[]
  agentCoreBlockIndex?: number
  flushHandle: ScheduledFlushHandle | null
  authoritative: boolean
}

const pendingThinkingDeltas = new Map<string, PendingThinkingState>()
function sameToolParent(
  parent: KeeperConversationEntry | undefined,
  tool: KeeperConversationEntry,
): boolean {
  if (!parent) return false
  const parentKey = parent.deliveryProvenance?.delivery_key
  const toolKey = tool.toolOwnerKey ?? tool.deliveryProvenance?.delivery_key
  return parentKey ? toolKey !== undefined && (tool.toolOwnerKey !== undefined
    ? sameDeliveryKey(parentKey, tool.toolOwnerKey) : toolDeliveryBelongsToProducer(parentKey, toolKey))
    : tool.toolOwnerKey === undefined && (tool.toolParentEntryId === parent.id || tool.toolParentCandidates?.includes(parent.id) === true)
}

function convergeAcknowledgedTool(keeperName: string, parent: KeeperConversationEntry,
  resource: KeeperConversationEntry, binding: NonNullable<KeeperConversationEntry['toolTranscriptBindings']>[number]): void {
  const entries = keeperThreads.value[keeperName] ?? []
  const canonical = entries.filter(entry => entry.role === 'tool' && entry.id !== resource.id
    && entry.deliveryProvenance?.transcript_slot.kind === 'tool_call'
    && entry.deliveryProvenance.transcript_slot.execution_id === binding.executionId
    && entry.deliveryProvenance.transcript_slot.ordinal === binding.ordinal
    && sameDeliveryKey(entry.deliveryProvenance.delivery_key, binding.deliveryKey))
  if (canonical.length > 1 || canonical.some(entry => entry.toolOccurrenceQuarantined
    || entry.toolParentCandidates?.length || entry.toolParentEntryId !== undefined && entry.toolParentEntryId !== parent.id)) {
    updateThreadEntry(keeperName, parent.id, entry => ({ ...entry, toolObservationAuthority: 'unavailable',
      error: 'Acknowledged tool transcript has conflicting parent associations' }))
  } else if (canonical[0]) {
    const durable = canonical[0]
    // Retain the full inventory while the shared reconciler folds only the
    // acknowledged fact and its explicit parent/occurrence observations.
    mergeServerHistoryEntries(keeperName, [durable, ...entries.filter(entry => entry.id !== durable.id)])
  }
}

function flushAutonomousSaying(keeperName: string, entryId: string, observationOnly: boolean): void {
  updateThreadEntry(keeperName, entryId, entry => {
    const pending = entry.autonomousSayingReplay
    if (!pending) return entry
    return { ...entry, autonomousSayingReplay: undefined,
      ...(pending.text ? { traceSteps: [...(entry.traceSteps ?? []), {
        kind: 'progress' as const, text: pending.text,
        ...(pending.timestamp === undefined ? {} : { ts: new Date(pending.timestamp * 1000).toISOString() }),
      }] } : {}),
      ...(observationOnly ? {} : { text: '', rawText: '', blocks: [], replyTextProjection: undefined, replyBlockSource: undefined }),
    }
  })
}

function recordAutonomousSaying(keeperName: string, entryId: string,
  event: Extract<KeeperChatStreamEvent, { type: 'TEXT_MESSAGE_CONTENT' }>, sequence: number, observationOnly: boolean): void {
  if (typeof event.delta !== 'string' || event.delta.length === 0) return
  const owner = event.textResponse ? Object.freeze({ ...event.textResponse }) : null
  const scope = event.textStreamScope ?? null
  const before = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === entryId)
  const pending = before?.autonomousSayingReplay
  if (pending && (!sameKeeperResponseOwner(pending.owner ?? undefined, owner ?? undefined) || pending.scope !== scope)) {
    flushAutonomousSaying(keeperName, entryId, observationOnly)
  }
  updateThreadEntry(keeperName, entryId, entry => ({ ...entry, autonomousTraceBoundary: sequence,
    autonomousSayingReplay: Object.freeze({ text: (entry.autonomousSayingReplay?.text ?? '') + event.delta,
      timestamp: entry.autonomousSayingReplay?.timestamp ?? event.timestamp, owner, scope }),
  }))
}

function occurrenceContains(
  occurrence: KeeperConversationEntry['toolOccurrence'], scope: number, index: number,
): boolean {
  if (!occurrence) return false
  return occurrence.kind === 'identified' ? occurrence.streamScope === scope && occurrence.blockIndex === index
    : occurrence.coordinates.some(value => value.streamScope === scope && value.blockIndex === index)
}

function streamedToolOccurrenceId(
  keeperName: string,
  assistantEntryId: string,
  streamScope: number,
  blockIndex: number,
): string {
  const entries = keeperThreads.value[keeperName] ?? []
  const parent = entries.find(entry => entry.id === assistantEntryId)
  const existing = entries.find(entry => entry.role === 'tool' && sameToolParent(parent, entry)
    && occurrenceContains(entry.toolOccurrence, streamScope, blockIndex))
  // This is a row key only. Occurrence admission uses typed parent identity and
  // server coordinates, so replacing the parent row does not change ownership.
  return existing?.id ?? `tool-delivery-${assistantEntryId}-stream-${streamScope}-block-${blockIndex}`
}

function isToolOccurrenceQuarantined(
  keeperName: string,
  assistantEntryId: string,
  toolOccurrenceId: string,
): boolean {
  const entries = keeperThreads.value[keeperName] ?? []
  const parent = entries.find(entry => entry.id === assistantEntryId)
  return entries.some(entry => entry.role === 'tool' && entry.id === toolOccurrenceId
    && sameToolParent(parent, entry) && entry.toolOccurrenceQuarantined === true)
}

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

function resetUnfinishedRuntimeAttempt(
  keeperName: string,
  assistantEntryId: string,
): void {
  const key = streamEntryKey(keeperName, assistantEntryId)
  const pending = pendingThinkingDeltas.get(key)
  if (pending?.flushHandle) cancelStreamFlush(pending.flushHandle)
  pendingThinkingDeltas.delete(key)
  clearPendingAgentCoreTextBlockIndex(keeperName, assistantEntryId)
  clearTextMessageStreamState(keeperName, assistantEntryId)
  updateThreadEntry(keeperName, assistantEntryId, entry => ({
    ...entry,
    text: '',
    rawText: '',
    replyTextProjection: undefined,
    replyBlockSource: undefined,
    blocks: producerReplyBlocks(entry).filter(block => (
      block.t !== 'p' && block.t !== 'thinking'
    )),
    traceSteps: (entry.traceSteps ?? []).filter(step => step.kind === 'tool'),
    details: entry.details
      ? {
          ...entry.details,
          providerMessageId: null,
          modelUsed: null,
          stopReason: null,
          usage: null,
          costUsd: null,
        }
      : entry.details,
    streamState: 'streaming',
    delivery: 'streaming',
    streamContract: keeperStreamContract(
      'sse_event',
      'backend_stream_event',
      { eventName: 'KEEPER_RUNTIME_ATTEMPT_STARTED' },
    ),
  }))
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

function fullPendingThinkingText(pending: PendingThinkingState): string {
  return pending.chunks.join('')
}

const applyingStreamFrames = new Set<string>()

function persistActiveAssistantDraft(keeperName: string, assistantEntryId: string): void {
  if (applyingStreamFrames.has(streamEntryKey(keeperName, assistantEntryId))) return
  const entry = (keeperThreads.value[keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return
  const deliveryKey = entry.deliveryProvenance?.delivery_key
  if (deliveryKey?.kind !== 'operation') return
  updateTrackedKeeperChatAssistantDraft(deliveryKey.operation_id, entry, keeperThreads.value[keeperName] ?? [])
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
  const before = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)
  const preserveActivity = (): void => {
    if (!pending.authoritative && before) updateThreadEntry(keeperName, assistantEntryId, entry => ({
      ...entry, streamState: before.streamState, delivery: before.delivery,
    }))
  }
  if (mode === 'preview') {
    setAssistantThinkingSnapshot(keeperName, assistantEntryId, fullPendingThinkingText(pending), {
      agentCoreBlockIndex: pending.agentCoreBlockIndex,
      responseOwner: pending.responseOwner,
    })
    preserveActivity()
    persistActiveAssistantDraft(keeperName, assistantEntryId)
    return
  }
  pendingThinkingDeltas.delete(key)
  setAssistantThinkingSnapshot(keeperName, assistantEntryId, fullPendingThinkingText(pending), {
    agentCoreBlockIndex: pending.agentCoreBlockIndex,
      responseOwner: pending.responseOwner,
  })
  preserveActivity()
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
  meta: { agentCoreBlockIndex?: number; responseOwner?: KeeperResponseOwner; authoritative?: boolean } = {},
): void {
  if (delta.length === 0) return
  const key = streamEntryKey(keeperName, assistantEntryId)
  let pending = pendingThinkingDeltas.get(key)
  if (pending && (!sameKeeperResponseOwner(pending.responseOwner, meta.responseOwner)
    || !sameAgentCoreBlockIndex(pending.agentCoreBlockIndex, meta.agentCoreBlockIndex)
    || pending.authoritative !== (meta.authoritative ?? true))) {
    flushPendingThinkingDeltas(keeperName, assistantEntryId)
    pending = undefined
  }
  if (!pending) {
    const entry = (keeperThreads.value[keeperName] ?? []).find(candidate => candidate.id === assistantEntryId)
    const last = entry?.traceSteps?.at(-1)
    const prefix = last?.kind === 'think' && sameKeeperResponseOwner(last.responseOwner, meta.responseOwner)
      && sameAgentCoreBlockIndex(last.agentCoreBlockIndex, meta.agentCoreBlockIndex) ? last.text : ''
    const text = `${prefix}${delta}`
    pending = {
      responseOwner: meta.responseOwner,
      chunks: [text],
      agentCoreBlockIndex: meta.agentCoreBlockIndex,
      flushHandle: null,
      authoritative: meta.authoritative ?? true,
    }
    pendingThinkingDeltas.set(key, pending)
  } else {
    pending.chunks.push(delta)
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
  target: {
    toolOccurrenceId?: string
    authoritativeQuarantine?: boolean
  } = {},
): void {
  updateThreadEntry(keeperName, assistantEntryId, entry => {
    return { ...entry, error: message }
  })
  const occurrenceId = target.toolOccurrenceId?.trim()
  if (!occurrenceId) return
  const toolEntry = (keeperThreads.value[keeperName] ?? []).find(entry => (
    entry.role === 'tool'
    && entry.id === occurrenceId
    && sameToolParent((keeperThreads.value[keeperName] ?? []).find(parent => parent.id === assistantEntryId), entry)
    && (target.authoritativeQuarantine || entry.executionId == null)
  ))
  if (!toolEntry) return
  markAssistantToolTraceErrored(keeperName, assistantEntryId, toolEntry.id)
  updateThreadEntry(keeperName, toolEntry.id, entry => ({
    ...entry,
    toolCallEnded: target.authoritativeQuarantine ? true : entry.toolCallEnded,
    ...(target.authoritativeQuarantine ? { toolOccurrenceQuarantined: true as const } : {}),
    delivery: 'error',
    streamState: null,
    error: message,
  }))
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
      // Preserve partial content; only the response connection has stopped.
      delivery: 'interrupted',
      streamState: null,
      error: null,
      timestamp: new Date().toISOString(),
    })
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
  sequence?: number
  event: KeeperChatStreamEvent
}

type KeeperStreamEventSource =
  | { kind: 'direct' }
  | { kind: 'operation'; operationId: string; sequence?: number; observationOnly?: true }
  | { kind: 'autonomous'; turnRef: string; sequence: number; observationOnly?: true }

function isToolObservation(event: KeeperChatStreamEvent): boolean {
  switch (event.type) {
    case 'TOOL_CALL_START':
    case 'TOOL_CALL_ARGS':
    case 'TOOL_CALL_END': return true
    case 'CUSTOM': return event.name === 'KEEPER_TOOL_RESULT_READY' || event.name === 'KEEPER_TOOL_TRANSCRIPT_COMMITTED'
    default: return false
  }
}

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
  // A persisted request_failure normalizes to a system-role row with the
  // same terminal_result provenance: the operation it terminated is
  // finished even though the row is not an assistant bubble, so a late
  // event for it must be ignored instead of opening a new bubble.
  const matched = [...entries].reverse().find(
    entry =>
      (entry.role === 'assistant' || entry.delivery === 'request_failure')
      && isOperationDeliveryProvenance(
        entry.deliveryProvenance,
        operationId,
        'terminal_result',
      ),
  )
  const outsideLiveDelivery = matched !== undefined
    && matched.delivery !== 'queued'
    && matched.delivery !== 'sending'
    && matched.delivery !== 'streaming'
  const observationOnly = outsideLiveDelivery && isToolObservation(operation.event)
  if (outsideLiveDelivery && matched.delivery !== 'interrupted' && !observationOnly) return null
  if (observationOnly && matched.role !== 'assistant') return null
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
      deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'),
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
    { kind: 'operation', operationId, sequence: operation.sequence, ...(observationOnly ? { observationOnly: true as const } : {}) },
  )
  if (error && observationOnly) {
    recordStreamProtocolError(keeperName, entryId, error)
  } else if (error) {
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

/** Autonomous ownership is the durable turn reference, never a user request. */
export function applyKeeperAutonomousTurnEvent(keeperName: string, turnRef: string, sequence: number,
  event: KeeperChatStreamEvent): string | null {
  const entries = keeperThreads.value[keeperName] ?? []
  const existing = entries.find(entry => entry.source === 'autonomous_turn' && entry.turnRef === turnRef)
  const entryId = existing?.id ?? `autonomous-${turnRef}`
  const settled = existing !== undefined && existing.delivery !== 'sending' && existing.delivery !== 'streaming'
  const observationOnly = settled && (isToolObservation(event) || event.type === 'TEXT_MESSAGE_CONTENT' || event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR' || event.type === 'CUSTOM'
    && (event.name === 'KEEPER_THINKING_DELTA' || event.name === 'KEEPER_STREAM_PROTOCOL_ERROR'))
  if (settled && !observationOnly) return null
  if (!existing) appendThreadEntry(keeperName, {
    id: entryId, role: 'assistant', source: 'autonomous_turn', label: keeperName,
    turnRef, text: '', rawText: null, deliveryProvenance: null, timestamp: event.timestamp === undefined ? null : new Date(event.timestamp * 1000).toISOString(),
    delivery: 'sending', streamState: 'opening', details: null,
    streamContract: keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'keeper_turn_stream_event' }),
  })
  const error = applyKeeperStreamEvent(keeperName, entryId, event,
    { kind: 'autonomous', turnRef, sequence, ...(observationOnly ? { observationOnly: true as const } : {}) })
  if (error && observationOnly) recordStreamProtocolError(keeperName, entryId, error)
  else if (error) finalizeAssistantEntry(keeperName, entryId, {
    delivery: 'error', streamState: null, error, timestamp: new Date().toISOString(),
  })
  return error
}

function admitResponseEvent(
  keeperName: string,
  assistantEntryId: string,
  event: KeeperResponseEvent,
): KeeperResponseDecision {
  const entry = (keeperThreads.value[keeperName] ?? []).find(candidate => candidate.id === assistantEntryId)
  const before = entry?.responseState ?? initialKeeperResponseState
  if (!entry) return { state: before, accepted: false, advanced: false, authoritative: false }
  const decision = reduceKeeperResponse(before, event)
  if (!decision.accepted) return decision
  if (decision.advanced) {
    flushPendingThinkingDeltas(keeperName, assistantEntryId)
    clearPendingAgentCoreTextBlockIndex(keeperName, assistantEntryId)
    clearTextMessageStreamState(keeperName, assistantEntryId)
  }
  if (decision.state !== before) updateThreadEntry(keeperName, assistantEntryId, current => ({
    ...current,
    responseState: decision.state,
    ...(decision.advanced && decision.authoritative ? {
      replyBlockSource: undefined,
      streamState: 'opening' as const,
      details: current.details ? { ...current.details, providerMessageId: null, modelUsed: null,
        stopReason: null, usage: null, costUsd: null } : current.details,
    } : {}),
  }))
  persistActiveAssistantDraft(keeperName, assistantEntryId)
  return decision
}

export function applyKeeperStreamEvent(
  keeperName: string,
  assistantEntryId: string,
  event: KeeperChatStreamEvent,
  source: KeeperStreamEventSource = { kind: 'direct' },
): string | null {
  const existing = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)
  if (!existing) return null
  const beforeSequence = existing.responseState ?? initialKeeperResponseState
  const sequenced = acknowledgeKeeperResponseSequence(beforeSequence, source.kind !== 'direct' ? source.sequence : undefined)
  if (!sequenced) return null
  const frameKey = streamEntryKey(keeperName, assistantEntryId)
  if (applyingStreamFrames.has(frameKey)) return 'Reentrant Keeper stream frame'
  applyingStreamFrames.add(frameKey)
  let failed = false
  const applyTextDelta = (payload: unknown, authoritative: boolean): void => {
    if (typeof payload !== 'string') return
    if (payload) {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const before = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)
      appendAssistantDelta(keeperName, assistantEntryId, payload)
      if (!authoritative && before) updateThreadEntry(keeperName, assistantEntryId, entry => ({
        ...entry, streamState: before.streamState, delivery: before.delivery,
      }))
      persistActiveAssistantDraft(keeperName, assistantEntryId)
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

  try {
  switch (event.type) {
    case 'RUN_STARTED':
      if (!admitResponseEvent(keeperName, assistantEntryId, { kind: 'started' }).accepted) return null
      setAssistantStreamState(
        keeperName,
        assistantEntryId,
        'opening',
        'sending',
        keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'RUN_STARTED' }),
      )
      return null
    case 'TEXT_MESSAGE_START': {
      const response = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.responseState
      if (response && (response.kind === 'unavailable' || response.floor || response.phase === 'terminal')) return null
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
      if (source.kind === 'autonomous' && source.observationOnly) {
        // Canonical history may arrive before journal replay. An observed
        // terminal journal boundary, however, closes saying for this turn.
        const response = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.responseState
        if (response?.kind === 'known' && response.phase === 'terminal') return null
        recordAutonomousSaying(keeperName, assistantEntryId, event, source.sequence, true)
        return null
      }

      const response = admitResponseEvent(keeperName, assistantEntryId, {
        kind: 'observe', owner: event.textResponse ?? null, scope: event.textStreamScope ?? null, source: 'body',
      })
      if (!response.accepted) return null
      const messageId = textStreamMessageId(event.messageId)
      if (!event.textResponse && messageId !== null) {
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
      if (source.kind === 'autonomous') recordAutonomousSaying(keeperName, assistantEntryId, event, source.sequence, false)
      applyTextDelta(event.delta, response.authoritative)
      return null
    }
    case 'TEXT_MESSAGE_END': {
      const response = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.responseState
      if (response && (response.kind === 'unavailable' || response.floor || response.phase === 'terminal')) return null
      const messageId = textStreamMessageId(event.messageId)
      if (messageId !== null) {
        const streamState = textMessageStreamState(keeperName, assistantEntryId)
        streamState.endedMessageIds.add(messageId)
        if (streamState.activeMessageId === messageId) streamState.activeMessageId = null
      }
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      markFinalizingIfLive('TEXT_MESSAGE_END')
      return null
    }
    case 'TOOL_CALL_START': {
      if ((keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.toolObservationAuthority === 'unavailable') {
        updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, error: 'Stored tool ownership is unavailable; authoritative recovery is required' }))
        return null
      }

      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = nonBlankToolCallId(event.toolCallId) ?? undefined
      const toolName = event.toolCallName?.trim()
      const toolOccurrenceId = streamedToolOccurrenceId(
        keeperName,
        assistantEntryId,
        event.toolStreamScope,
        event.toolCallBlockIndex,
      )
      if (!toolName) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_START missing toolCallName',
          { toolOccurrenceId },
        )
        return null
      }
      const assistantEntry = (keeperThreads.value[keeperName] ?? [])
        .find(entry => entry.id === assistantEntryId)
      const existingOccurrence = (keeperThreads.value[keeperName] ?? [])
        .find(entry => entry.id === toolOccurrenceId)
      if (existingOccurrence) {
        const providerIdConflict = toolCallId
          && existingOccurrence.toolCallId
          && existingOccurrence.toolCallId !== toolCallId
        if (existingOccurrence.label !== toolName || providerIdConflict) {
          recordStreamProtocolError(
            keeperName,
            assistantEntryId,
            'TOOL_CALL_START conflicts with an existing server occurrence',
            { toolOccurrenceId },
          )
        }
        return null
      }
      if (source.kind === 'autonomous') {
        flushAutonomousSaying(keeperName, assistantEntryId, source.observationOnly === true)
        updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, autonomousTraceBoundary: source.sequence }))
      }
      if (!(source.kind !== 'direct' && source.observationOnly)) {
        promoteAssistantTextToProgress(keeperName, assistantEntryId, {
          agentCoreBlockIndex: takeAgentCoreTextBlockIndex(keeperName, assistantEntryId),
        })
      }
      const agentCoreBlockIndex = event.toolCallBlockIndex
      const toolOwnerKey = assistantEntry?.deliveryProvenance?.delivery_key
      appendAssistantToolTraceStep(keeperName, assistantEntryId, {
        toolCallId,
        toolOccurrenceId,
        name: toolName,
        agentCoreBlockIndex,
      }, source.kind !== 'direct' && source.observationOnly ? 'observation' : 'active')
      // Insert above the live assistant bubble so the final reply text
      // stays the last entry in the transcript.
      insertThreadEntryBefore(keeperName, assistantEntryId, {
        id: toolOccurrenceId,
        role: 'tool',
        source: 'tool_result',
        label: toolName,
        text: '',
        rawText: '',
        timestamp: new Date().toISOString(),
        toolCallId,
        toolCallEnded: false,
        toolOccurrence: Object.freeze({ kind: 'identified' as const, streamScope: event.toolStreamScope, blockIndex: event.toolCallBlockIndex }),
        ...(toolOwnerKey ? { toolOwnerKey } : { toolParentEntryId: assistantEntryId }),
        deliveryProvenance: null,
        delivery: 'streaming',
        streamState: 'streaming',
        streamContract: keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'TOOL_CALL_START' }),
        details: null,
      })
      return null
    }
    case 'TOOL_CALL_ARGS': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = nonBlankToolCallId(event.toolCallId) ?? undefined
      const snapshot = event.snapshot
      const toolOccurrenceId = streamedToolOccurrenceId(
        keeperName,
        assistantEntryId,
        event.toolStreamScope,
        event.toolCallBlockIndex,
      )
      const toolEntry = (keeperThreads.value[keeperName] ?? [])
        .find(entry => entry.id === toolOccurrenceId)
      if (!toolEntry) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_ARGS names no open server occurrence',
          { toolOccurrenceId },
        )
        return null
      }
      if (toolEntry.toolCallEnded) {
        // The occurrence already has an authoritative terminal state (normal
        // END/RESULT or quarantine). Diagnose the late event on the assistant
        // row without rewriting that terminal tool evidence.
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_ARGS names no open server occurrence',
        )
        return null
      }
      if (toolCallId && toolEntry.toolCallId && toolEntry.toolCallId !== toolCallId) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_ARGS provider correlation conflicts with its server occurrence',
          { toolOccurrenceId },
        )
        return null
      }
      if (typeof snapshot === 'string') {
        setAssistantToolTraceArgsSnapshot(keeperName, assistantEntryId, toolEntry.id, snapshot)
        updateThreadEntry(keeperName, toolEntry.id, entry => ({
          ...entry,
          text: snapshot,
          rawText: snapshot,
        }))
      } else if (typeof event.delta === 'string' && event.delta) {
        appendAssistantToolTraceArgsDelta(keeperName, assistantEntryId, toolEntry.id, event.delta)
        updateThreadEntry(keeperName, toolEntry.id, entry => ({
          ...entry,
          text: `${entry.text}${event.delta}`,
          rawText: `${entry.rawText ?? entry.text}${event.delta}`,
        }))
      }
      return null
    }
    case 'TOOL_CALL_END': {
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      const toolCallId = nonBlankToolCallId(event.toolCallId) ?? undefined
      const toolOccurrenceId = streamedToolOccurrenceId(
        keeperName,
        assistantEntryId,
        event.toolStreamScope,
        event.toolCallBlockIndex,
      )
      const toolEntry = (keeperThreads.value[keeperName] ?? [])
        .find(entry => entry.id === toolOccurrenceId)
      if (!toolEntry) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_END names no server occurrence',
          { toolOccurrenceId },
        )
        return null
      }
      if (isToolOccurrenceQuarantined(keeperName, assistantEntryId, toolOccurrenceId)) {
        updateThreadEntry(keeperName, toolEntry.id, entry => ({
          ...entry,
          toolCallEnded: true,
        }))
        return null
      }
      if (toolEntry.toolCallEnded) return null
      if (toolCallId && toolEntry.toolCallId && toolEntry.toolCallId !== toolCallId) {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          'TOOL_CALL_END provider correlation conflicts with its server occurrence',
          { toolOccurrenceId },
        )
        return null
      }
      updateThreadEntry(keeperName, toolEntry.id, entry => {
        if (entry.delivery === 'delivered') return { ...entry, toolCallEnded: true }
        return {
          ...entry,
          toolCallEnded: true,
          delivery: 'streaming',
          streamState: 'streaming',
          streamContract: keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'TOOL_CALL_END' }),
        }
      })
      return null
    }
    case 'CUSTOM': {
      const customEventName: string = event.name
      if (event.name === 'KEEPER_MODEL_CONTENT_ACTIVITY') {
        if (event.value.state === 'observed') admitResponseEvent(keeperName, assistantEntryId, {
          kind: 'observe', source: 'content', scope: event.value.stream_scope,
          owner: { content_generation: event.value.generation, stream_scope: event.value.stream_scope },
        })
        return null
      }
      if (event.name === 'KEEPER_TOOL_TRANSCRIPT_COMMITTED') {
        const { executionId, ordinal } = event.value
        const deliveryKey = Object.freeze({ ...event.value.deliveryKey })
        const entries = keeperThreads.value[keeperName] ?? []
        const parent = entries.find(entry => entry.id === assistantEntryId)
        if (!parent || parent.toolObservationAuthority === 'unavailable') return null
        const autonomousOwner = source.kind === 'autonomous' && parent.source === 'autonomous_turn' && parent.turnRef === source.turnRef
        if (!autonomousOwner && (!parent.deliveryProvenance
          || !toolDeliveryBelongsToProducer(parent.deliveryProvenance.delivery_key, deliveryKey))) return null
        const previous = parent.toolTranscriptBindings ?? []
        if (previous.some(binding => binding.executionId === executionId && (binding.ordinal !== ordinal || !sameDeliveryKey(binding.deliveryKey, deliveryKey))
          || sameDeliveryKey(binding.deliveryKey, deliveryKey) && binding.ordinal === ordinal && binding.executionId !== executionId)) {
          updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, toolObservationAuthority: 'unavailable',
            error: 'Server transcript bindings conflict; authoritative recovery is required' }))
          return null
        }
        const matching = entries.filter(entry => entry.role === 'tool' && sameToolParent(parent, entry) && entry.executionId === executionId)
        if (matching.length > 1) {
          updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, toolObservationAuthority: 'unavailable' }))
          return null
        }
        const resource = matching[0]
        if (resource?.toolOccurrenceQuarantined || resource?.toolParentCandidates?.length) {
          updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, toolObservationAuthority: 'unavailable',
            error: 'Acknowledged tool transcript is quarantined under disputed parent ownership' }))
          return null
        }
        const resourceSlot = resource?.deliveryProvenance?.transcript_slot
        if (resource && resourceSlot?.kind === 'tool_call' && (resourceSlot.execution_id !== executionId || resourceSlot.ordinal !== ordinal
          || !sameDeliveryKey(resource!.deliveryProvenance!.delivery_key, deliveryKey))
          || resource?.toolTranscriptOrdinal !== undefined && resource.toolTranscriptOrdinal !== ordinal) {
          updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, toolObservationAuthority: 'unavailable',
            error: 'Server transcript binding contradicts canonical tool ownership' }))
          return null
        }
        updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry,
          toolTranscriptBindings: Object.freeze(previous.some(binding => binding.executionId === executionId) ? [...previous]
            : [...previous, Object.freeze({ deliveryKey: deliveryKey, executionId, ordinal })]),
        }))
        if (matching[0]) updateThreadEntry(keeperName, matching[0].id, entry => ({ ...entry,
          toolTranscriptOrdinal: ordinal,
          deliveryProvenance: { delivery_key: deliveryKey, transcript_slot: { kind: 'tool_call', execution_id: executionId, ordinal } },
        }))
        if (resource) convergeAcknowledgedTool(keeperName, parent, resource, { deliveryKey, executionId, ordinal })
        return null
      }
      if (event.name === 'KEEPER_TOOL_RESULT_READY') {
        if ((keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.toolObservationAuthority === 'unavailable') {
          updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, error: 'Stored tool ownership is unavailable; authoritative recovery is required' }))
          return null
        }
        const toolCallId = nonBlankToolCallId(event.value.toolCallId) ?? undefined
        const executionId = event.value.executionId
        if (!executionId.trim()) return 'KEEPER_TOOL_RESULT_READY missing executionId'
        const toolOccurrenceId = streamedToolOccurrenceId(
          keeperName,
          assistantEntryId,
          event.value.toolStreamScope,
          event.value.toolCallBlockIndex,
        )
        if (isToolOccurrenceQuarantined(keeperName, assistantEntryId, toolOccurrenceId)) {
          return 'KEEPER_TOOL_RESULT_READY targets a quarantined tool occurrence'
        }
        const toolEntry = (keeperThreads.value[keeperName] ?? [])
          .find(entry => entry.id === toolOccurrenceId)
        if (!toolEntry) return 'KEEPER_TOOL_RESULT_READY names no streamed server occurrence'
        const executionOwner = (keeperThreads.value[keeperName] ?? []).find(entry => (
          entry.role === 'tool'
          && entry.id !== toolEntry.id
          && sameToolParent((keeperThreads.value[keeperName] ?? []).find(parent => parent.id === assistantEntryId), entry)
          && entry.executionId === executionId
        ))
        if (toolCallId && toolEntry.toolCallId && toolEntry.toolCallId !== toolCallId) {
          return 'KEEPER_TOOL_RESULT_READY provider correlation conflicts with its server occurrence'
        }
        const currentSlot = toolEntry?.deliveryProvenance?.transcript_slot
        if (
          currentSlot?.kind === 'tool_call'
          && currentSlot.execution_id !== executionId
        ) {
          return 'KEEPER_TOOL_RESULT_READY conflicts with the recorded execution_id'
        }
        if (toolEntry.executionId != null) {
          return toolEntry.executionId === executionId
            ? null
            : 'KEEPER_TOOL_RESULT_READY conflicts with the recorded execution_id'
        }
        const committedBinding = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)
          ?.toolTranscriptBindings?.find(binding => binding.executionId === executionId)
        const committedOrdinal = committedBinding?.ordinal
        if (executionOwner) {
          const canonicalSlot = executionOwner.deliveryProvenance?.transcript_slot
          const parentKey = toolEntry.toolOwnerKey ?? toolEntry.deliveryProvenance?.delivery_key
          const canonicalKey = executionOwner.deliveryProvenance?.delivery_key
          // Only the server result binds a planned ordinal to an execution.
          // History alone cannot infer this association from provider correlation.
          if (!parentKey || !canonicalKey || !toolDeliveryBelongsToProducer(parentKey, canonicalKey)
            || canonicalSlot?.kind !== 'tool_call' || canonicalSlot.execution_id !== executionId
            || committedBinding !== undefined && (!sameDeliveryKey(canonicalKey, committedBinding.deliveryKey) || canonicalSlot.ordinal !== committedBinding.ordinal)
            || executionOwner.toolOccurrence !== undefined) {
            return 'KEEPER_TOOL_RESULT_READY execution_id belongs to another tool occurrence'
          }
          if (executionOwner.toolOccurrenceQuarantined === true) {
            return 'KEEPER_TOOL_RESULT_READY targets a quarantined tool occurrence'
          }
          if (toolEntry.toolCallId && executionOwner.toolCallId
            && toolEntry.toolCallId !== executionOwner.toolCallId) {
            return 'KEEPER_TOOL_RESULT_READY provider correlation conflicts with its server occurrence'
          }
          if (toolCallId && executionOwner.toolCallId && executionOwner.toolCallId !== toolCallId) {
            return 'KEEPER_TOOL_RESULT_READY provider correlation conflicts with its server occurrence'
          }
          const entries = keeperThreads.value[keeperName] ?? []
          const parent = entries.find(entry => entry.id === assistantEntryId)
          setRecordValue(keeperThreads, keeperName, entries.filter(entry => entry.id !== toolEntry.id).map(entry => {
            if (entry.id === executionOwner.id) return {
              ...entry, toolOwnerKey: parentKey, toolOccurrence: toolEntry.toolOccurrence, toolCallEnded: true,
            }
            if (entry.role !== 'assistant' || !sameToolParent(entry, executionOwner)
              || !sameToolParent(parent, executionOwner)) return entry
            return { ...entry, traceSteps: entry.traceSteps?.map(step => step.kind === 'tool'
              && (step.toolOccurrenceId === toolEntry.id || step.executionId === executionId)
              ? { ...step, toolOccurrenceId: executionOwner.id, executionId,
                status: step.status === 'err' ? 'err' as const : 'ok' as const }
              : step) }
          }))
          return null
        }
        const deliveryProvenance = committedBinding === undefined ? null
          : { delivery_key: committedBinding.deliveryKey,
            transcript_slot: { kind: 'tool_call' as const, execution_id: executionId, ordinal: committedBinding.ordinal } }
        markAssistantToolTraceEnded(
          keeperName,
          assistantEntryId,
          toolEntry.id,
          executionId,
        )
        updateThreadEntry(keeperName, toolEntry.id, entry => ({
          ...entry,
          executionId,
          ...(committedOrdinal !== undefined ? { toolTranscriptOrdinal: committedOrdinal } : {}),
          toolCallEnded: true,
          deliveryProvenance,
          delivery: 'delivered',
          streamState: null,
          streamContract: keeperStreamContract(
            'sse_event',
            'backend_stream_event',
            { eventName: 'KEEPER_TOOL_RESULT_READY' },
          ),
        }))
        if (committedBinding) {
          const current = keeperThreads.value[keeperName] ?? []
          const parent = current.find(entry => entry.id === assistantEntryId)
          const resource = current.find(entry => entry.id === toolEntry.id)
          if (parent && resource) convergeAcknowledgedTool(keeperName, parent, resource, committedBinding)
        }
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
            'terminal_result',
          ),
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
        return null
      }
      if (event.name === 'KEEPER_RUNTIME_ATTEMPT_STARTED') {
        if (!admitResponseEvent(keeperName, assistantEntryId, { kind: 'attempt' }).accepted) return null
        resetUnfinishedRuntimeAttempt(keeperName, assistantEntryId)
        return null
      }
      if (event.name === 'KEEPER_TOOL_APPROVAL_REQUESTED') {
        const toolCallId = nonBlankToolCallId(event.value.tool_call_id)
        if (!toolCallId) return 'KEEPER_TOOL_APPROVAL_REQUESTED missing tool_call_id'
        const toolName = event.value.tool_call_name
        const question = event.value.question
        if (!toolName) return 'KEEPER_TOOL_APPROVAL_REQUESTED missing tool_call_name'
        if (!question) return 'KEEPER_TOOL_APPROVAL_REQUESTED missing question'
        upsertKeeperToolApproval(keeperName, {
          toolCallId,
          toolName,
          args: event.value.args,
          question,
          because: event.value.because ?? '',
          askedAtMs: Date.now(),
          timeoutSec: null,
          answering: false,
          answeredDecision: null,
          answeredOutcome: null,
          settled: false,
        })
        return null
      }
      if (event.name === 'KEEPER_TOOL_APPROVAL_SETTLED') {
        const toolCallId = nonBlankToolCallId(event.value.tool_call_id)
        if (!toolCallId) return 'KEEPER_TOOL_APPROVAL_SETTLED missing tool_call_id'
        const outcome = event.value.outcome
        if (!outcome) return 'KEEPER_TOOL_APPROVAL_SETTLED missing outcome'
        // A settle for a call this view never drew (e.g. answered from another
        // window, or a re-hydrated wait whose REQUESTED predates this view)
        // still retires nothing here; dropping is the no-op it should be.
        dropKeeperToolApproval(keeperName, toolCallId)
        return null
      }
      if (event.name === 'KEEPER_STREAM_MESSAGE_START') {
        const response = admitResponseEvent(keeperName, assistantEntryId, {
          kind: 'observe', source: 'header', scope: event.value.stream_scope,
          owner: event.value.content_generation === undefined ? null
            : { content_generation: event.value.content_generation, stream_scope: event.value.stream_scope },
        })
        if (!response.accepted) return null
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        const patch: Partial<KeeperConversationDetails> = {}
        const providerMessageId = asString(value?.provider_message_id)
        const modelUsed = asString(value?.model)
        const usage = normalizeStreamUsage(value?.usage)
        if (providerMessageId) patch.providerMessageId = providerMessageId
        if (modelUsed) patch.modelUsed = modelUsed
        const current = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.details
        if (usage) {
          const initial = { ...usage }
          for (const key of Object.keys(initial) as Array<keyof typeof initial>) {
            if (current?.usage?.[key] != null) delete initial[key]
          }
          patch.usage = initial
        }
        if (usage?.costUsd !== undefined && current?.costUsd == null) patch.costUsd = usage.costUsd
        if (Object.keys(patch).length > 0) mergeAssistantStreamDetails(keeperName, assistantEntryId, patch)
        if (response.advanced) setAssistantStreamState(
          keeperName, assistantEntryId, 'opening', 'streaming',
          keeperStreamContract('sse_event', 'backend_stream_event', { eventName: 'KEEPER_STREAM_MESSAGE_START' }),
        )
        persistActiveAssistantDraft(keeperName, assistantEntryId)
        return null
      }
      if (event.name === 'KEEPER_STREAM_MESSAGE_DELTA') {
        if (!admitResponseEvent(keeperName, assistantEntryId, {
          kind: 'observe', source: 'details', scope: event.value.stream_scope,
          owner: event.value.content_generation === undefined ? null
            : { content_generation: event.value.content_generation, stream_scope: event.value.stream_scope },
        }).accepted) return null
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
        if (!admitResponseEvent(keeperName, assistantEntryId, { kind: 'stop', owner: event.value }).accepted) return null
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        markFinalizingIfLive('KEEPER_STREAM_MESSAGE_STOP')
        return null
      }
      if (event.name === 'KEEPER_STREAM_PING') return null
      if (event.name === 'KEEPER_CONTENT_BLOCK_START') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const value = isRecord(event.value) ? event.value : null
        const agentCoreBlockIndex = asNumber(value?.index)
        const contentType = asString(value?.content_type)
        if (contentType === 'text') {
          rememberAgentCoreTextBlockIndex(keeperName, assistantEntryId, agentCoreBlockIndex)
        }
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_STOP') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        return null
      }
      if (event.name === 'KEEPER_THINKING_DELTA' && source.kind === 'autonomous') {
        const current = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.responseState
        if (source.observationOnly && current?.kind === 'known' && current.phase === 'terminal') return null
        const value = event.value
        const response = source.observationOnly ? null : admitResponseEvent(keeperName, assistantEntryId, {
          kind: 'observe', owner: value.response ?? null, scope: null, source: 'body',
        })
        if (response && !response.accepted) return null
        if (typeof value.delta !== 'string' || value.delta.length === 0) return null
        flushAutonomousSaying(keeperName, assistantEntryId, source.observationOnly === true)
        const owner = value.response ? Object.freeze({ ...value.response }) : null
        const before = (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)
        if (!before) return null
        const slots = before.autonomousThinkingReplay ?? []
        const boundary = before.autonomousTraceBoundary ?? null
        const same = (slot: typeof slots[number]) => slot.index === value.index && slot.boundary === boundary
          && sameKeeperResponseOwner(slot.owner ?? undefined, owner ?? undefined)
        const previous = slots.find(same)
        const observed = Object.freeze({ boundary, index: value.index, owner, text: (previous?.text ?? '') + value.delta })
        setAssistantThinkingSnapshot(keeperName, assistantEntryId, observed.text,
          { agentCoreBlockIndex: value.index, responseOwner: owner ?? undefined })
        updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry,
          ...(source.observationOnly || response && !response.authoritative
            ? { delivery: before.delivery, streamState: before.streamState } : {}),
          autonomousThinkingReplay: Object.freeze([...slots.filter(slot => !same(slot)), observed]),
        }))
        return null
      }
      if (event.name === 'KEEPER_THINKING_DELTA') {
        const response = admitResponseEvent(keeperName, assistantEntryId, {
          kind: 'observe', source: 'body', scope: null, owner: event.value.response ?? null,
        })
        if (!response.accepted) return null
        const value = isRecord(event.value) ? event.value : null
        const delta = value && typeof value.delta === 'string'
          ? value.delta
          : undefined
        const agentCoreBlockIndex = value ? asNumber(value.index) : undefined
        if (delta) enqueueThinkingDelta(keeperName, assistantEntryId, delta, { agentCoreBlockIndex, responseOwner: event.value.response && response.state.kind === 'known' ? response.state.current ?? undefined : undefined, authoritative: response.authoritative })
        return null
      }
      if (event.name === 'KEEPER_STREAM_PROTOCOL_ERROR') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        const quarantinedOccurrence = event.value.quarantined_occurrence
        const toolOccurrenceId = quarantinedOccurrence
          ? streamedToolOccurrenceId(
              keeperName,
              assistantEntryId,
              quarantinedOccurrence.toolStreamScope,
              quarantinedOccurrence.toolCallBlockIndex,
            )
          : undefined
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          streamProtocolMessage(event.value, 'stream protocol error'),
          {
            toolOccurrenceId,
            authoritativeQuarantine: quarantinedOccurrence !== undefined,
          },
        )
        return null
      }
      if (event.name === 'KEEPER_THINKING_SIGNATURE_DELTA') {
        return null
      }
      if (event.name === 'KEEPER_MEDIA_DELTA') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        return null
      }
      if (event.name === 'KEEPER_CONTINUATION_CHECKPOINT') {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        if (!admitResponseEvent(keeperName, assistantEntryId, { kind: 'checkpoint' }).accepted) return null
        const rawText = isRecord(event.value)
          ? asString(event.value.message, '')
          : ''
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          replyTextProjection: undefined,
          replyBlockSource: undefined,
          blocks: [
            ...producerReplyBlocks(entry).filter(block => block.t !== 'status'),
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
            const rawText = entry.replyBlockSource === 'canonical_body'
              ? entry.rawText ?? entry.text
              : mergedDetails.replyText ?? entry.rawText ?? entry.text
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
            const text = rawText
            const projection = projectFinalReplyBlocks(entry, text)
            return {
              ...entry,
              details: mergedDetails,
              turnRef: mergedDetails.turnRef ?? entry.turnRef,
              rawText,
              text,
              ...projection,
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
      admitResponseEvent(keeperName, assistantEntryId, {
        kind: (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantEntryId)?.details?.turnOutcome === 'continuation_checkpoint'
          ? 'checkpoint' : 'terminal',
      })
      clearPendingAgentCoreTextBlockIndex(keeperName, assistantEntryId)
      clearTextMessageStreamState(keeperName, assistantEntryId)
      if (source.kind === 'autonomous') {
        updateThreadEntry(keeperName, assistantEntryId, entry => entry.source === 'autonomous_turn' && entry.turnRef === source.turnRef
          ? { ...entry, delivery: source.observationOnly ? entry.delivery : entry.delivery === 'no_reply' ? 'no_reply' : 'delivered',
            autonomousSayingReplay: undefined, streamState: null, error: null,
            streamContract: keeperStreamContract('sse_event', 'backend_terminal_event', { eventName: 'RUN_FINISHED' }) }
          : entry)
        return null
      }
      if (source.kind !== 'operation') return null
      updateThreadEntry(keeperName, assistantEntryId, entry => {
        if (!isOperationDeliveryProvenance(
          entry.deliveryProvenance,
          source.operationId,
          'terminal_result',
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
      if (source.kind === 'autonomous') updateThreadEntry(keeperName, assistantEntryId, entry => ({ ...entry, autonomousSayingReplay: undefined }))
      flushPendingThinkingDeltas(keeperName, assistantEntryId)
      admitResponseEvent(keeperName, assistantEntryId, { kind: 'terminal' })
      clearPendingAgentCoreTextBlockIndex(keeperName, assistantEntryId)
      clearTextMessageStreamState(keeperName, assistantEntryId)
      return asString(event.message, '').trim() || 'Keeper stream failed'
    default:
      return 'Unsupported Keeper stream event'
  }
  } catch (error) {
    failed = true
    throw error
  } finally {
    try {
      if (!failed && source.kind !== 'direct' && source.sequence !== undefined) {
        flushPendingThinkingDeltas(keeperName, assistantEntryId)
        updateThreadEntry(keeperName, assistantEntryId, entry => {
          const state = acknowledgeKeeperResponseSequence(entry.responseState ?? initialKeeperResponseState, source.sequence)
          return state ? { ...entry, responseState: state } : entry
        })
      }
    } finally {
      applyingStreamFrames.delete(frameKey)
    }
    if (!failed) persistActiveAssistantDraft(keeperName, assistantEntryId)
  }
}
