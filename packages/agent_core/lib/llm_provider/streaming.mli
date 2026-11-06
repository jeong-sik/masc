(** SSE event parsing for Anthropic and Openai streaming APIs.

    Pure functions — no I/O or agent_core coupling.

    @stability Internal
    @since 0.93.1 *)

open Types

(** {1 Anthropic SSE} *)

val parse_sse_event : string option -> string -> sse_event option
val emit_synthetic_events : api_response -> (sse_event -> unit) -> unit
(** Preserves exact inline Chat content replay through the synthetic stream.
    Native Chat inline streams emit a terminal InlineContentReplay witness;
    rejected chunks roll back both carrier bytes and occurrence identities. *)

(** {1 First-token classification (Agent Core contract)}

    These predicates distinguish *prelude / scheduling* events
    (which set [prefill_ms] in [Streaming_summary]) from
    *first-token* events (which set [ttft_ms]). The capture site
    is [Complete_stream] §publish_summary. *)

(** [true] when the SSE event represents the first generated
    content. That means a [ContentBlockDelta] carrying a
    non-empty [TextDelta] / [TextSnapshot] / [ThinkingDelta] / [ReasoningDetailsDelta] /
    [InputJsonDelta] / [InputJsonSnapshot] / [MediaDelta] /
    [RedactedThinkingSnapshot] payload, or the [ContentBlockStart] of a
    [redacted_thinking] block carrying its data: a redacted block is
    generated content the caller receives, so the model has produced.
    Prelude events ([MessageStart], every other [ContentBlockStart],
    [ThinkingSignatureDelta] carriers, [Ping]), terminator events
    ([MessageStop], [MessageDelta] with no usage), and error events return
    [false].

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

(** {1 Openai SSE}

    {!Openai_wire} reads one OpenAI-compatible payload into a chunk. The
    functions below turn the chunk into stream events with a request-local
    {!openai_stream_state}. *)

(** Request-local mutable normalization state, owned by one sequential stream
    decoder. Its representation is private so callers cannot bypass tool
    identity and block-routing invariants or share its tables directly. *)
type openai_stream_state

val create_openai_stream_state
  :  ?provider:string
  -> ?model:string
  -> ?inline_reasoning:bool
  -> ?preserve_inline_content:bool
  -> unit
  -> openai_stream_state
(** [inline_reasoning] says the model's content channel also carries reasoning
    wrapped in tags (template-parser dialect or declared think-tags), which is
    separated out rather than drawn as reply text. Defaults to [false], and a
    model that does not declare it keeps every byte of its content channel.
    [preserve_inline_content] is separately declared by the Chat replay contract;
    it retains scalar content deltas transactionally, including empty strings,
    without treating absent/null content as an empty scalar. *)

(** Emits one [MessageStart] from a complete, nonblank provider [chunk_id]
    and [chunk_model] pair, before this request publishes other events. Empty
    or partial metadata never uses the configured model as a reported value.
    If output has already been published without a complete pair, no later
    prelude is emitted: a late start would conflict with the existing content
    or reset consumer metadata. Later metadata does not create another response;
    each HTTP request owns its own normalization state. Tool-bearing chunks
    commit the prelude and content together, or roll back both on failure. *)
val openai_chunk_to_events
  :  openai_stream_state
  -> Openai_wire.openai_chunk
  -> sse_event list * Telemetry_event.t option

(** Convert every closed parser outcome into stream events. Malformed payloads
    become exactly one [SSEParseFailed], provider errors become exactly one
    [SSEError], and the terminal sentinel becomes [MessageStop]. *)
val openai_sse_parse_result_to_events
  :  openai_stream_state
  -> Openai_wire.openai_sse_parse_result
  -> sse_event list * Telemetry_event.t option

(** Convert one OpenAI Responses API streaming SSE payload into AGENT_CORE stream
    events. Responses streaming is item/event based, not Chat Completions delta
    based: output text, reasoning summaries, and function call arguments each
    have their own event family. *)
val responses_sse_to_events
  :  openai_stream_state
  -> string option
  -> string
  -> sse_event list * Telemetry_event.t option

(** Read a response body that carried no SSE [data:] payload at all as a
    provider error event when it is a JSON error envelope, [None] otherwise.
    [raw] is the evidence the event carries; [body] is what gets parsed. *)
val sse_error_event_of_bodiless_body : raw:string -> string -> Types.sse_event option

(** {1 Gemini SSE}

    {!Gemini_wire} reads one Gemini payload into a chunk. This turns the
    chunk into stream events, reusing {!openai_stream_state} for block
    tracking since the state management pattern is identical. *)

type gemini_chunk_to_events_error = { reason : string }

val gemini_chunk_to_events
  :  openai_stream_state
  -> Gemini_wire.gemini_chunk
  -> (sse_event list * Telemetry_event.t option, gemini_chunk_to_events_error) result

(** {1 Ollama NDJSON Streaming}

    {!Ollama_wire} reads one Ollama [/api/chat] line into a chunk. The
    function below turns the chunk into stream events.

    State management reuses {!openai_stream_state} since the block
    tracking pattern is identical. Tool calls in Ollama typically
    arrive fully-formed in the [done:true] line, so the streaming
    consumer treats them as a single delta rather than incremental.

    @since 0.171.0 *)

(** Convert a parsed {!Ollama_wire.ollama_chunk} into {!sse_event} list.
    Synthesises [ContentBlockStart] events on first occurrence of
    text / thinking content and on each new tool_call. The terminal
    [done:true] chunk also emits [MessageDelta] carrying the
    stop_reason and any token-count usage. *)
val ollama_chunk_to_events
  :  openai_stream_state
  -> Ollama_wire.ollama_chunk
  -> sse_event list * Telemetry_event.t option
