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
  appendAssistantThinkingDelta,
  appendAssistantToolTraceArgsDelta,
  setAssistantToolTraceArgsSnapshot,
  appendAssistantToolTraceStep,
  setAssistantStreamState,
  updateThreadEntry,
  insertThreadEntryBefore,
  finalizeAssistantEntry,
  markAssistantToolTraceEnded,
  clearActiveStream,
  clearActiveStreamRequestId,
  releaseActiveStreamRequestId,
  activeStreamEntryId,
  activeStreamRequestId,
  getStreamController,
  keeperSending,
  keeperStreamStartedAt,
  setRecordValue,
} from './keeper-state'
import { isRecord, asNumber, asString } from './components/common/normalize'
import { toolEntryIdFromCallId } from './tool-call-output-store'

const KEEPER_MESSAGE_CANCELLED_TEXT = '요청이 취소되었습니다.'
export const TERMINAL_REQUEST_STATUSES = new Set(['done', 'error', 'lost', 'cancelled'])

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
  const index = typeof value.index === 'number' ? `index=${value.index}` : ''
  return [kind || fallback, eventType ? `event=${eventType}` : '', index, reason]
    .filter(part => part.trim() !== '')
    .join(' | ')
}

function recordStreamProtocolError(
  keeperName: string,
  assistantEntryId: string,
  message: string,
): void {
  updateThreadEntry(keeperName, assistantEntryId, entry => {
    const line = `[stream protocol] ${message}`
    return {
      ...entry,
      rawText: entry.rawText?.trim() ? `${entry.rawText}\n${line}` : line,
      error: message,
    }
  })
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
    finalizeAssistantEntry(keeperName, entryId, {
      text: KEEPER_MESSAGE_CANCELLED_TEXT,
      rawText: KEEPER_MESSAGE_CANCELLED_TEXT,
      delivery: 'cancelled',
      streamState: null,
      error: null,
      timestamp: new Date().toISOString(),
    })
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
    if (payload) appendAssistantDelta(keeperName, assistantEntryId, payload)
  }

  switch (event.type) {
    case 'RUN_STARTED':
      setAssistantStreamState(keeperName, assistantEntryId, 'opening', 'sending')
      return null
    case 'TEXT_MESSAGE_START':
      setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
      return null
    case 'TEXT_MESSAGE_CONTENT': {
      applyTextDelta(event.delta)
      return null
    }
    case 'TEXT_MESSAGE_END':
      setAssistantStreamState(keeperName, assistantEntryId, 'finalizing', 'streaming')
      return null
    case 'TOOL_CALL_START': {
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
      appendAssistantToolTraceStep(keeperName, assistantEntryId, {
        toolCallId,
        name: toolName,
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
        details: null,
      })
      return null
    }
    case 'TOOL_CALL_ARGS': {
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
        }))
      }
      return null
    }
    case 'CUSTOM':
      if (event.name === 'KEEPER_STREAM_MESSAGE_START') {
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
        setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_STREAM_MESSAGE_DELTA') {
        const value = isRecord(event.value) ? event.value : null
        const patch: Partial<KeeperConversationDetails> = {}
        const stopReason = asString(value?.stop_reason)
        const usage = normalizeStreamUsage(value?.usage)
        if (stopReason) patch.stopReason = stopReason
        if (usage) patch.usage = usage
        if (usage?.costUsd !== undefined) patch.costUsd = usage.costUsd
        if (Object.keys(patch).length > 0) mergeAssistantStreamDetails(keeperName, assistantEntryId, patch)
        if (stopReason) setAssistantStreamState(keeperName, assistantEntryId, 'finalizing', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_STREAM_MESSAGE_STOP') {
        setAssistantStreamState(keeperName, assistantEntryId, 'finalizing', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_STREAM_PING') {
        setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_START') {
        const value = isRecord(event.value) ? event.value : null
        const oasBlockIndex = asNumber(value?.index) ?? asNumber(value?.block_index)
        const toolCallId = asString(value?.tool_call_id)
        const toolName = asString(value?.tool_call_name)
        if (toolCallId && toolName) {
          appendAssistantToolTraceStep(keeperName, assistantEntryId, {
            toolCallId,
            name: toolName,
            oasBlockIndex,
          })
        }
        setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_CONTENT_BLOCK_STOP') {
        setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
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
        if (delta) appendAssistantThinkingDelta(keeperName, assistantEntryId, delta, { oasBlockIndex })
        else setAssistantStreamState(keeperName, assistantEntryId, 'thinking', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_STREAM_PROTOCOL_ERROR') {
        recordStreamProtocolError(
          keeperName,
          assistantEntryId,
          streamProtocolMessage(event.value, 'stream protocol error'),
        )
        return null
      }
      if (event.name === 'KEEPER_THINKING_SIGNATURE_DELTA') {
        setAssistantStreamState(keeperName, assistantEntryId, 'thinking', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_MEDIA_DELTA') {
        setAssistantStreamState(keeperName, assistantEntryId, 'streaming', 'streaming')
        return null
      }
      if (event.name === 'KEEPER_QUEUE_REQUEST') {
        setAssistantStreamState(keeperName, assistantEntryId, 'opening', 'queued')
        return null
      }
      if (event.name === 'KEEPER_CONTINUATION_CHECKPOINT') {
        const rawText = isRecord(event.value)
          ? asString(event.value.message, '')
          : ''
        updateThreadEntry(keeperName, assistantEntryId, entry => ({
          ...entry,
          text: '',
          rawText: rawText || entry.rawText,
          delivery: 'queued',
          streamState: null,
        }))
        return null
      }
      if (event.name === 'KEEPER_REQUEST_TERMINAL') {
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
          }))
          return message
        }
        return null
      }
      if (event.name === 'KEEPER_REPLY_DETAILS') {
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
    case 'RUN_ERROR':
      return typeof event.value === 'string'
        ? event.value
        : (isRecord(event.value) ? asString(event.value.message) : null) ?? 'Keeper stream failed'
    default:
      return null
  }
}
