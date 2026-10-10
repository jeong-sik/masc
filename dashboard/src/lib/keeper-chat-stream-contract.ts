export const KEEPER_CHAT_CUSTOM_EVENT_NAMES = [
  'KEEPER_CONNECTED',
  'KEEPER_RUNTIME_ATTEMPT_STARTED',
  'KEEPER_STREAM_MESSAGE_START',
  'KEEPER_STREAM_MESSAGE_DELTA',
  'KEEPER_STREAM_MESSAGE_STOP',
  'KEEPER_STREAM_PING',
  'KEEPER_CONTENT_BLOCK_START',
  'KEEPER_CONTENT_BLOCK_STOP',
  'KEEPER_MODEL_CONTENT_ACTIVITY',
  'KEEPER_THINKING_DELTA',
  'KEEPER_THINKING_SIGNATURE_DELTA',
  'KEEPER_MEDIA_DELTA',
  'KEEPER_STREAM_PROTOCOL_ERROR',
  'KEEPER_CHAT_OPERATION_ACCEPTED',
  'KEEPER_CHAT_BATCH_BOUND',
  'KEEPER_CONTINUATION_CHECKPOINT',
  'KEEPER_EXTERNAL_EFFECT_COMPLETED',
  'KEEPER_REPLY_DETAILS',
  // #29650 put the pre-tool-use decision in one place and gave it these two
  // events. The OCaml side had them and this list did not, which the
  // cross-language parity test reads as a broken binding: an event the server
  // sends and the vocabulary does not name is dropped by the SSE decoder.
  'KEEPER_TOOL_APPROVAL_REQUESTED',
  'KEEPER_TOOL_APPROVAL_SETTLED',
  'KEEPER_TOOL_RESULT_READY',
  'KEEPER_NATIVE_TOOL_START',
  'KEEPER_NATIVE_TOOL_END',
  'KEEPER_NATIVE_TOOL_PROGRESS',
  // #29742 and #29744 both registered the two approval events for the same
  // main-red and both merged, leaving them listed twice. A duplicate entry
  // makes the contract array longer than the OCaml codec's vocabulary and
  // fails the cross-language parity test the other way.
] as const

export interface KeeperInteractiveReceipt {
  outcome: 'applied' | 'stale_control' | 'paused' | 'replayed'
  chat_control_token: string
  signalled: boolean
  resumed: boolean
  interrupt_error: string | null
}

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

// One list for the wire kinds of KEEPER_STREAM_PROTOCOL_ERROR. The decoder in
// schemas/sse.ts builds its accept set from it, and
// keeper-stream-protocol-error-kind-parity.test.ts holds it equal to the
// OCaml emitter (Keeper_chat_events.stream_protocol_error_kind_to_string). A
// kind missing here is not "unknown": the decoder rejects the frame, and on
// the operation-projection path (keeper_chat_operation_event frames) that
// rejection is synthesised into a terminal RUN_ERROR, so a mid-turn attempt
// failure would end the bubble and drop the answer that follows on the next
// attempt. The direct fetch stream in api/keeper.ts does not decode at all.
export const KEEPER_STREAM_PROTOCOL_ERROR_KINDS = [
  'tool_start_duplicate_index',
  'tool_start_missing_identity',
  'tool_args_without_start',
  'tool_stop_without_start',
  'tool_replay_mismatch',
  'tool_delta_invalid_kind',
  'tool_attempt_superseded',
  'tool_message_start_conflict',
  'stream_event_after_terminal',
  'tool_occurrence_mapping_invalid',
  'media_delta_invalid_block',
  'media_source_unsupported',
  'media_decode_failed',
  'media_payload_too_large',
  'media_persist_failed',
  'sse_error',
  'ndjson_error',
  'sse_parse_failed',
  'ndjson_parse_failed',
  'sse_unknown_event_type',
  'sse_unsupported_part',
  'sse_unsupported_response',
  'sse_stream_incomplete',
  'sse_stream_repeating',
  'sse_timeout',
] as const

export type KeeperStreamProtocolErrorKind = (typeof KEEPER_STREAM_PROTOCOL_ERROR_KINDS)[number]

export type KeeperTurnOutcome =
  | 'visible_reply'
  | 'continuation_checkpoint'
  | 'external_effect_completed'
  | 'external_effect_pending'
  | 'no_visible_reply'

type KeeperToolStreamOccurrence = {
  toolStreamScope: number
  toolCallBlockIndex: number
  providerMessageId?: string
  toolCallId?: string
}

/** Provider observation only: no MASC execution receipt or inferred success. */
export type KeeperNativeToolObservation = KeeperToolStreamOccurrence & {
  toolCallName?: string
}

/** Wire projection of Runtime_native_tools.completion. A reported completion
 * is not a success verdict; absent is_error and absent exit status stay null. */
export type KeeperNativeToolCompletion = { exit_code: number | null } & (
  | { kind: 'end_observed' | 'completion_reported' | 'error_reported' | 'decline_reported' }
  | { kind: 'result_received'; is_error: boolean | null }
  | { kind: 'unrecognized_status'; status: string }
)

export type KeeperNativeToolProgress =
  | { kind: 'output_observed'; byte_count: number }
  | { kind: 'message_reported'; message: string }
  // Provider-reported elapsed seconds, independent of local arrival timers.
  | { kind: 'heartbeat_reported'; elapsed_seconds: number }
  | { kind: 'retry_reported'; agent_id: string; subagent_type: string;
      attempt: number; max_retries: number; retry_delay_ms: number;
      error_status: number | null; error_category: string }
  | { kind: 'retry_cleared'; agent_id: string; subagent_type: string }

type KeeperQuarantinedToolOccurrence = {
  toolStreamScope: number
  toolCallBlockIndex: number
  providerMessageId?: string
}

/** Side metadata for an exact model content occurrence, never body bytes,
 * tool progress, or proof that the whole response/turn has ended. */
export type KeeperModelContentActivity = {
  generation: number
  stream_scope: number
  block_index: number
  provider_message_id?: string
  channel: 'text' | 'thinking'
  state: 'observed' | 'ended'
}

type KeeperChatCustomEvent =
  | { type: 'CUSTOM'; name: 'KEEPER_CONNECTED'; value: null }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_RUNTIME_ATTEMPT_STARTED'
      value: {
        runtime_id?: string
        attempt_index?: number
      } | null
    }
  // #29650 added these two to the name list above and to the SSE field table,
  // but not here, so a decoded frame could not be handed to a handler that
  // takes a KeeperChatStreamEvent. The fields match sse.ts's allowedFields.
  | {
      type: 'CUSTOM'
      name: 'KEEPER_TOOL_APPROVAL_REQUESTED'
      value: {
        tool_call_id: string
        tool_call_name: string
        args: string
        question: string
        because?: string
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_TOOL_APPROVAL_SETTLED'
      value: { tool_call_id: string; outcome: string }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_CHAT_BATCH_BOUND'
      value: { operation_id: string; execution_id: string }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_CHAT_OPERATION_ACCEPTED'
      value: {
        operation_id: string
        state: 'Queued' | 'Running' | 'Succeeded' | 'Failed' | 'Cancelled'
        queued_count: number
        interactive?: KeeperInteractiveReceipt
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_STREAM_MESSAGE_START'
      value: {
        stream_scope: number
        provider_message_id?: string
        model?: string
        usage?: KeeperStreamUsage
      }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_STREAM_MESSAGE_DELTA'
      value: { stream_scope: number; stop_reason?: string; usage?: KeeperStreamDeltaUsage }
    }
  | { type: 'CUSTOM'; name: 'KEEPER_STREAM_MESSAGE_STOP'; value: null }
  | { type: 'CUSTOM'; name: 'KEEPER_STREAM_PING'; value: null }
  | { type: 'CUSTOM'; name: 'KEEPER_NATIVE_TOOL_START'; value: KeeperNativeToolObservation }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_NATIVE_TOOL_END'
      // Older streams omit completion: only an end was observed.
      value: KeeperNativeToolObservation & { completion?: KeeperNativeToolCompletion }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_NATIVE_TOOL_PROGRESS'
      value: KeeperNativeToolObservation & { progress: KeeperNativeToolProgress }
    }
  | {
      type: 'CUSTOM'
      name: 'KEEPER_TOOL_RESULT_READY'
      value: KeeperToolStreamOccurrence & { executionId: string }
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
  | { type: 'CUSTOM'; name: 'KEEPER_MODEL_CONTENT_ACTIVITY'; value: KeeperModelContentActivity }
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
        quarantined_occurrence?: KeeperQuarantinedToolOccurrence
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
      value: {
        reply?: string
        turn_outcome?: KeeperTurnOutcome
        turn_ref?: string
        terminal_stream_scope?: number
      }
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
  | { type: 'TEXT_MESSAGE_CONTENT'; messageId?: string; delta?: string; textStreamScope?: number }
  | { type: 'TEXT_MESSAGE_END'; messageId?: string }
  | (KeeperToolStreamOccurrence & { type: 'TOOL_CALL_START'; toolCallName?: string })
  | (KeeperToolStreamOccurrence & { type: 'TOOL_CALL_ARGS'; delta?: string; snapshot?: string })
  | (KeeperToolStreamOccurrence & { type: 'TOOL_CALL_END' })
  | KeeperChatCustomEvent
)
