export const KEEPER_CHAT_CUSTOM_EVENT_NAMES = [
  'KEEPER_CONNECTED',
  'KEEPER_STREAM_MESSAGE_START',
  'KEEPER_STREAM_MESSAGE_DELTA',
  'KEEPER_STREAM_MESSAGE_STOP',
  'KEEPER_STREAM_PING',
  'KEEPER_CONTENT_BLOCK_START',
  'KEEPER_CONTENT_BLOCK_STOP',
  'KEEPER_THINKING_DELTA',
  'KEEPER_THINKING_SIGNATURE_DELTA',
  'KEEPER_MEDIA_DELTA',
  'KEEPER_STREAM_PROTOCOL_ERROR',
  'KEEPER_QUEUE_REQUEST',
  'KEEPER_CHAT_QUEUED',
  'KEEPER_QUEUED_TURN_DEFERRED',
  'KEEPER_CONTINUATION_CHECKPOINT',
  'KEEPER_EXTERNAL_EFFECT_COMPLETED',
  'KEEPER_REQUEST_TERMINAL',
  'KEEPER_REPLY_DETAILS',
] as const

export type KeeperChatCustomEventName = typeof KEEPER_CHAT_CUSTOM_EVENT_NAMES[number]

type KeeperChatStreamEventBase = {
  threadId?: string
  runId?: string
  timestamp?: number
}

export type KeeperChatStreamEvent = KeeperChatStreamEventBase & (
  | { type: 'RUN_STARTED' | 'RUN_FINISHED' }
  | { type: 'RUN_ERROR'; message?: string; code?: string }
  | { type: 'TEXT_MESSAGE_START'; messageId?: string; role?: 'assistant' | 'user' }
  | { type: 'TEXT_MESSAGE_CONTENT'; messageId?: string; delta?: string }
  | { type: 'TEXT_MESSAGE_END'; messageId?: string }
  | { type: 'TOOL_CALL_START'; toolCallId?: string; toolCallName?: string }
  | { type: 'TOOL_CALL_ARGS'; toolCallId?: string; delta?: string; snapshot?: string }
  | { type: 'TOOL_CALL_END'; toolCallId?: string }
  | { type: 'CUSTOM'; name: KeeperChatCustomEventName; value?: unknown }
)
