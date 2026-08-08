(** Stream accumulator: gather SSE events into a {!Types.api_response}.

    Depends only on [Types] -- no provider/backend/transport references.

    @since 0.79.0

    @stability Internal
    @since 0.93.1 *)

(** Mutable accumulator that collects SSE stream events into content blocks.
    Use {!create_stream_acc} to create, {!accumulate_event} to feed events,
    and {!finalize_stream_acc} to produce the final response. *)
type stream_acc =
  { id : string ref
  ; model : string ref
  ; input_tokens : int ref
  ; output_tokens : int ref
  ; cache_creation : int ref
  ; cache_read : int ref
  ; stop_reason : Types.stop_reason ref
  ; stop_reason_received : bool ref
  ; done_sentinel_seen : bool ref
    (** Set when a {!Types.MessageStop} is observed: the provider sent an
        explicit terminal sentinel (e.g. the OpenAI-compatible [data: [DONE]]
        line or an Anthropic [message_stop]). Distinguishes a stream that
        completed without a [finish_reason]/[stop_reason] from one truncated by
        a dropped connection; {!finalize_stream_acc} uses it to default
        {!stop_reason} (EndTurn) instead of rejecting a phantom completion. *)
  ; terminal_incomplete : bool ref
  ; sse_error : Types.stream_error option ref
  ; block_texts : (int, Buffer.t) Hashtbl.t
  ; block_types : (int, string) Hashtbl.t
  ; block_tool_ids : (int, string) Hashtbl.t
  ; block_tool_names : (int, string) Hashtbl.t
  ; block_thinking_signatures : (int, Buffer.t) Hashtbl.t
  ; block_reasoning_details : (int, Types.reasoning_detail list ref) Hashtbl.t
  ; block_media_types : (int, string) Hashtbl.t
    (** Per-block media MIME type from {!Types.MediaDelta}; payload is in
        {!block_texts}. *)
  ; block_media_sources : (int, Types.media_source_kind) Hashtbl.t
    (** Per-block media source kind from {!Types.MediaDelta}. *)
  }

(** Create a fresh accumulator with empty defaults. *)
val create_stream_acc : unit -> stream_acc

(** [true] after the first typed provider/wire parse failure. Callers use this
    terminal state to suppress trailing success events without erasing the
    original failure. *)
val stream_failed : stream_acc -> bool

(** Feed a single SSE event into the accumulator.
    Updates id, model, tokens, content blocks in-place. *)
val accumulate_event : stream_acc -> Types.sse_event -> unit

(** Produce the final {!Types.api_response} from the accumulated state.
    Returns [Error stream_error] if an SSE error was recorded during the stream
    (typed so the consumer can route a provider-reported error through the same
    classification path as a non-streaming error); content blocks are ordered by
    their stream index. *)
val finalize_stream_acc : stream_acc -> (Types.api_response, Types.stream_error) result
