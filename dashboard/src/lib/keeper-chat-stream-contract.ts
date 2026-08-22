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
  'KEEPER_CHAT_OPERATION_ACCEPTED',
  'KEEPER_CONTINUATION_CHECKPOINT',
  'KEEPER_EXTERNAL_EFFECT_COMPLETED',
  'KEEPER_REPLY_DETAILS',
  'KEEPER_TOOL_RESULT_READY',
] as const

export type KeeperChatCustomEventName = typeof KEEPER_CHAT_CUSTOM_EVENT_NAMES[number]

export type KeeperStreamUsage = {
  input_tokens?: number
  output_tokens?: number
  total_tokens?: number
  cache_creation_input_tokens?: number
  cache_read_input_tokens?: number
  cost_usd?: number
}

// Cumulative mid-stream counters: only the fields the delta actually
// reported appear, and the producer never emits a total or a cost here.
export type KeeperStreamDeltaUsage = {
  input_tokens?: number
  output_tokens?: number
  cache_creation_input_tokens?: number
  cache_read_input_tokens?: number
}

export type KeeperStreamProtocolErrorKind =
  | 'tool_start_duplicate_index'
  | 'tool_start_missing_identity'
  | 'tool_args_without_start'
  | 'tool_stop_without_start'
  | 'media_delta_invalid_block'
  | 'media_source_unsupported'
  | 'media_decode_failed'
  | 'media_payload_too_large'
  | 'media_persist_failed'
  | 'sse_error'
  | 'ndjson_error'
  | 'sse_parse_failed'
  | 'ndjson_parse_failed'
  | 'sse_unknown_event_type'
  | 'sse_unsupported_part'
  | 'sse_unsupported_response'
  | 'sse_stream_incomplete'

export type KeeperTurnOutcome =
  | 'visible_reply'
  | 'continuation_checkpoint'
  | 'external_effect_completed'
  | 'external_effect_pending'
  | 'no_visible_reply'

type KeeperChatCustomEvent =
  | { type: 'CUSTOM'; name: 'KEEPER_CONNECTED'; value: null }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_CHAT_OPERATION_ACCEPTED'
      value: {
        operation_id: string
        state: 'Queued' | 'Running' | 'Succeeded' | 'Failed' | 'Cancelled'
        queued_count: number
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_STREAM_MESSAGE_START'
      value: {
        provider_message_id?: string
        model?: string
        usage?: KeeperStreamUsage
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_STREAM_MESSAGE_DELTA'
      value: { stop_reason?: string; usage?: KeeperStreamDeltaUsage }
    }
  | { type: 'CUSTOM'; name: 'KEEPER_STREAM_MESSAGE_STOP'; value: null }
  | { type: 'CUSTOM'; name: 'KEEPER_STREAM_PING'; value: null }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_TOOL_RESULT_READY'
      value: { tool_call_id: string }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_CONTENT_BLOCK_START'
      value: {
        index?: number
        content_type?: string
        tool_call_id?: string
        tool_call_name?: string
      }
    }
  | { type: 'CUSTOM'; name: 'KEEPER_CONTENT_BLOCK_STOP'; value: { index?: number } }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_THINKING_DELTA'
      value: { index?: number; delta?: string }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_THINKING_SIGNATURE_DELTA'
      value: { index?: number; signature_bytes?: number }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_MEDIA_DELTA'
      value: {
        index?: number
        media_type?: string
        source_type?: 'base64' | 'url' | 'file_id'
        media_ref?: string
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_STREAM_PROTOCOL_ERROR'
      value: {
        kind?: KeeperStreamProtocolErrorKind
        index?: number
        tool_call_id?: string
        event_type?: string
        reason?: string
        raw_bytes?: number
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_CONTINUATION_CHECKPOINT'
      value: { message?: string; request_id?: string }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_EXTERNAL_EFFECT_COMPLETED'
      // The typed target names the real destination of the completed
      // surface post (#28374).
      value: {
        target: {
          kind?: 'dashboard' | 'discord' | 'slack'
          channel_id?: string
          thread_ts?: string
        }
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_REPLY_DETAILS'
      value: { reply?: string; turn_outcome?: KeeperTurnOutcome; turn_ref?: string }
    }

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
  | KeeperChatCustomEvent
)
