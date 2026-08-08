(** SSE event parsing for Anthropic and Openai streaming APIs.

    Pure functions — no I/O or agent_sdk coupling.

    @stability Internal
    @since 0.93.1 *)

open Types

(** {1 Anthropic SSE} *)

val parse_sse_event : string option -> string -> sse_event option
val emit_synthetic_events : api_response -> (sse_event -> unit) -> unit

(** {1 First-token classification (RFC-OAS-020)}

    These predicates distinguish *prelude / scheduling* events
    (which set [prefill_ms] in [Streaming_summary]) from
    *first-token* events (which set [ttft_ms]). The capture site
    is [Complete] §publish_summary. *)

(** [true] when the SSE event represents the first generated
    token delta. That means a [ContentBlockDelta] carrying a
    non-empty [TextDelta] / [ThinkingDelta] / [ReasoningDetailsDelta] /
    [InputJsonDelta] / [InputJsonSnapshot] payload. Prelude events
    ([MessageStart], [ContentBlockStart], [ThinkingSignatureDelta] carriers,
    [Ping]), terminator events ([MessageStop], [MessageDelta] with no usage),
    and error events return [false].

    @stability Internal *)
val sse_event_is_first_token_signal : sse_event -> bool

(** [true] when the SSE event represents progress that a downstream
    application can act on without exposing model-private reasoning:
    non-empty text, non-empty tool-call JSON, or a tool-use block start.
    Thinking/reasoning details deltas intentionally return [false]. Complete
    uses this to distinguish "the model is generating hidden reasoning" from
    "the stream has produced a deliverable answer/tool signal".

    @stability Internal
    @since 0.205.12 *)
val sse_event_is_deliverable_progress_signal : sse_event -> bool

(** {1 Openai SSE} *)

(** Wire shape of streamed tool-call arguments. [Args_fragment] is an incremental
    string chunk the accumulator appends; [Args_complete] is a whole JSON-value
    snapshot serialized in a single delta, which replaces the block buffer so a
    re-emitted snapshot does not concatenate into invalid JSON. Each codec and
    the completed ToolUse boundary validate the value shape they allow. *)
type tool_call_arguments =
  | Args_fragment of string
  | Args_complete of string

type openai_tool_call_delta =
  { tc_index : int
  ; tc_id : string option
  ; tc_name : string option
  ; tc_arguments : tool_call_arguments option
  }

type openai_reasoning_details_delta =
  { delta_reasoning_content : string option
  ; delta_details : reasoning_detail list
  }

type openai_chunk_parse_error =
  { reason : string
  ; raw : string
  }

type openai_chunk =
  { chunk_id : string
  ; chunk_model : string
  ; delta_content : string option
  ; delta_reasoning : string option
  ; delta_reasoning_details : openai_reasoning_details_delta option
  ; delta_tool_calls : openai_tool_call_delta list
  ; finish_reason : string option
  ; chunk_usage : api_usage option
  }

(** Closed classification of one OpenAI-compatible SSE data payload. Parsing
    never collapses malformed data into an absent chunk: callers must handle a
    terminal sentinel, an intentional empty chunk, a provider error, or a
    protocol parse failure explicitly. *)
type openai_sse_parse_result =
  | Openai_chunk of openai_chunk
  | Openai_done
  | Openai_empty
  | Openai_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Openai_parse_failed of openai_chunk_parse_error

(** Request-local mutable normalization state, owned by one sequential stream
    decoder. Its representation is private so callers cannot bypass tool
    identity and block-routing invariants or share its tables directly. *)
type openai_stream_state

val parse_openai_sse_chunk
  :  ?streaming_reasoning:Reasoning_dialect.streaming_reasoning
  -> string
  -> openai_sse_parse_result

(** RFC-OAS-020: [true] when the chunk carries either a non-empty
    [delta_content] or a non-empty [delta_reasoning] or any
    [delta_tool_calls] — that is, the consumer would surface a
    visible token (or tool-call argument) to the application. Used
    by the TTFT capture point in [Complete] to distinguish prelude
    chunks (empty role-only deltas, finish-only chunks) from the
    first real token.

    @stability Internal *)
val chunk_has_non_empty_delta : openai_chunk -> bool

val create_openai_stream_state
  :  ?provider:string
  -> ?model:string
  -> unit
  -> openai_stream_state

val openai_chunk_to_events
  :  openai_stream_state
  -> openai_chunk
  -> sse_event list * Telemetry_event.t option

(** Convert every closed parser outcome into stream events. Malformed payloads
    become exactly one [SSEParseFailed], provider errors become exactly one
    [SSEError], and the terminal sentinel becomes [MessageStop]. *)
val openai_sse_parse_result_to_events
  :  openai_stream_state
  -> openai_sse_parse_result
  -> sse_event list * Telemetry_event.t option

(** Convert one OpenAI Responses API streaming SSE payload into OAS stream
    events. Responses streaming is item/event based, not Chat Completions delta
    based: output text, reasoning summaries, and function call arguments each
    have their own event family. *)
val responses_sse_to_events
  :  openai_stream_state
  -> string option
  -> string
  -> sse_event list * Telemetry_event.t option

(** {1 Gemini SSE}

    Gemini [streamGenerateContent?alt=sse] emits SSE chunks with
    [{candidates: [{content: {parts: [...]}}]}] structure per chunk.
    We reuse {!openai_stream_state} for block tracking since the
    state management pattern is identical. *)

type gemini_terminal_reason =
  | Gemini_candidate_finish_reason of string
  | Gemini_prompt_block_reason of string

type gemini_chunk =
  { gem_model : string option
  ; gem_parts : Yojson.Safe.t list
  ; gem_finish_reason : gemini_terminal_reason option
  ; gem_usage : api_usage option
  }

type gemini_unsupported_part =
  | Gemini_executable_code
  | Gemini_code_execution_result
  | Gemini_tool_call
  | Gemini_tool_response
  | Gemini_function_response
  | Gemini_file_data
  | Gemini_audio_transcription
  | Gemini_streaming_function_call_arguments
  | Gemini_streaming_function_call_continuation

type gemini_unsupported_response = Gemini_multiple_candidates of { count : int }

type gemini_sse_parse_result =
  | Gemini_chunk of gemini_chunk
  | Gemini_unsupported_part of
      { part : gemini_unsupported_part
      ; raw : string
      }
  | Gemini_unsupported_response of
      { response : gemini_unsupported_response
      ; raw : string
      }
  | Gemini_parse_failed of
      { reason : string
      ; raw : string
      }

(** Parse one Gemini SSE data payload without collapsing malformed JSON or
    malformed candidate/part shapes into an absent chunk. Official Part kinds
    that OAS does not project are returned as [Gemini_unsupported_part], not
    relabelled as malformed bytes. Official response shapes that OAS does not
    project are returned as [Gemini_unsupported_response]. Callers must surface
    either capability fact with the raw payload. *)
val parse_gemini_sse_chunk : string -> gemini_sse_parse_result

val gemini_unsupported_part_wire_name : gemini_unsupported_part -> string
val gemini_unsupported_response_wire_name : gemini_unsupported_response -> string

type gemini_chunk_to_events_error = { reason : string }

val gemini_chunk_to_events
  :  openai_stream_state
  -> gemini_chunk
  -> (sse_event list * Telemetry_event.t option, gemini_chunk_to_events_error) result

(** {1 Ollama NDJSON Streaming}

    Ollama [/api/chat] with [stream:true] emits one JSON object per
    line (newline-delimited JSON, NDJSON). The final line carries
    [done:true] together with [done_reason] and the
    [prompt_eval_count] / [prompt_eval_duration] /
    [eval_count] / [eval_duration] timing fields that the Openai
    compat path on [/v1/chat/completions] strips out.

    State management reuses {!openai_stream_state} since the block
    tracking pattern is identical. Tool calls in Ollama typically
    arrive fully-formed in the [done:true] line, so the streaming
    consumer treats them as a single delta rather than incremental.

    @since 0.171.0 *)

type ollama_tool_call_delta =
  { oll_tc_index : int
  ; oll_tc_id : string option
  ; oll_tc_name : string option
  ; oll_tc_arguments : tool_call_arguments option
    (** Tool-call arguments as they arrive on the wire. *)
  }

type ollama_chunk =
  { oll_model : string
  ; oll_delta_content : string option
  ; oll_delta_thinking : string option
  ; oll_tool_calls : ollama_tool_call_delta list
  ; oll_done_reason : string option
  ; oll_is_done : bool
  ; oll_usage : api_usage option
  ; oll_timings : inference_timings option
  }

type ollama_ndjson_parse_result =
  | Ollama_chunk of ollama_chunk
  | Ollama_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Ollama_parse_failed of
      { reason : string
      ; raw : string
      }

(** Parse one NDJSON line without collapsing provider errors or malformed
    records into an absent chunk. The Ollama error envelope is a provider
    fact; missing or incorrectly typed data fields are wire failures. When a
    provider error object omits [message], [message] stays empty and the
    original payload remains available only through [raw]. *)
val parse_ollama_ndjson_chunk : string -> ollama_ndjson_parse_result

(** Convert a parsed {!ollama_chunk} into {!sse_event} list.
    Synthesises [ContentBlockStart] events on first occurrence of
    text / thinking content and on each new tool_call. The terminal
    [done:true] chunk also emits [MessageDelta] carrying the
    stop_reason and any token-count usage. *)
val ollama_chunk_to_events
  :  openai_stream_state
  -> ollama_chunk
  -> sse_event list * Telemetry_event.t option
