import { normalizeKeeperConversationDetails, formatKeeperVisibleReply } from './keeper-message'
import type { KeeperChatStreamEvent } from './api'
import {
  appendAssistantDelta,
  setAssistantStreamState,
  updateThreadEntry,
  insertThreadEntryBefore,
  finalizeAssistantEntry,
  clearActiveStream,
  activeStreamEntryId,
  getStreamController,
  keeperSending,
  keeperStreamStartedAt,
  setRecordValue,
} from './keeper-state'
import { isRecord, asString } from './components/common/normalize'

// Most recent TOOL_CALL_START id per keeper — fallback target for
// TOOL_CALL_ARGS / TOOL_CALL_END events that omit toolCallId.
const lastToolCallIds = new Map<string, string>()

function toolEntryId(toolCallId: string): string {
  return `tool-${toolCallId}`
}

export function abortKeeperThreadMessage(name: string): void {
  const keeperName = name.trim()
  if (!keeperName) return
  const controller = getStreamController(keeperName)
  const entryId = activeStreamEntryId(keeperName)
  console.debug(`[keeper-stream] aborting stream for ${keeperName}${entryId ? ` (entry=${entryId})` : ''}`)
  if (controller) controller.abort()
  if (entryId) {
    finalizeAssistantEntry(keeperName, entryId, {
      delivery: 'timeout',
      streamState: null,
      error: '요청 취소됨',
      timestamp: new Date().toISOString(),
    })
  }
  clearActiveStream(keeperName)
  setRecordValue(keeperSending, keeperName, false)
  setRecordValue(keeperStreamStartedAt, keeperName, null)
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
      // Insert above the live assistant bubble so the final reply text
      // stays the last entry in the transcript.
      insertThreadEntryBefore(keeperName, assistantEntryId, {
        id: toolEntryId(toolCallId),
        role: 'tool',
        source: 'tool_result',
        label: event.toolCallName ?? event.name ?? 'tool',
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
        updateThreadEntry(keeperName, toolEntryId(toolCallId), entry => ({
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
        updateThreadEntry(keeperName, toolEntryId(toolCallId), entry => ({
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
        setAssistantStreamState(keeperName, assistantEntryId, 'thinking', 'streaming')
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
        const status = asString(terminal?.status, '').trim()
        const ok = terminal?.ok === true
        const failed =
          !ok && ['error', 'lost', 'cancelled'].includes(status)
        if (failed) {
          const message =
            asString(terminal?.message, '').trim() || 'Keeper request failed'
          updateThreadEntry(keeperName, assistantEntryId, entry => ({
            ...entry,
            text: entry.text || `Keeper request failed: ${message}`,
            rawText: entry.rawText || message,
            delivery: status === 'cancelled' ? 'timeout' : 'error',
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
            if (details.turnOutcome === 'continuation_checkpoint') {
              return {
                ...entry,
                details,
                rawText,
                text: '',
                delivery: 'queued',
                streamState: null,
              }
            }
            const text = formatKeeperVisibleReply(rawText)
            return {
              ...entry,
              details,
              rawText,
              text,
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
