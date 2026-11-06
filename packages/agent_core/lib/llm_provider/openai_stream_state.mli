(** Openai_stream_state — request-local state of the stream converters.

    One value belongs to one HTTP request and one sequential stream decoder; it
    is never shared across fibers or domains. The OpenAI Chat, Responses, Gemini
    and Ollama converters in {!Streaming} keep their block indices, tool
    identities and thinking state here.

    The converters read and write the fields directly, so the record is visible
    in this interface. Outside the library the state is abstract:
    {!Streaming.openai_stream_state} hides the fields, and this module is
    private to the library. *)

open Types

(** {1 State} *)

type thinking_state =
  | Not_thinking
  | Thinking_started of float
  | Thinking_done

(** How a tool-call wire index routes to blocks. *)
type tool_index_route =
  | Tool_index_single of int
  | Tool_index_ambiguous of int list

(** Who named a tool call: the provider sent its id, or AGENT_CORE allocated
    one because the provider sent none. *)
type tool_identity_origin =
  | Provider_supplied
  | Agent_core_allocated

type tool_block_identity =
  { id : string
  ; origin : tool_identity_origin
  }

(** Which kind of block the inline-reasoning splitter writes into. *)
type inline_channel

type openai_prelude =
  | Awaiting_reported_metadata
  | Reported_prelude_published
  | Output_without_prelude

(** Request-local mutable state for converting OpenAI flat deltas to block-based
    events. One sequential stream decoder owns each value; it is never shared
    across fibers or domains. *)
type openai_stream_state =
  { mutable thinking_block_started : bool
  ; mutable thinking_block_index : int
  ; mutable reasoning_details_index : int option
  ; mutable inline_raw_rev : string list
  ; mutable inline_indices_rev : int list
  ; mutable inline_active_block : (inline_channel * int) option
  ; mutable text_block_started : bool
  ; mutable text_block_index : int
  ; tool_blocks_by_id : (string, int) Hashtbl.t
    (** Secondary lookup index from tool identity to normalized block index.
        [tool_block_identities] remains the identity authority. *)
  ; tool_block_indices : (int, tool_index_route) Hashtbl.t
    (** tool_call wire index -> routing state. Id-less continuation fragments
        can route only while the wire index maps to one known block. Once more
        than one id has used the same wire index, id-less fragments are
        ambiguous and must fail loud rather than silently picking the last
        writer. *)
  ; tool_block_identities : (int, tool_block_identity) Hashtbl.t
    (** Normalized block index -> the identity emitted at block start.  This is
        the sole identity authority for an open tool block. *)
  ; responses_text_blocks : (int * int, int) Hashtbl.t
  ; responses_thinking_blocks : (int, int) Hashtbl.t
  ; responses_reasoning : (int, Responses_reasoning_stream.t) Hashtbl.t
  ; responses_output_ids : (int, string) Hashtbl.t
  ; responses_output_kinds : (int, Response_replay.kind) Hashtbl.t
  ; responses_output_groups : (int, Response_replay.kind * int list) Hashtbl.t
    (** Responses-only native identities. Chat's transactional projection never
        reads or mutates these tables. *)
  ; mutable next_block_index : int
  ; mutable thinking_state : thinking_state
  ; mutable gemini_message_model : Model_id.t option
  ; mutable openai_prelude : openai_prelude
  ; mutable refusal_seen : bool
  ; preserve_inline_content : bool
  ; inline_reasoning : Inline_reasoning_split.state option
    (** Present only for a model whose content channel can also carry
        reasoning wrapped in tags (template-parser dialect or declared
        think-tags): drawing that as speech is what put a wall of thinking
        where the reply belonged. A model that does not declare it keeps
        every byte of its content. *)
  ; provider : string
  ; model : string
  }

(** The arguments are documented on {!Streaming.create_openai_stream_state}. *)
val create_openai_stream_state
  :  ?provider:string
  -> ?model:string
  -> ?inline_reasoning:bool
  -> ?preserve_inline_content:bool
  -> unit
  -> openai_stream_state

(** {1 Projection transaction}

    A tool-bearing chunk commits its events together with the state changes
    they caused, or rolls both back. *)

(** A snapshot of the scalar fields and the inline splitter, plus an undo log
    of the tool-table changes made through [?tx]. *)
type openai_projection_tx

val begin_openai_projection : openai_stream_state -> openai_projection_tx

(** Restores the snapshot and undoes the logged tool-table changes. *)
val rollback_openai_projection : openai_projection_tx -> unit

(** {1 Tool block resolution} *)

(** Which block index a newly opened tool block takes: the next unused index
    or the one after it. *)
type tool_block_index_policy =
  | Next_available
  | Next_after_carrier

type idless_tool_semantics =
  (* Argument fragments continue the one call selected by the wire index. *)
  | Continue_by_wire_index
  (* Each complete provider item is a new call occurrence.  Identical
      name/arguments must not collapse into one identity. *)
  | Complete_occurrence

type tool_block_resolution =
  | Tool_block_resolved of
      { block_index : int
      ; identity : tool_block_identity
      }
  | Tool_block_rejected of sse_event
      (** An [SSEParseFailed] naming the conflict: a late provider identity, an
          ambiguous id-less continuation and so on. *)

(** [Some id] for a non-blank provider tool id, [None] for a blank or missing one. *)
val non_blank_provider_tool_id : string option -> string option

(** Finds the block a tool-call delta belongs to, or opens one. The second
    component is the [ContentBlockStart] of a block this call opened. [?tx]
    logs the table changes so that {!rollback_openai_projection} can undo them. *)
val resolve_tool_block
  :  ?tx:openai_projection_tx
  -> openai_stream_state
  -> protocol:string
  -> wire_index:int
  -> provider_tool_id:string option
  -> tool_name:string option
  -> index_policy:tool_block_index_policy
  -> idless_semantics:idless_tool_semantics
  -> tool_block_resolution * sse_event option

(** {1 Block stops and inline segments} *)

(** OpenAI-compatible streams carry no wire [content_block_stop] event (unlike
    Anthropic, whose stops are parsed straight off the wire). Synthesize one
    [ContentBlockStop] per block this state opened so the emitted AGENT_CORE
    event sequence stays symmetric: every [ContentBlockStart] gets a matching
    [ContentBlockStop]. The stream accumulator ignores stops, but block-lifecycle
    consumers depend on them — a stop closes a tool block so the NEXT provider
    message (a separate stream whose block indices restart at 0) reuses the same
    index without colliding with a still-open block, and so a tool-call-end is
    surfaced for that block. Called once on the terminal [finish_reason] chunk;
    blank/missing-finish chunks never close blocks. *)
val openai_open_block_stops : openai_stream_state -> sse_event list

(** Emits the splitter's segments as text or thinking blocks, closing the
    previous inline block when the channel changes. *)
val emit_inline_segments
  :  openai_stream_state
  -> (sse_event -> unit)
  -> Inline_reasoning_split.segment list
  -> unit
