import {
  formatKeeperVisibleReply,
  keeperTurnOutcomeSuppressesReply,
  normalizeKeeperConversationDetails,
} from './keeper-message'
import { parseTextToChatBlocks } from './lib/chat-blocks'
import type { KeeperChatStreamEvent } from './api'
import {
  appendAssistantDelta,
  appendAssistantThinkingDelta,
  appendAssistantToolTraceArgsDelta,
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
import { isRecord, asString } from './components/common/normalize'
import { toolEntryIdFromCallId } from './tool-call-output-store'

const KEEPER_MESSAGE_CANCELLED_TEXT = '요청이 취소되었습니다.'
export const TERMINAL_REQUEST_STATUSES = new Set(['done', 'error', 'lost', 'cancelled'])

// Most recent TOOL_CALL_START id per keeper — fallback target for
// TOOL_CALL_ARGS / TOOL_CALL_END events that omit toolCallId.
const lastToolCallIds = new Map<string, string>()

export interface KeeperThreadAbortResult {
  readonly keeperName: string
  readonly entryId: string | null
  readonly requestId: string | null
  readonly controllerAborted: boolean
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
      const toolCallId = event.toolCallId ?? `tc-${keeperName}-${Date.now()}`
      lastToolCallIds.set(keeperName, toolCallId)
      const toolName = event.toolCallName ?? event.name ?? 'tool'
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
      const toolCallId = event.toolCallId ?? lastToolCallIds.get(keeperName)
      if (toolCallId && typeof event.delta === 'string' && event.delta) {
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
      const toolCallId = event.toolCallId ?? lastToolCallIds.get(keeperName)
      if (toolCallId) {
        markAssistantToolTraceEnded(keeperName, assistantEntryId, toolCallId)
        updateThreadEntry(keeperName, toolEntryIdFromCallId(toolCallId), entry => ({
          ...entry,
          delivery: 'delivered',
          streamState: null,
        }))
        if (lastToolCallIds.get(keeperName) === toolCallId) {
          lastToolCallIds.delete(keeperName)
        }
      }
      return null
    }
    case 'CUSTOM':
      if (event.name === 'KEEPER_THINKING_DELTA') {
        const delta = isRecord(event.value)
          ? (typeof event.value.delta === 'string'
              ? event.value.delta
              : typeof event.value.text === 'string'
                ? event.value.text
                : undefined)
          : typeof event.value === 'string'
            ? event.value
            : undefined
        if (delta) appendAssistantThinkingDelta(keeperName, assistantEntryId, delta)
        else setAssistantStreamState(keeperName, assistantEntryId, 'thinking', 'streaming')
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
            const rawText = details.replyText ?? entry.rawText ?? entry.text
            if (keeperTurnOutcomeSuppressesReply(details.turnOutcome)) {
              return {
                ...entry,
                details,
                rawText,
                text: '',
                delivery: details.turnOutcome === 'no_visible_reply' ? 'no_reply' : 'queued',
                streamState: null,
              }
            }
            const text = formatKeeperVisibleReply(rawText)
            const blocks = entry.blocks?.length ? entry.blocks : parseTextToChatBlocks(text)
            return {
              ...entry,
              details,
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
