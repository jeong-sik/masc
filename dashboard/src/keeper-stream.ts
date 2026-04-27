import { normalizeKeeperConversationDetails, formatKeeperVisibleReply } from './keeper-message'
import type { KeeperChatStreamEvent } from './api'
import {
  appendAssistantDelta,
  setAssistantStreamState,
  updateThreadEntry,
  finalizeAssistantEntry,
  clearActiveStream,
  activeStreamEntryId,
  getStreamController,
  keeperSending,
  keeperStreamStartedAt,
  setRecordValue,
} from './keeper-state'
import { isRecord, asString } from './components/common/normalize'

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
      error: '스트림 취소됨',
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
    case 'TEXT_DELTA': {
      applyTextDelta(event.delta)
      return null
    }
    case 'TEXT_MESSAGE_END':
      setAssistantStreamState(keeperName, assistantEntryId, 'finalizing', 'streaming')
      return null
    case 'CUSTOM':
      if (event.name === 'KEEPER_REPLY_DETAILS') {
        const details = normalizeKeeperConversationDetails(event.value)
        if (details) {
          updateThreadEntry(keeperName, assistantEntryId, entry => {
            const rawText = details.replyText ?? entry.rawText ?? entry.text
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
