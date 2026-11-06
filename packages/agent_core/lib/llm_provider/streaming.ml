(** SSE event parsing and synthetic event emission.

    Pure functions operating on {!Llm_provider.Types}. No agent_core coupling.
    The streaming HTTP client (create_message_stream) remains in agent_core. *)

open Types

let event_type_of_payload event_type json : (string, string) result =
  match json with
  | `Assoc fields ->
    (match event_type with
     | Some value when not (Api_common.string_is_blank value) -> Ok value
     | Some _ -> Error "sse_event_type_blank"
     | None ->
       (match List.assoc_opt "type" fields with
        | Some (`String value) when not (Api_common.string_is_blank value) -> Ok value
        | Some (`String _) -> Error "sse_event_type_blank"
        | Some _ -> Error "sse_event_type_not_string"
        | None -> Error "sse_event_type_missing"))
  | _ -> Error "sse_payload_must_be_object"
;;

(** Parse a single SSE data JSON payload into an [sse_event]. *)
let parse_sse_event event_type data_str =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string data_str in
    match event_type_of_payload event_type json with
    | Error reason -> Some (SSEParseFailed { raw = data_str; reason })
    | Ok evt_type ->
      (match evt_type with
       | "message_start" ->
         let msg = json |> member "message" in
         let id = msg |> member "id" |> to_string in
         let model = msg |> member "model" |> to_string in
         let usage =
           let u = msg |> member "usage" in
           if u = `Null
           then None
           else (
             let input_tokens = u |> member "input_tokens" |> to_int in
             let cache_creation_input_tokens =
               u
               |> member "cache_creation_input_tokens"
               |> to_int_option
               |> Option.value ~default:0
             in
             let cache_read_input_tokens =
               u
               |> member "cache_read_input_tokens"
               |> to_int_option
               |> Option.value ~default:0
             in
             (* The start snapshot seeds every counter; a later cumulative
                message_delta replaces the ones it reports (#28903). *)
             Some
               (Backend_anthropic.usage_of_wire_counts
                  ~input_tokens
                  ~output_tokens:
                    (Cli_common_json.member_int "output_tokens" u)
                  ~cache_creation_input_tokens
                  ~cache_read_input_tokens))
         in
         Some (MessageStart { id; model; usage })
       | "content_block_start" ->
         let index = json |> member "index" |> to_int in
         let cb = json |> member "content_block" in
         let content_type = cb |> member "type" |> to_string in
         let tool_id =
           match content_type with
           | "redacted_thinking" -> cb |> member "data" |> to_string_option
           | _ -> cb |> member "id" |> to_string_option
         in
         let tool_name = cb |> member "name" |> to_string_option in
         let non_blank_tool_id =
           match tool_id with
           | Some id when not (Api_common.string_is_blank id) -> Some id
           | Some _ | None -> None
         in
         (match content_type, non_blank_tool_id with
          | "tool_use", None ->
            Some
              (SSEParseFailed
                 { raw = Printf.sprintf "anthropic tool_use index %d" index
                 ; reason =
                     Printf.sprintf
                       "malformed_tool_use:index:%d:missing_provider_id"
                       index
                 })
          | "tool_use", Some tool_id ->
            Some
              (ContentBlockStart
                 { index; content_type; tool_id = Some tool_id; tool_name })
          | _, _ -> Some (ContentBlockStart { index; content_type; tool_id; tool_name }))
       | "content_block_delta" ->
         let index = json |> member "index" |> to_int in
         let delta_json = json |> member "delta" in
         let delta_type = delta_json |> member "type" |> to_string in
         let delta =
           match delta_type with
           | "text_delta" -> TextDelta (delta_json |> member "text" |> to_string)
           | "thinking_delta" ->
             ThinkingDelta (delta_json |> member "thinking" |> to_string)
           | "signature_delta" ->
             ThinkingSignatureDelta (delta_json |> member "signature" |> to_string)
           | "input_json_delta" ->
             InputJsonDelta (delta_json |> member "partial_json" |> to_string)
           | unknown_delta_type ->
             raise
               (Yojson.Safe.Util.Type_error
                  ( "unsupported content_block_delta type: " ^ unknown_delta_type
                  , delta_json ))
         in
         Some (ContentBlockDelta { index; delta })
       | "content_block_stop" ->
         let index = json |> member "index" |> to_int in
         Some (ContentBlockStop { index })
       | "message_delta" ->
         let delta = json |> member "delta" in
         let stop_reason =
           delta
           |> member "stop_reason"
           |> to_string_option
           |> Option.map stop_reason_of_string
         in
         let usage : Types.delta_usage option =
           let u = json |> member "usage" in
           if u = `Null
           then None
           else (
             (* message_delta usage is wire-cumulative (official streaming
                contract): every reported field is the message's running
                total, so each is carried as present-or-absent for the
                accumulator to replace, never add (#28903). The wire's
                input_tokens is exclusive; when the delta reports it, the
                same report carries the cache components it accounts
                against, so the inclusive normalization uses those
                (an unreported cache field in that report reads as 0, the
                api_usage convention). *)
             let output_tokens = u |> member "output_tokens" |> to_int in
             let cache_creation_input_tokens =
               u |> member "cache_creation_input_tokens" |> to_int_option
             in
             let cache_read_input_tokens =
               u |> member "cache_read_input_tokens" |> to_int_option
             in
             let input_tokens =
               u
               |> member "input_tokens"
               |> to_int_option
               |> Option.map (fun exclusive_input ->
                 (* DET-OK: absent wire field is 0 by api_usage convention *)
                 exclusive_input
                 + Option.value cache_creation_input_tokens ~default:0
                 (* DET-OK: absent wire field is 0 by api_usage convention *)
                 + Option.value cache_read_input_tokens ~default:0)
             in
             Some
               { Types.input_tokens
               ; output_tokens = Some output_tokens
               ; cache_creation_input_tokens
               ; cache_read_input_tokens
               ; cost_usd = None
               })
         in
         Some (MessageDelta { stop_reason; usage })
       | "message_stop" -> Some MessageStop
       | "ping" -> Some Ping
       | "error" ->
         let err = json |> member "error" in
         let message =
           match err |> member "message" |> to_string_option with
           | Some m -> m
           | None -> Openai_error_envelope.missing_message
         in
         let error_type = err |> member "type" |> to_string_option in
         Some
           (SSEError
              { message
              ; error_type
              ; provider_status = None
              ; report = Types.Provider_stated
              ; raw = data_str
              })
       | other -> Some (SSEUnknownEventType { event_type = other; raw = data_str }))
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Some (SSEParseFailed { raw = data_str; reason = "type_error: " ^ msg })
  | Yojson.Json_error msg ->
    Some (SSEParseFailed { raw = data_str; reason = "json_error: " ^ msg })
;;

(* Agent Core contract: TTFT classification — distinguishes prelude events
   ([MessageStart], a [ContentBlockStart] that carries no content, [Ping])
   from the first generated content. Capture point in [Complete_stream] uses this
   to fill [Streaming_summary.ttft_ms] and to end the first-event budget. *)
let sse_event_is_first_token_signal (e : sse_event) : bool =
  let non_empty s = String.length s > 0 in
  match e with
  | ContentBlockDelta { delta = TextDelta s | TextSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = ThinkingDelta s | ThinkingSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = ReasoningDetailsDelta { reasoning_content; details }; _ }
    ->
    (match reasoning_content with
     | Some s when non_empty s -> true
     | Some _ | None -> details <> [])
  | ContentBlockDelta { delta = InputJsonDelta s | InputJsonSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = MediaDelta { source; _ }; _ } ->
    non_empty (Types.media_source_payload source)
  (* A redacted thinking block is generated content the caller receives
     ([Types.RedactedThinking]): the model has produced, so the first-event
     wait is over and TTFT is measured to it. Anthropic delivers the whole
     block in its [content_block_start], with the payload in [tool_id]. *)
  | ContentBlockStart { content_type = "redacted_thinking"; tool_id = Some data; _ } ->
    not (Api_common.string_is_blank data)
  | ContentBlockDelta { delta = RedactedThinkingSnapshot data; _ } -> non_empty data
  | ContentBlockDelta { delta = ThinkingSignatureDelta _; _ } -> false
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | InlineContentReplay _ | ResponsesOutputItems _ | Ping
  | SSEError _
  | NDJSONError _
  | SSEParseFailed _
  | NDJSONParseFailed _
  | SSEUnknownEventType _
  | SSEUnsupportedPart _
  | SSEUnsupportedResponse _
  | Connected
  | Timeout _
  | StreamIncomplete _ -> false
;;

let sse_event_is_deliverable_progress_signal (e : sse_event) : bool =
  let non_empty s = String.length s > 0 in
  match e with
  | ContentBlockDelta { delta = TextDelta s | TextSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = InputJsonDelta s | InputJsonSnapshot s; _ } -> non_empty s
  | ContentBlockDelta { delta = MediaDelta { source; _ }; _ } ->
    non_empty (Types.media_source_payload source)
  | ContentBlockStart { content_type = "tool_use"; _ } -> true
  | ContentBlockDelta { delta = ThinkingSignatureDelta _; _ }
  | ContentBlockDelta { delta = RedactedThinkingSnapshot _; _ }
  | ContentBlockDelta { delta = (ThinkingDelta _ | ThinkingSnapshot _); _ }
  | ContentBlockDelta { delta = ReasoningDetailsDelta _; _ }
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | InlineContentReplay _ | ResponsesOutputItems _ | Ping
  | SSEError _
  | NDJSONError _
  | SSEParseFailed _
  | NDJSONParseFailed _
  | SSEUnknownEventType _
  | SSEUnsupportedPart _
  | SSEUnsupportedResponse _
  | Connected
  | Timeout _
  | StreamIncomplete _ -> false
;;

(** Emit synthetic SSE events from a complete [api_response].
    Used as fallback for non-Anthropic providers that don't support SSE.

    An unreadable tool call is emitted as the tool block it was on the wire,
    at its [tool_use_ordinal] among the tool calls, with its argument text as a
    snapshot. A consumer that counts tool blocks then sees what a stream would
    have shown it, and the accumulator classifies the call again on its own. *)
let emit_synthetic_events (response : api_response) on_event =
  on_event
    (MessageStart { id = response.id; model = response.model; usage = response.usage });
  let next_index = ref 0 in
  let next_tool_ordinal = ref 0 in
  (* Emission walks the calls in ordinal order; the response does not promise
     its list is in that order. *)
  let pending_unreadable =
    ref
      (List.stable_sort
         (fun (a : unreadable_tool_use) (b : unreadable_tool_use) ->
            Int.compare a.tool_use_ordinal b.tool_use_ordinal)
         response.unreadable_tool_uses)
  in
  let take_index () =
    let index = !next_index in
    incr next_index;
    index
  in
  let emit_unreadable (call : unreadable_tool_use) =
    let index = take_index () in
    incr next_tool_ordinal;
    on_event
      (ContentBlockStart
         { index
         ; content_type = "tool_use"
         ; tool_id = Some call.tool_use_id
         ; tool_name = Some call.tool_name
         });
    on_event (ContentBlockDelta { index; delta = InputJsonSnapshot call.arguments });
    on_event (ContentBlockStop { index })
  in
  let rec emit_unreadable_due () =
    match !pending_unreadable with
    | call :: rest when call.tool_use_ordinal <= !next_tool_ordinal ->
      pending_unreadable := rest;
      emit_unreadable call;
      emit_unreadable_due ()
    | _ :: _ | [] -> ()
  in
  let stream_indices =
    List.map
      (fun block ->
         let content_type, tool_id, tool_name =
           match block with
           | Text _ -> "text", None, None
           | Thinking _ -> "thinking", None, None
           | ReasoningDetails _ -> "reasoning_details", None, None
           | ToolUse { id; name; _ } -> "tool_use", Some id, Some name
           | Image _ -> "image", None, None
           | Document _ -> "document", None, None
           | Audio _ -> "audio", None, None
           | RedactedThinking data -> "redacted_thinking", Some data, None
           | ToolResult _ -> "text", None, None
         in
         (match block with
          | ToolUse _ -> emit_unreadable_due ()
          | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolResult _
          | Image _ | Document _ | Audio _ -> ());
         let index = take_index () in
         on_event (ContentBlockStart { index; content_type; tool_id; tool_name });
         (match block with
          | Text s -> on_event (ContentBlockDelta { index; delta = TextDelta s })
          | Thinking { content; signature } ->
            on_event (ContentBlockDelta { index; delta = ThinkingDelta content });
            (match signature with
             | Some s ->
               on_event (ContentBlockDelta { index; delta = ThinkingSignatureDelta s })
             | None -> ())
          | ReasoningDetails { reasoning_content; details } ->
            on_event
              (ContentBlockDelta
                 { index; delta = ReasoningDetailsDelta { reasoning_content; details } })
          | ToolUse { input; _ } ->
            incr next_tool_ordinal;
            on_event
              (ContentBlockDelta
                 { index; delta = InputJsonSnapshot (Yojson.Safe.to_string input) })
          | Image { media_type; source }
          | Document { media_type; source }
          | Audio { media_type; source } ->
            (* Re-emit media payload through the typed media channel so a
               non-streamed media block survives an api_response -> synthetic SSE
               -> accumulator round-trip instead of collapsing to empty text. *)
            on_event
              (ContentBlockDelta
                 { index; delta = MediaDelta { media_type; source } })
          | RedactedThinking _ | ToolResult _ -> ());
         on_event (ContentBlockStop { index });
         index)
      response.content
  in
  List.iter emit_unreadable !pending_unreadable;
  (* The start event already carried the complete usage; repeating it here
     would make any replace-or-add accumulator double-count. The synthetic
     delta only settles the stop reason. Inline replay names content
     positions; an unreadable call emitted before a block moves that block's
     stream index, so the positions are carried over to stream indices. *)
  (match Option.bind response.telemetry (fun telemetry -> telemetry.inline_content_replay) with
   | None -> ()
   | Some {Inline_content_replay.raw_content;block_indices} ->
     let stream_indices = Array.of_list stream_indices in
     let block_indices =
       List.map
         (fun position ->
            if position >= 0 && position < Array.length stream_indices
            then stream_indices.(position)
            else position)
         block_indices
     in
     on_event (InlineContentReplay {raw_content;block_indices}));
  on_event (MessageDelta { stop_reason = Some response.stop_reason; usage = None });
  on_event MessageStop
;;

let%test "emit_synthetic_events round-trips a media block through the accumulator" =
  (* A non-streamed api_response carrying an Image survives the synthetic-SSE
     fallback: emit_synthetic_events -> Complete_stream_acc -> finalize yields the
     same Image. Revert the media delta/content_type arms here (or the accumulator
     media arms) and the image collapses to empty text, so this goes red. This is
     the real producer that keeps the new MediaDelta path from being dead code. *)
  let image =
    Image { media_type = "image/png"; source = Types.Base64 "iVBORw0KGgo=" }
  in
  let response : api_response =
    { id = "msg_rt"
    ; model = "test-model"
    ; unreadable_tool_uses = []
    ; stop_reason = EndTurn
    ; content = [ image ]
    ; usage = None
    ; telemetry = None
    }
  in
  let events = ref [] in
  emit_synthetic_events response (fun e -> events := e :: !events);
  let acc = Complete_stream_acc.create_stream_acc () in
  List.iter (Complete_stream_acc.accumulate_event acc) (List.rev !events);
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error _ -> false
  | Ok result -> result.content = [ image ]
;;

(** {1 OpenAI-compatible SSE Streaming}

    Openai Chat Completions streaming uses SSE with flat deltas:
    - Text content arrives as [delta.content] strings
    - Tool calls arrive as [delta.tool_calls] with incremental arguments
    - [finish_reason] signals end of a choice
    - No explicit content_block_start/stop events (unlike Anthropic)

    {!Openai_wire} reads each SSE chunk into an {!Openai_wire.openai_chunk}.
    The functions below convert it to {!sse_event} list using a stateful
    adapter ({!openai_stream_state}). *)

open Openai_wire

(** Request-local mutable state for converting OpenAI flat deltas to block-based
    events. One sequential stream decoder owns each value; it is never shared
    across fibers or domains. *)
type thinking_state =
  | Not_thinking
  | Thinking_started of float
  | Thinking_done

type tool_index_route =
  | Tool_index_single of int
  | Tool_index_ambiguous of int list

type tool_identity_origin =
  | Provider_supplied
  | Agent_core_allocated

type tool_block_identity =
  { id : string
  ; origin : tool_identity_origin
  }

type inline_channel = Inline_text | Inline_thinking

type openai_prelude =
  | Awaiting_reported_metadata
  | Reported_prelude_published
  | Output_without_prelude

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
  ; responses_text_blocks : ((int * int), int) Hashtbl.t
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

let create_openai_stream_state
      ?(provider = "")
      ?(model = "")
      ?(inline_reasoning = false)
      ?(preserve_inline_content = false)
      ()
  =
  { thinking_block_started = false
  ; thinking_block_index = -1
  ; reasoning_details_index = None
  ; inline_raw_rev = []
  ; inline_indices_rev = []
  ; inline_active_block = None
  ; text_block_started = false
  ; text_block_index = -1
  ; tool_blocks_by_id = Hashtbl.create 4
  ; tool_block_indices = Hashtbl.create 4
  ; tool_block_identities = Hashtbl.create 4
  ; responses_text_blocks = Hashtbl.create 4
  ; responses_thinking_blocks = Hashtbl.create 4
  ; responses_reasoning = Hashtbl.create 4
  ; responses_output_ids = Hashtbl.create 4
  ; responses_output_kinds = Hashtbl.create 4
  ; responses_output_groups = Hashtbl.create 4
  ; next_block_index = 0
  ; thinking_state = Not_thinking
  ; gemini_message_model = None
  ; openai_prelude = Awaiting_reported_metadata
  ; refusal_seen = false
  ; preserve_inline_content
  ; inline_reasoning =
      (if inline_reasoning then Some (Inline_reasoning_split.create ()) else None)
  ; provider
  ; model
  }
;;

type openai_projection_scalar_snapshot =
  { snapshot_thinking_block_started : bool
  ; snapshot_thinking_block_index : int
  ; snapshot_reasoning_details_index : int option
  ; snapshot_inline_raw_rev : string list
  ; snapshot_inline_indices_rev : int list
  ; snapshot_inline_active_block : (inline_channel * int) option
  ; snapshot_text_block_started : bool
  ; snapshot_text_block_index : int
  ; snapshot_next_block_index : int
  ; snapshot_thinking_state : thinking_state
  ; snapshot_openai_prelude : openai_prelude
  ; snapshot_refusal_seen : bool
  }

type openai_projection_undo =
  | Undo_tool_block_by_id of string * int option
  | Undo_tool_index_route of int * tool_index_route option
  | Undo_tool_block_identity of int * tool_block_identity option

type openai_projection_tx =
  { state : openai_stream_state
  ; scalar_snapshot : openai_projection_scalar_snapshot
  ; inline_snapshot : (Inline_reasoning_split.state * Inline_reasoning_split.snapshot) option
  ; mutable undo : openai_projection_undo list
  }

let begin_openai_projection state =
  { state
  ; scalar_snapshot =
      { snapshot_thinking_block_started = state.thinking_block_started
      ; snapshot_thinking_block_index = state.thinking_block_index
      ; snapshot_reasoning_details_index = state.reasoning_details_index
      ; snapshot_inline_raw_rev = state.inline_raw_rev
      ; snapshot_inline_indices_rev = state.inline_indices_rev
      ; snapshot_inline_active_block = state.inline_active_block
      ; snapshot_text_block_started = state.text_block_started
      ; snapshot_text_block_index = state.text_block_index
      ; snapshot_next_block_index = state.next_block_index
      ; snapshot_thinking_state = state.thinking_state
      ; snapshot_openai_prelude = state.openai_prelude
      ; snapshot_refusal_seen = state.refusal_seen
      }
  ; inline_snapshot = Option.map (fun split -> split, Inline_reasoning_split.snapshot split) state.inline_reasoning
  ; undo = []
  }
;;

let restore_table_entry table key = function
  | Some value -> Hashtbl.replace table key value
  | None -> Hashtbl.remove table key
;;

let rollback_openai_projection tx =
  let state = tx.state in
  let snapshot = tx.scalar_snapshot in
  state.thinking_block_started <- snapshot.snapshot_thinking_block_started;
  state.thinking_block_index <- snapshot.snapshot_thinking_block_index;
  state.reasoning_details_index <- snapshot.snapshot_reasoning_details_index;
  state.inline_raw_rev <- snapshot.snapshot_inline_raw_rev;
  state.inline_indices_rev <- snapshot.snapshot_inline_indices_rev;
  state.inline_active_block <- snapshot.snapshot_inline_active_block;
  state.text_block_started <- snapshot.snapshot_text_block_started;
  state.text_block_index <- snapshot.snapshot_text_block_index;
  state.next_block_index <- snapshot.snapshot_next_block_index;
  state.thinking_state <- snapshot.snapshot_thinking_state;
  state.openai_prelude <- snapshot.snapshot_openai_prelude;
  state.refusal_seen <- snapshot.snapshot_refusal_seen;
  Option.iter (fun (split, captured) -> Inline_reasoning_split.restore split captured) tx.inline_snapshot;
  List.iter
    (function
      | Undo_tool_block_by_id (id, previous) ->
        restore_table_entry state.tool_blocks_by_id id previous
      | Undo_tool_index_route (index, previous) ->
        restore_table_entry state.tool_block_indices index previous
      | Undo_tool_block_identity (index, previous) ->
        restore_table_entry state.tool_block_identities index previous)
    tx.undo
;;

let tx_replace_tool_block_by_id tx id block_index =
  tx.undo
  <- Undo_tool_block_by_id (id, Hashtbl.find_opt tx.state.tool_blocks_by_id id) :: tx.undo;
  Hashtbl.replace tx.state.tool_blocks_by_id id block_index
;;

let tx_replace_tool_index_route tx index route =
  tx.undo
  <- Undo_tool_index_route (index, Hashtbl.find_opt tx.state.tool_block_indices index)
     :: tx.undo;
  Hashtbl.replace tx.state.tool_block_indices index route
;;

let tx_replace_tool_block_identity tx index identity =
  tx.undo
  <- Undo_tool_block_identity
       (index, Hashtbl.find_opt tx.state.tool_block_identities index)
     :: tx.undo;
  Hashtbl.replace tx.state.tool_block_identities index identity
;;

let tool_index_route_add_block route block_index =
  match route with
  | Tool_index_single existing when existing = block_index -> Tool_index_single existing
  | Tool_index_single existing ->
    Tool_index_ambiguous (List.sort_uniq Int.compare [ existing; block_index ])
  | Tool_index_ambiguous indices ->
    Tool_index_ambiguous (List.sort_uniq Int.compare (block_index :: indices))
;;

let record_tool_index_route ?tx state tool_index block_index =
  let route =
    match Hashtbl.find_opt state.tool_block_indices tool_index with
    | Some route -> tool_index_route_add_block route block_index
    | None -> Tool_index_single block_index
  in
  match tx with
  | Some tx -> tx_replace_tool_index_route tx tool_index route
  | None -> Hashtbl.replace state.tool_block_indices tool_index route
;;

type tool_block_index_policy =
  | Next_available
  | Next_after_carrier
  | Wire_index

type idless_tool_semantics =
  (* Argument fragments continue the one call selected by the wire index. *)
  | Continue_by_wire_index
  (* Each complete provider item is a new call occurrence.  Identical
      name/arguments must not collapse into one identity. *)
  | Complete_occurrence

type tool_route_failure =
  | Ambiguous_idless_continuation
  | Late_provider_identity
  | Provider_identity_route_conflict
  | Identity_index_conflict
  | Block_index_collision
  | Missing_block_identity

type tool_block_resolution =
  | Tool_block_resolved of
      { block_index : int
      ; identity : tool_block_identity
      }
  | Tool_block_rejected of sse_event

let non_blank_provider_tool_id = function
  | Some id when not (Api_common.string_is_blank id) -> Some id
  | Some _ | None -> None
;;

let tool_route_failure_reason = function
  | Ambiguous_idless_continuation ->
    "ambiguous_tool_call_index: id-less continuation follows multiple tool identities"
  | Late_provider_identity ->
    "late_provider_tool_call_id: provider identity arrived after an AGENT_CORE identity was \
     emitted"
  | Provider_identity_route_conflict ->
    "provider_tool_call_id_route_conflict: one provider identity used multiple wire \
     routes"
  | Identity_index_conflict ->
    "tool_identity_index_conflict: identity lookup and block authority disagree"
  | Block_index_collision ->
    "tool_block_index_collision: distinct tool identities require the same normalized \
     block"
  | Missing_block_identity ->
    "missing_tool_block_identity: tool route references a block without identity state"
;;

let reject_tool_block ~protocol ~wire_index failure =
  Tool_block_rejected
    (SSEParseFailed
       { raw = Printf.sprintf "%s tool_call index %d" protocol wire_index
       ; reason = tool_route_failure_reason failure
       })
;;

let register_tool_block_identity ?tx state ~block_index identity =
  match tx with
  | Some tx ->
    tx_replace_tool_block_by_id tx identity.id block_index;
    tx_replace_tool_block_identity tx block_index identity
  | None ->
    Hashtbl.replace state.tool_blocks_by_id identity.id block_index;
    Hashtbl.replace state.tool_block_identities block_index identity
;;

let open_tool_block
      ?tx
      state
      ~protocol
      ~wire_index
      ~provider_tool_id
      ~tool_name
      ~index_policy
  =
  let block_index =
    match index_policy with
    | Next_available -> state.next_block_index
    | Next_after_carrier -> state.next_block_index + 1
    | Wire_index -> wire_index
  in
  if Hashtbl.mem state.tool_block_identities block_index
  then reject_tool_block ~protocol ~wire_index Block_index_collision, None
  else (
    let identity =
      match non_blank_provider_tool_id provider_tool_id with
      | Some id -> { id; origin = Provider_supplied }
      | None -> { id = Api_common.fresh_tool_use_id (); origin = Agent_core_allocated }
    in
    register_tool_block_identity ?tx state ~block_index identity;
    state.next_block_index <- max state.next_block_index (block_index + 1);
    ( Tool_block_resolved { block_index; identity }
    , Some
        (ContentBlockStart
           { index = block_index
           ; content_type = "tool_use"
           ; tool_id = Some identity.id
           ; tool_name
           }) ))
;;

let resolve_tool_block
      ?tx
      state
      ~protocol
      ~wire_index
      ~provider_tool_id
      ~tool_name
      ~index_policy
      ~idless_semantics
  =
  let reject failure = reject_tool_block ~protocol ~wire_index failure, None in
  let open_and_record () =
    let resolution, start =
      open_tool_block
        ?tx
        state
        ~protocol
        ~wire_index
        ~provider_tool_id
        ~tool_name
        ~index_policy
    in
    (match resolution with
     | Tool_block_resolved { block_index; _ } ->
       record_tool_index_route ?tx state wire_index block_index
     | Tool_block_rejected _ -> ());
    resolution, start
  in
  let route_contains_block route block_index =
    match route with
    | Tool_index_single routed -> routed = block_index
    | Tool_index_ambiguous routed -> List.mem block_index routed
  in
  match non_blank_provider_tool_id provider_tool_id with
  | Some id ->
    (match Hashtbl.find_opt state.tool_blocks_by_id id with
     | Some block_index ->
       (match Hashtbl.find_opt state.tool_block_indices wire_index with
        | Some route when route_contains_block route block_index ->
          (match Hashtbl.find_opt state.tool_block_identities block_index with
           | Some identity when String.equal identity.id id ->
             Tool_block_resolved { block_index; identity }, None
           | Some _ -> reject Identity_index_conflict
           | None -> reject Missing_block_identity)
        | Some _ | None -> reject Provider_identity_route_conflict)
     | None ->
       (match Hashtbl.find_opt state.tool_block_indices wire_index with
        | Some (Tool_index_single block_index) ->
          (match Hashtbl.find_opt state.tool_block_identities block_index with
           | Some { origin = Agent_core_allocated; _ } -> reject Late_provider_identity
           | Some { origin = Provider_supplied; _ } ->
             (match index_policy with
              | Next_available | Next_after_carrier -> open_and_record ()
              | Wire_index -> reject Block_index_collision)
           | None -> reject Missing_block_identity)
        | Some (Tool_index_ambiguous _) ->
          (match index_policy with
           | Next_available | Next_after_carrier -> open_and_record ()
           | Wire_index -> reject Block_index_collision)
        | None -> open_and_record ()))
  | None ->
    (match idless_semantics with
     | Complete_occurrence -> open_and_record ()
     | Continue_by_wire_index ->
       (match Hashtbl.find_opt state.tool_block_indices wire_index with
        | Some (Tool_index_single block_index) ->
          (match Hashtbl.find_opt state.tool_block_identities block_index with
           | Some identity -> Tool_block_resolved { block_index; identity }, None
           | None -> reject Missing_block_identity)
        | Some (Tool_index_ambiguous _) -> reject Ambiguous_idless_continuation
        | None -> open_and_record ()))
;;

(* OpenAI-compatible streams carry no wire [content_block_stop] event (unlike
   Anthropic, whose stops are parsed straight off the wire). Synthesize one
   [ContentBlockStop] per block this state opened so the emitted AGENT_CORE event
   sequence stays symmetric: every [ContentBlockStart] gets a matching
   [ContentBlockStop]. The stream accumulator ignores stops, but block-lifecycle
   consumers depend on them — a stop closes a tool block so the NEXT provider
   message (a separate stream whose block indices restart at 0) reuses the same
   index without colliding with a still-open block, and so a tool-call-end is
   surfaced for that block. Called once on the terminal [finish_reason] chunk;
   blank/missing-finish chunks never close blocks. *)
let openai_open_block_stops (state : openai_stream_state) : sse_event list =
  let indices =
    (if state.thinking_block_started then [ state.thinking_block_index ] else [])
    @ (if state.text_block_started then [ state.text_block_index ] else [])
    @ Option.to_list state.reasoning_details_index
    @ (match state.inline_active_block with None -> [] | Some (_, index) -> [index])
    @ Hashtbl.fold
        (fun block_index _identity acc -> block_index :: acc)
        state.tool_block_identities
        []
  in
  indices |> List.sort_uniq Int.compare |> List.map (fun index -> ContentBlockStop { index })
;;

let emit_inline_segments state emit segments =
  List.iter (fun segment ->
    let channel, content_type, delta = match segment with
      | Inline_reasoning_split.Text text -> Inline_text, "text", TextDelta text
      | Inline_reasoning_split.Reasoning text -> Inline_thinking, "thinking", ThinkingDelta text in
    let index = match state.inline_active_block with
      | Some (previous, index) when previous = channel -> index
      | previous ->
          Option.iter (fun (_, index) -> emit (ContentBlockStop {index})) previous;
          let index = state.next_block_index in
          state.next_block_index <- index + 1;
          state.inline_active_block <- Some (channel, index);
          state.inline_indices_rev <- index :: state.inline_indices_rev;
          emit (ContentBlockStart {index; content_type; tool_id = None; tool_name = None});
          index
    in
    emit (ContentBlockDelta {index; delta})) segments
;;

(** Project one parsed chunk into locally buffered events. Tool route failures
    remain typed so the caller can roll back tool-bearing chunks before any
    event escapes. *)
let project_openai_chunk ?tx (state : openai_stream_state) (chunk : openai_chunk)
  : (sse_event list * Telemetry_event.t option, sse_event) result
  =
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  state.refusal_seen <- state.refusal_seen || chunk.delta_refusal;
  (* Reasoning content delta — emitted before text *)
  let emit_thinking_delta text =
    (match state.thinking_state with
     | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
     | Thinking_started _ | Thinking_done ->
       (* Already started, or model is re-emitting reasoning after a
          closure — keep current state. Enumerated explicitly so adding
          a new [thinking_state] variant forces review of how it should
          react to a fresh reasoning chunk. *)
       ());
    if not state.thinking_block_started
    then (
      state.thinking_block_index <- state.next_block_index;
      emit
        (ContentBlockStart
           { index = state.next_block_index
           ; content_type = "thinking"
           ; tool_id = None
           ; tool_name = None
           });
      state.thinking_block_started <- true;
      state.next_block_index <- state.next_block_index + 1);
    emit
      (ContentBlockDelta
         { index = state.thinking_block_index; delta = ThinkingDelta text })
  in
  (match chunk.delta_reasoning with
   | Some text when text <> "" -> emit_thinking_delta text
   | Some "" ->
     (match state.thinking_state with
      | Thinking_started t0 ->
        let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
        state.thinking_state <- Thinking_done;
        telemetry_event
        := Some
             (Telemetry_event.Thinking_complete
                { provider = state.provider; model = state.model; thinking_duration_ms })
      | Not_thinking | Thinking_done ->
        (* Empty reasoning chunk while never started, or after a prior
           close — no telemetry to emit. Enumerated explicitly so a new
           [thinking_state] variant cannot silently inherit the no-op. *)
        ())
   | Some empty_reasoning ->
     let (_ : string) = empty_reasoning in
     ()
   | None -> ());
  (match chunk.delta_reasoning_details with
   | Some { delta_reasoning_content; delta_details } ->
     (match state.thinking_state with
      | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
      | Thinking_started _ | Thinking_done -> ());
     let index = match state.reasoning_details_index with
       | Some index -> index
       | None ->
           let index = state.next_block_index in
           state.reasoning_details_index <- Some index;
           state.next_block_index <- index + 1;
           emit (ContentBlockStart {index; content_type = "reasoning_details";
                                    tool_id = None; tool_name = None});
           index
     in
     emit (ContentBlockDelta {index; delta = ReasoningDetailsDelta
       {reasoning_content=delta_reasoning_content;details=delta_details}})
   | None -> ());
  let emit_text_delta text =
    if not state.text_block_started
    then (
      state.text_block_index <- state.next_block_index;
      emit
        (ContentBlockStart
           { index = state.next_block_index
           ; content_type = "text"
           ; tool_id = None
           ; tool_name = None
           });
      state.text_block_started <- true;
      state.next_block_index <- state.next_block_index + 1);
    emit (ContentBlockDelta { index = state.text_block_index; delta = TextDelta text })
  in
  (* Explicit content framing is independent of the native reasoning dialect.
     Preserve inline segment order and distinct native/inline block identities. *)
  (match chunk.delta_content with
   | Some text when text <> "" ->
     (match state.inline_reasoning with
      | None -> emit_text_delta text
      | Some split ->
        if state.preserve_inline_content then state.inline_raw_rev <- text :: state.inline_raw_rev;
        emit_inline_segments state emit (Inline_reasoning_split.feed_segments split text))
   | Some empty_text ->
     if state.preserve_inline_content then state.inline_raw_rev <- empty_text :: state.inline_raw_rev
   | None -> ());
  (* Tool call deltas are one state transaction with the rest of this chunk.
     A late identity/index conflict rolls back every earlier sibling and
     discards locally buffered events before the caller can observe them. *)
  let rec emit_tool_calls = function
    | [] -> Ok ()
    | (tc : openai_tool_call_delta) :: rest ->
      let resolution, start =
        resolve_tool_block
          ?tx
          state
          ~protocol:"openai"
          ~wire_index:tc.tc_index
          ~provider_tool_id:tc.tc_id
          ~tool_name:tc.tc_name
          ~index_policy:Next_available
          ~idless_semantics:Continue_by_wire_index
      in
      (match resolution with
       | Tool_block_rejected error -> Error error
       | Tool_block_resolved { block_index; _ } ->
         Option.iter emit start;
         (match tc.tc_arguments with
          | Some (Args_fragment args) when args <> "" ->
            emit (ContentBlockDelta { index = block_index; delta = InputJsonDelta args })
          | Some (Args_complete args) when args <> "" ->
            emit
              (ContentBlockDelta { index = block_index; delta = InputJsonSnapshot args })
          | Some (Args_fragment _ | Args_complete _) | None -> ());
         emit_tool_calls rest)
  in
  match emit_tool_calls chunk.delta_tool_calls with
  | Error error -> Error error
  | Ok () ->
    (* Finish reason -> MessageDelta *)
    (match chunk.finish_reason with
     | Some reason ->
       let stop_reason =
         (* OpenAI wire vocabulary -> PROVISIONAL stop_reason. The accumulated
            tool-block set is unknown at the chunk boundary (tool arguments arrive
            as deltas before this terminal chunk), so a "tool_calls" finish is
            recorded as a provisional StopToolUse and reconciled against the
            assembled content in Complete_stream_acc.finalize_stream_acc
            (Stop_reason_wire.reconcile). SSOT: the wire vocabulary lives in
            Stop_reason_wire, not in an unguarded chunk-level match. *)
         Stop_reason_wire.provisional_of_string reason
         |> Stop_reason_wire.with_refusal ~has_refusal:state.refusal_seen
       in
       (* Close every block this message opened before the terminal MessageDelta,
          mirroring Anthropic's content_block_stop-then-message_delta ordering.
          Without this the OpenAI-compat stream leaves tool blocks open and a
          downstream per-message block-index consumer collides on the next
          message's reused index. *)
       (* Bytes the inline-reasoning splitter was holding back belong to this
          message. Release them before the blocks close: an unterminated tag
          means the stream was cut mid-thought, and dropping what it carried
          would lose the reasoning outright. *)
       (match state.inline_reasoning with
        | None -> ()
        | Some split ->
          emit_inline_segments state emit (Inline_reasoning_split.flush_segments split));
       List.iter emit (openai_open_block_stops state);
       (match state.inline_reasoning with
        | None -> ()
        | Some _ when state.preserve_inline_content && state.inline_raw_rev <> [] -> emit (InlineContentReplay
            {raw_content=String.concat "" (List.rev state.inline_raw_rev);
             block_indices=List.rev state.inline_indices_rev})
        | Some _ -> ());
       emit
         (MessageDelta
            { stop_reason = Some stop_reason
            ; usage = chunk.chunk_usage
            })
     | None ->
       (* With stream_options.include_usage the provider sends token totals in a
          separate final chunk that has no finish_reason and an empty choices
          array (hence no content/tool deltas). Emit a MessageDelta carrying only
          the usage so the accumulator records it. The finish_reason branch above
          already forwards usage when a stop arrives in the same chunk, so the two
          paths are mutually exclusive and usage is never emitted twice. *)
       (match chunk.chunk_usage with
        | Some usage ->
          emit
            (MessageDelta
               { stop_reason = None
               ; usage = Some usage
               })
        | None -> ()));
    let events = List.rev !events in
    let events =
      match state.openai_prelude with
      | Reported_prelude_published | Output_without_prelude -> events
      | Awaiting_reported_metadata ->
        if not (Api_common.string_is_blank chunk.chunk_id)
           && not (Api_common.string_is_blank chunk.chunk_model)
        then (
          state.openai_prelude <- Reported_prelude_published;
          (* The pair belongs to this wire chunk. Never assemble it from
             separate partial headers or substitute the requested model.
             Usage remains on its existing MessageDelta, exactly once. *)
          MessageStart {id=chunk.chunk_id; model=chunk.chunk_model; usage=None} :: events)
        else (
          (* A late prelude is not a metadata update: accumulators and chat
             consumers treat it as a response boundary. Preserve the existing
             metadata-poor output rather than reopening it later. *)
          if events <> [] then state.openai_prelude <- Output_without_prelude;
          events)
    in
    Ok (events, !telemetry_event)
;;

(** Convert a parsed {!Openai_wire.openai_chunk} into {!sse_event} list.
    Synthesizes [ContentBlockStart] events on first occurrence of text content
    or each new tool-call identity, and matching stops on terminal chunks.

    Tool-bearing chunks are transactional: a sibling route conflict returns
    exactly one parse failure and rolls back every scalar/table mutation. The
    structurally exact no-tool fast path avoids transaction allocation for the
    common text/reasoning token stream. *)
let openai_chunk_to_events (state : openai_stream_state) (chunk : openai_chunk)
  : sse_event list * Telemetry_event.t option
  =
  match chunk.delta_tool_calls with
  | [] ->
    (match project_openai_chunk state chunk with
     | Ok result -> result
     | Error error -> [ error ], None)
  | _ :: _ ->
    let tx = begin_openai_projection state in
    (match project_openai_chunk ~tx state chunk with
     | Ok result -> result
     | Error error ->
       rollback_openai_projection tx;
       [ error ], None
     | exception exn ->
       rollback_openai_projection tx;
       raise exn)
;;

let openai_sse_parse_result_to_events state = function
  | Openai_chunk chunk -> openai_chunk_to_events state chunk
  | Openai_done ->
    (* The terminal sentinel is observable even without a preceding chunk.
       It closes the prelude window; later data must not invent a new start. *)
    (match state.openai_prelude with
     | Awaiting_reported_metadata -> state.openai_prelude <- Output_without_prelude
     | Reported_prelude_published | Output_without_prelude -> ());
    [ MessageStop ], None
  | Openai_empty -> [], None
  | Openai_provider_error { message; error_type; provider_status; report; raw } ->
    [ SSEError { message; error_type; provider_status; report; raw } ], None
  | Openai_parse_failed { reason; raw } -> [ SSEParseFailed { reason; raw } ], None
  | Openai_undeclared_reasoning_member { declared; member; raw } ->
    (* The stream fails on the chunk that exposed the row: the raw payload is
       the evidence and the reason names both members so the catalog can be
       corrected. *)
    ( [ SSEParseFailed
          { reason =
              Printf.sprintf
                "undeclared_reasoning_member:%s:declared:%s"
                member
                declared
          ; raw
          }
      ]
    , None )
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_tool_use_start_with_name = function
  | ContentBlockStart { index; content_type = "tool_use"; tool_name; _ } ->
    Some (index, tool_name)
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | InlineContentReplay _ | ResponsesOutputItems _ | Ping
  | SSEError _
  | NDJSONError _
  | SSEParseFailed _
  | NDJSONParseFailed _
  | SSEUnknownEventType _
  | SSEUnsupportedPart _
  | SSEUnsupportedResponse _
  | Connected
  | Timeout _
  | StreamIncomplete _ -> None
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_tool_use_start = function
  | ContentBlockStart { content_type = "tool_use"; _ } -> Some ()
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta _
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | InlineContentReplay _ | ResponsesOutputItems _ | Ping
  | SSEError _
  | NDJSONError _
  | SSEParseFailed _
  | NDJSONParseFailed _
  | SSEUnknownEventType _
  | SSEUnsupportedPart _
  | SSEUnsupportedResponse _
  | Connected
  | Timeout _
  | StreamIncomplete _ -> None
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_input_json_delta = function
  | ContentBlockDelta { index; delta = InputJsonDelta s } -> Some (index, s)
  | MessageStart _
  | ContentBlockStart _
  | ContentBlockDelta
      { delta =
          ( TextDelta _
          | TextSnapshot _
          | (ThinkingDelta _ | ThinkingSnapshot _)
          | ThinkingSignatureDelta _
          | RedactedThinkingSnapshot _
          | ReasoningDetailsDelta _
          | InputJsonSnapshot _
          | MediaDelta _ )
      ; _
      }
  | ContentBlockStop _
  | MessageDelta _
  | MessageStop
  | InlineContentReplay _ | ResponsesOutputItems _ | Ping
  | SSEError _
  | NDJSONError _
  | SSEParseFailed _
  | NDJSONParseFailed _
  | SSEUnknownEventType _
  | SSEUnsupportedPart _
  | SSEUnsupportedResponse _
  | Connected
  | Timeout _
  | StreamIncomplete _ -> None
;;

let%test
    "openai_chunk_to_events: parallel tool calls sharing wire index:0 get distinct blocks"
  =
  (* minimax-m3 (Ollama Cloud) stamps every parallel tool call index:0 but gives
     each a distinct id. Blocks are keyed by id so the three calls do not collapse
     into one buffer whose concatenated arguments are not one JSON object. *)
  let mk id name args : openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some id
    ; tc_name = Some name
    ; tc_arguments = Some (Args_fragment args)
    }
  in
  let state = create_openai_stream_state () in
  let chunk =
    { chunk_id = "c"
    ; chunk_model = "minimax-m3"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls =
        [ mk "a" "list_tasks" {|{"limit":5}|}
        ; mk "b" "run_shell" {|{"argv":["git"]}|}
        ; mk "c" "read_file" {|{"file_path":"x"}|}
        ]
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let events, _ = openai_chunk_to_events state chunk in
  let starts = List.filter_map test_tool_use_start_with_name events in
  let deltas = List.filter_map test_input_json_delta events in
  starts = [ 0, Some "list_tasks"; 1, Some "run_shell"; 2, Some "read_file" ]
  && deltas = [ 0, {|{"limit":5}|}; 1, {|{"argv":["git"]}|}; 2, {|{"file_path":"x"}|} ]
;;

(* Inline-test-only helpers for the inline-reasoning split. *)
let[@warning "-32"] test_thinking_text = function
  | ContentBlockDelta { delta = ThinkingDelta s | ThinkingSnapshot s; _ } -> Some s
  | ContentBlockDelta { delta = (TextDelta _ | (TextSnapshot _ | (ThinkingSignatureDelta _ | (RedactedThinkingSnapshot _ | (ReasoningDetailsDelta _ | (InputJsonDelta _ | (InputJsonSnapshot _ | MediaDelta _)))))));_}
  | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | Connected | MessageStart _ | ContentBlockStart _ | ContentBlockStop _
  | MessageDelta _ | SSEError _ | NDJSONError _ | SSEParseFailed _ | NDJSONParseFailed _
  | SSEUnknownEventType _ | SSEUnsupportedPart _ | SSEUnsupportedResponse _ | Timeout _
  | StreamIncomplete _ -> None
;;

let[@warning "-32"] test_reply_text = function
  | ContentBlockDelta { delta = TextDelta s; _ } -> Some s
  | ContentBlockDelta { delta = (TextSnapshot _ | ((ThinkingDelta _ | ThinkingSnapshot _) | (ThinkingSignatureDelta _ | (RedactedThinkingSnapshot _ | (ReasoningDetailsDelta _ | (InputJsonDelta _ | (InputJsonSnapshot _ | MediaDelta _)))))));_}
  | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | Connected | MessageStart _ | ContentBlockStart _ | ContentBlockStop _
  | MessageDelta _ | SSEError _ | NDJSONError _ | SSEParseFailed _ | NDJSONParseFailed _
  | SSEUnknownEventType _ | SSEUnsupportedPart _ | SSEUnsupportedResponse _ | Timeout _
  | StreamIncomplete _ -> None
;;

let[@warning "-32"] test_content_chunk ?(finish_reason = None) content =
  { chunk_id = "c"
  ; chunk_model = "minimax-m3"
  ; delta_content = Some content
  ; delta_refusal = false
  ; delta_reasoning = None
  ; delta_reasoning_details = None
  ; delta_tool_calls = []
  ; finish_reason
  ; chunk_usage = None
  ; chunk_timings = None
  }
;;

let%test "minimax-m3 declares inline reasoning without losing its reasoning stream" =
  (* Both halves matter. The declaration is worthless if it does not reach the
     capability record, and folding it into [reasoning_streaming_format] would
     displace [Delta_reasoning_details] and cost the model the reasoning it
     already streams correctly. *)
  match Capabilities.for_model_id "minimax-m3" with
  | None -> false
  | Some caps ->
    let inline =
      match caps.Capabilities.content_inline_reasoning with
      | Capabilities.Think_tags | Capabilities.Think_tags_with_chat_replay -> true
      | Capabilities.No_content_inline_reasoning | Capabilities.Content_chunks -> false
    in
    let stream_intact =
      match (Reasoning_dialect.of_capabilities caps).streaming with
      | Reasoning_dialect.Delta_field_and_details "reasoning_content" -> true
      | Reasoning_dialect.Delta_field_and_details _
      | Reasoning_dialect.No_streaming_reasoning
      | Reasoning_dialect.Delta_field _
      | Reasoning_dialect.Template_parser -> false
    in
    inline && stream_intact
;;

let%test "openai_chunk_to_events: a declared template model keeps reasoning out of the reply"
  =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let events, _ =
    openai_chunk_to_events state (test_content_chunk "<think>weighing</think>the answer")
  in
  List.filter_map test_thinking_text events = [ "weighing" ]
  && List.filter_map test_reply_text events = [ "the answer" ]
;;

let%test "openai_chunk_to_events: an undeclared model keeps every byte of its content" =
  (* The split is a declaration, not a guess about text that looks like a tag. *)
  let state = create_openai_stream_state () in
  let events, _ =
    openai_chunk_to_events state (test_content_chunk "<think>weighing</think>the answer")
  in
  List.filter_map test_thinking_text events = []
  && List.filter_map test_reply_text events = [ "<think>weighing</think>the answer" ]
;;

let%test "openai_chunk_to_events: a tag split across chunks leaks no fragment" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed content =
    fst (openai_chunk_to_events state (test_content_chunk content))
  in
  (* Bound in order: [@] does not fix the order its arguments are evaluated in,
     and a stream fed backwards proves nothing. *)
  let first = feed "<thi" in
  let second = feed "nk>mid</th" in
  let third = feed "ink>done" in
  let events = first @ second @ third in
  List.filter_map test_thinking_text events = [ "mid" ]
  && List.filter_map test_reply_text events = [ "done" ]
;;

let%test "openai_chunk_to_events: a cut thought is released as reasoning at stream end" =
  (* Every unbalanced block measured on the live fleet was short exactly one
     closing tag. The held bytes are reasoning, not reply, and not nothing. *)
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let opened, _ = openai_chunk_to_events state (test_content_chunk "<think>cut off") in
  let terminal, _ =
    openai_chunk_to_events
      state
      { (test_content_chunk "") with finish_reason = Some "stop" }
  in
  let events = opened @ terminal in
  List.filter_map test_thinking_text events = [ "cut off" ]
  && List.filter_map test_reply_text events = []
;;

let%test "openai_chunk_to_events: id-less continuation fragment stays in its call's block"
  =
  (* OpenAI streams a tool call's id and name only on its first chunk, then sends
     argument fragments carrying just the index. An id-less continuation must
     route back to the block opened for that index, not open a new one. *)
  let base =
    { chunk_id = "c"
    ; chunk_model = "m"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let state = create_openai_stream_state () in
  let ev1, _ =
    openai_chunk_to_events
      state
      { base with
        delta_tool_calls =
          [ { tc_index = 0
            ; tc_id = Some "a"
            ; tc_name = Some "calc"
            ; tc_arguments = Some (Args_fragment {|{"x":|})
            }
          ]
      }
  in
  let ev2, _ =
    openai_chunk_to_events
      state
      { base with
        delta_tool_calls =
          [ { tc_index = 0
            ; tc_id = None
            ; tc_name = None
            ; tc_arguments = Some (Args_fragment {|1}|})
            }
          ]
      }
  in
  let starts = List.filter_map test_tool_use_start (ev1 @ ev2) in
  let deltas = List.filter_map test_input_json_delta (ev1 @ ev2) in
  List.length starts = 1 && deltas = [ 0, {|{"x":|}; 0, {|1}|} ]
;;

let%test
    "openai_chunk_to_events: gemma-style fragmented parallel calls keep distinct blocks"
  =
  (* gemma4-coder-fable5 (RunPod llama-server) emits parallel tool calls the
     spec-compliant way: distinct wire indices, id and name only on each call's
     first chunk, then argument fragments carrying just the index. Each call's
     fragments must accumulate into its own block (one Start per call, fragments
     routed back by index). Captured wire, 2026-06-30. *)
  let base =
    { chunk_id = "c"
    ; chunk_model = "gemma4-coder-fable5"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let tc tc_index tc_id tc_name args =
    { tc_index; tc_id; tc_name; tc_arguments = Some (Args_fragment args) }
  in
  let state = create_openai_stream_state () in
  let chunks =
    [ [ tc 0 (Some "a") (Some "list_tasks") {|{"li|} ]
    ; [ tc 0 None None {|mit":5}|} ]
    ; [ tc 1 (Some "b") (Some "run_shell") {|{"ar|} ]
    ; [ tc 1 None None {|gv":["git"]}|} ]
    ]
  in
  let events =
    List.concat_map
      (fun tcs -> fst (openai_chunk_to_events state { base with delta_tool_calls = tcs }))
      chunks
  in
  let starts =
    List.filter_map
      (function
        | ContentBlockStart { index; content_type = "tool_use"; tool_name; _ } ->
          Some (index, tool_name)
        | MessageStart _
        | ContentBlockStart _
        | ContentBlockDelta _
        | ContentBlockStop _
        | MessageDelta _
        | MessageStop
        | InlineContentReplay _ | ResponsesOutputItems _ | Ping
        | SSEError _
        | NDJSONError _
        | SSEParseFailed _
        | NDJSONParseFailed _
        | SSEUnknownEventType _
        | SSEUnsupportedPart _
        | SSEUnsupportedResponse _
        | Connected
        | Timeout _
        | StreamIncomplete _ -> None)
      events
  in
  let deltas =
    List.filter_map
      (function
        | ContentBlockDelta { index; delta = InputJsonDelta s } -> Some (index, s)
        | MessageStart _
        | ContentBlockStart _
        | ContentBlockDelta
            { delta =
                ( TextDelta _
                | TextSnapshot _
                | (ThinkingDelta _ | ThinkingSnapshot _)
                | ThinkingSignatureDelta _
                | RedactedThinkingSnapshot _
                | ReasoningDetailsDelta _
                | InputJsonSnapshot _
                | MediaDelta _ )
            ; _
            }
        | ContentBlockStop _
        | MessageDelta _
        | MessageStop
        | InlineContentReplay _ | ResponsesOutputItems _ | Ping
        | SSEError _
        | NDJSONError _
        | SSEParseFailed _
        | NDJSONParseFailed _
        | SSEUnknownEventType _
        | SSEUnsupportedPart _
        | SSEUnsupportedResponse _
        | Connected
        | Timeout _
        | StreamIncomplete _ -> None)
      events
  in
  starts = [ 0, Some "list_tasks"; 1, Some "run_shell" ]
  && deltas = [ 0, {|{"li|}; 0, {|mit":5}|}; 1, {|{"ar|}; 1, {|gv":["git"]}|} ]
;;

let%test "openai_chunk_to_events: id-less continuation on ambiguous index fails loud" =
  let base =
    { chunk_id = "c"
    ; chunk_model = "minimax-m3"
    ; delta_content = None
    ; delta_refusal = false
    ; delta_reasoning = None
    ; delta_reasoning_details = None
    ; delta_tool_calls = []
    ; finish_reason = None
    ; chunk_usage = None
    ; chunk_timings = None
    }
  in
  let tc tc_id args =
    { tc_index = 0; tc_id; tc_name = None; tc_arguments = Some (Args_fragment args) }
  in
  let state = create_openai_stream_state () in
  let _ =
    openai_chunk_to_events
      state
      { base with
        delta_tool_calls = [ tc (Some "a") {|{"a":|}; tc (Some "b") {|{"b":|} ]
      }
  in
  let events, _ =
    openai_chunk_to_events state { base with delta_tool_calls = [ tc None {|1}|} ] }
  in
  match events with
  | [ SSEParseFailed { raw; reason } ] ->
    raw = "openai tool_call index 0"
    && reason
       = "ambiguous_tool_call_index: id-less continuation follows multiple tool \
          identities"
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

(** {1 OpenAI Responses API SSE Streaming}

    Responses streaming uses item-level event names:
    - [response.output_text.delta] for assistant text
    - [response.reasoning_summary_text.delta] / [response.reasoning_text.delta]
      for reasoning summaries/text
    - [response.output_item.added] + [response.function_call_arguments.delta]
      for function calls
    - [response.completed] / [response.incomplete] / [response.failed] for
      terminal status and usage.

    Keep this separate from {!Openai_wire.parse_openai_sse_chunk}: Responses has no
    [choices[].delta] envelope. *)

let responses_member_string_opt key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_string_option
;;

let responses_member_int_default key json =
  let open Yojson.Safe.Util in
  json |> member key |> to_int_option |> Option.value ~default:0
;;

let responses_usage_of_response response =
  let open Yojson.Safe.Util in
  match response |> member "usage" with
  | `Assoc _ as usage ->
    let input_tokens = responses_member_int_default "input_tokens" usage in
    let output_tokens = responses_member_int_default "output_tokens" usage in
    let cache_read_input_tokens =
      match usage |> member "input_tokens_details" with
      | `Assoc _ as details -> responses_member_int_default "cached_tokens" details
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> 0
    in
    Some
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens
      ; cost_usd = None
      }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_output_has_function_call response =
  let open Yojson.Safe.Util in
  match response |> member "output" with
  | `List items ->
    List.exists
      (fun item ->
         match responses_member_string_opt "type" item with
         | Some ("function_call" | "custom_tool_call") -> true
         | Some _ | None -> false)
      items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> false
;;

let responses_incomplete_reason_opt response =
  let open Yojson.Safe.Util in
  match response |> member "incomplete_details" with
  | `Assoc _ as details -> responses_member_string_opt "reason" details
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_incomplete_reason response =
  responses_incomplete_reason_opt response |> Option.value ~default:"incomplete"
;;

let responses_failed_message response =
  let open Yojson.Safe.Util in
  match response |> member "error" with
  | `Assoc _ as err -> responses_member_string_opt "message" err
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let responses_stop_reason_of_response response =
  Responses_stop_reason.of_status
    ~status:(responses_member_string_opt "status" response)
    ~incomplete_reason:(responses_incomplete_reason_opt response)
    ~failed_message:(responses_failed_message response)
    ~has_tool_calls:(responses_output_has_function_call response)
  |> Option.map
       (Stop_reason_wire.with_refusal
          ~has_refusal:(Responses_stop_reason.has_refusal response))
;;

let responses_error_message json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc _ as err ->
    responses_member_string_opt "message" err |> Option.value ~default:"Responses error"
  | `String message -> message
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    responses_member_string_opt "message" json |> Option.value ~default:"Responses error"
;;

let responses_error_type json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc _ as err ->
    (match responses_member_string_opt "type" err with
     | Some _ as t -> t
     | None -> responses_member_string_opt "code" err)
  | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    responses_member_string_opt "code" json
;;

let responses_fresh_block state =
  let index = state.next_block_index in
  state.next_block_index <- index + 1;
  index
;;

let responses_ensure_thinking_block state emit ~output_index =
  (match state.thinking_state with
   | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
   | Thinking_started _ | Thinking_done -> ());
  match Hashtbl.find_opt state.responses_thinking_blocks output_index with
  | Some index -> index
  | None ->
    let index = responses_fresh_block state in
    Hashtbl.add state.responses_thinking_blocks output_index index;
    emit (ContentBlockStart
      {index;content_type="thinking";tool_id=None;tool_name=None});
    index
;;

let responses_ensure_text_block state emit ~output_index ~content_index =
  let key = output_index, content_index in
  match Hashtbl.find_opt state.responses_text_blocks key with
  | Some index -> index
  | None ->
    let index = responses_fresh_block state in
    Hashtbl.add state.responses_text_blocks key index;
    emit (ContentBlockStart {index;content_type="text";tool_id=None;tool_name=None});
    index
;;

let responses_tool_id_of_item item = responses_member_string_opt "call_id" item

let responses_ensure_tool_block state emit ~output_index ~tool_id ~tool_name =
  let resolution, start =
    resolve_tool_block
      state
      ~protocol:"openai_responses"
      ~wire_index:output_index
      ~provider_tool_id:tool_id
      ~tool_name
      ~index_policy:Next_available
      ~idless_semantics:Continue_by_wire_index
  in
  Option.iter emit start;
  match resolution with
  | Tool_block_resolved { block_index; _ } -> Some block_index
  | Tool_block_rejected error ->
    emit error;
    None
;;

let responses_assert_output_kind state emit output_index incoming =
    let effective = match Hashtbl.find_opt state.responses_output_kinds output_index, incoming with
      | None, (Response_replay.Message _ | Reasoning | Function_call as kind) -> Some kind
      | Some (Response_replay.Message previous), Response_replay.Message phase ->
        if phase=Response_replay.Absent then Some (Response_replay.Message previous)
        else if previous=Response_replay.Absent || previous=phase then Some incoming
        else None
      | Some Response_replay.Reasoning, Response_replay.Reasoning
      | Some Response_replay.Function_call, Response_replay.Function_call -> Some incoming
      | Some Response_replay.Reasoning, (Response_replay.Message _ | Function_call)
      | Some Response_replay.Function_call, (Response_replay.Message _ | Reasoning)
      | Some (Response_replay.Message _), (Reasoning | Function_call) -> None in
    match effective with
    | Some kind -> Hashtbl.replace state.responses_output_kinds output_index kind; Some kind
    | None -> emit(SSEParseFailed{raw="";reason="responses_replay:conflicting_item_kind_or_phase"});None
;;

let responses_accept_output_identity state emit output_index = function
  | None | Some "" -> true
  | Some id ->
    (match Hashtbl.find_opt state.responses_output_ids output_index with
     | None -> Hashtbl.add state.responses_output_ids output_index id;true
     | Some previous when String.equal previous id -> true
     | Some _ -> emit(SSEParseFailed{raw="";reason="responses_replay:conflicting_output_item_identity"});false)
;;

let responses_reasoning_update state emit ~output_index apply =
  let previous=Hashtbl.find_opt state.responses_reasoning output_index
    |> Option.value ~default:Responses_reasoning_stream.empty in
  match apply previous with
  | Error reason -> emit(SSEParseFailed{raw="";reason})
  | Ok(next,update) ->
    Hashtbl.replace state.responses_reasoning output_index next;
    (match update with
     | Responses_reasoning_stream.Unchanged -> ()
     | Append text ->
       let index=responses_ensure_thinking_block state emit ~output_index in
       emit(ContentBlockDelta{index;delta=ThinkingDelta text})
     | Replace text ->
       let index=responses_ensure_thinking_block state emit ~output_index in
       emit(ContentBlockDelta{index;delta=ThinkingSnapshot text})
     | Redact raw ->
       (match Hashtbl.find_opt state.responses_thinking_blocks output_index with
        | Some index -> emit(ContentBlockDelta{index;delta=RedactedThinkingSnapshot raw})
        | None ->
          let index=responses_fresh_block state in
          Hashtbl.add state.responses_thinking_blocks output_index index;
          emit(ContentBlockStart{index;content_type="redacted_thinking";tool_id=Some raw;tool_name=None})));
    Option.iter(fun index->Hashtbl.replace state.responses_output_groups output_index
      (Response_replay.Reasoning,[index]))
      (Hashtbl.find_opt state.responses_thinking_blocks output_index)
;;

let responses_capture_output_item ?(drop_function_call=false) state emit ~output_index item =
  let open Yojson.Safe.Util in
  let capture kind indices =
    Hashtbl.replace state.responses_output_groups output_index (kind, indices)
  in
  let assert_kind incoming = responses_assert_output_kind state emit output_index incoming in
  let identity_matches=responses_accept_output_identity state emit output_index
    (responses_member_string_opt "id" item) in
  if not identity_matches then ()
  else match responses_member_string_opt "type" item with
  | Some "message" ->
    let phase = match item with
      | `Assoc fields -> Response_replay.phase_of_fields fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "responses_replay:message_not_object" in
    (match phase with
     | Error reason -> emit (SSEParseFailed {raw="";reason})
     | Ok phase ->
       (match assert_kind (Response_replay.Message phase) with
        | None -> ()
        | Some kind ->
       let indices = match item |> member "content" with
         | `List parts -> List.mapi (fun content_index part -> content_index,part) parts
           |> List.filter_map (fun (content_index,part) ->
             match responses_member_string_opt "type" part,
                   responses_member_string_opt "text" part with
             | Some ("output_text" | "text"), Some text ->
               let index = responses_ensure_text_block state emit ~output_index ~content_index in
               emit (ContentBlockDelta {index;delta=TextSnapshot text});Some index
             | _ -> None)
         | `String text ->
           let index = responses_ensure_text_block state emit ~output_index ~content_index:0 in
           emit (ContentBlockDelta {index;delta=TextSnapshot text});[index]
         | `Null | `Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> [] in
       capture kind indices))
  | Some "reasoning" ->
    (match assert_kind Response_replay.Reasoning with
     | None -> ()
     | Some kind ->
    (match Responses_reasoning.decode item with
     | Error reason -> emit(SSEParseFailed{raw="";reason})
     | Ok incoming -> responses_reasoning_update state emit ~output_index
         (fun previous->Responses_reasoning_stream.item previous incoming));
    capture kind (Option.to_list(Hashtbl.find_opt state.responses_thinking_blocks output_index)))
  | Some "function_call" ->
    (match assert_kind Response_replay.Function_call with
     | None -> ()
     | Some kind ->
       if drop_function_call || responses_member_string_opt "status" item = Some "incomplete"
       then
         (* A cut-off call is never completed from its terminal snapshot. The
            accumulator's existing incomplete policy discards any held block. *)
         let indices = match Hashtbl.find_opt state.tool_block_indices output_index with
           | Some (Tool_index_single index) -> [index]
           | Some (Tool_index_ambiguous _) | None -> [] in
         capture kind indices
       else
         let item_for_decode, wire_tool_id =
           match responses_tool_id_of_item item with
           | Some id when not (Api_common.string_is_blank id) -> item, Some id
           | Some _ | None ->
             (match Hashtbl.find_opt state.tool_block_indices output_index with
              | Some (Tool_index_single block_index) ->
                (match Hashtbl.find_opt state.tool_block_identities block_index with
                 | Some { id; origin = Agent_core_allocated } ->
                   (match item with
                    | `Assoc fields ->
                      `Assoc (("call_id", `String id) :: List.remove_assoc "call_id" fields), None
                    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
                      item, None)
                 | Some { origin = Provider_supplied; _ } | None -> item, None)
              | Some (Tool_index_ambiguous _) | None -> item, None)
         in
         (match Responses_function_call.decode item_for_decode with
          | Error _ -> emit(SSEParseFailed{raw="";reason="responses_replay:malformed_function_call"})
          | Ok call ->
            let index = responses_ensure_tool_block state emit ~output_index
              ~tool_id:wire_tool_id ~tool_name:(Some call.name) in
            Option.iter (fun index ->
              emit(ContentBlockDelta{index;delta=InputJsonSnapshot call.arguments})) index;
            capture kind (Option.to_list index)))
  | Some "custom_tool_call" ->
    (* Preserve only an already assembled legacy stream block. This codec has
       no custom-input admission contract and cannot synthesize one here. *)
    (match Hashtbl.find_opt state.tool_block_indices output_index with
     | Some (Tool_index_single index) -> capture Response_replay.Function_call [index]
     | Some (Tool_index_ambiguous _) | None -> ())
  | Some _ | None -> ()
;;

let responses_capture_terminal_outputs state emit response =
  let open Yojson.Safe.Util in
  let drop_function_call = responses_member_string_opt "status" response = Some "incomplete" in
  (match response |> member "output" with
   | `List items ->
     Hashtbl.clear state.responses_output_groups;
     List.iteri (fun output_index item ->
       responses_capture_output_item ~drop_function_call state emit ~output_index item) items
   | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> ());
  let explicit_output=match response |> member "output" with `List _->true
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> false in
  if Hashtbl.length state.responses_output_groups > 0
     || (explicit_output && Hashtbl.length state.responses_thinking_blocks > 0) then
    emit (ResponsesOutputItems
      (Hashtbl.fold (fun index group acc -> (index,group)::acc) state.responses_output_groups []
       |> List.sort (fun (left,_) (right,_) -> Int.compare left right)
       |> List.map snd))
;;

let responses_sse_to_events (state : openai_stream_state) event_type data_str
  : sse_event list * Telemetry_event.t option
  =
  (* The Responses API delivers its terminal status via a [response.completed]
     event before this trailing sentinel, so [DONE] needs no synthesized
     terminal here -- the accumulator already has a stop_reason. *)
  if String.equal data_str openai_done_sentinel
  then [], None
  else (
    (* Decode through the shared total boundary (#2620): a valid-JSON
       non-object frame raises Util.Type_error out of [member], which a
       Json_error-only guard would let escape the parser (agent-core boundary). *)
    let decode json =
      let open Yojson.Safe.Util in
      let evt_type =
        match event_type with
        | Some t when String.trim t <> "" -> t
        | Some _ | None -> Cli_common_json.member_str "type" json
      in
      let events = ref [] in
      let emit evt = events := evt :: !events in
      let emit_terminal response =
        emit
          (MessageDelta
             { stop_reason =
                 responses_stop_reason_of_response response
                 |> Option.map (Stop_reason_wire.with_refusal ~has_refusal:state.refusal_seen)
             ; usage =
                 Option.map
                   Types.delta_usage_of_api_usage
                   (responses_usage_of_response response)
             });
        emit MessageStop
      in
      (match evt_type with
       | "response.created" ->
         let response = json |> member "response" in
         emit
           (MessageStart
              { id = Cli_common_json.member_str "id" response
              ; model = Cli_common_json.member_str "model" response
              ; usage = responses_usage_of_response response
              })
       | "response.output_text.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let content_index = responses_member_int_default "content_index" json in
            let index = responses_ensure_text_block state emit ~output_index ~content_index in
            emit (ContentBlockDelta { index; delta = TextDelta delta })
          | Some _ | None -> ())
       | "response.refusal.delta" | "response.refusal.done" ->
         state.refusal_seen <- true
       | "response.output_text.done" ->
         (match responses_member_string_opt "text" json with
          | Some text ->
            let output_index=responses_member_int_default "output_index" json in
            let content_index=responses_member_int_default "content_index" json in
            let index=responses_ensure_text_block state emit ~output_index ~content_index in
            emit(ContentBlockDelta {index;delta=TextSnapshot text})
          | None -> ())
       | ("response.reasoning_summary_text.delta" | "response.reasoning_text.delta"
         | "response.reasoning_summary_text.done" | "response.reasoning_text.done") as event ->
         let channel,part_field,is_delta=match event with
           | "response.reasoning_text.delta" -> Responses_reasoning.Full,"content_index",true
           | "response.reasoning_text.done" -> Full,"content_index",false
           | "response.reasoning_summary_text.delta" -> Summary,"summary_index",true
           | _ -> Summary,"summary_index",false in
         let output_index=responses_member_int_default "output_index" json in
         if responses_accept_output_identity state emit output_index
             (responses_member_string_opt "item_id" json) then
           (match responses_assert_output_kind state emit output_index Response_replay.Reasoning with
            | None -> ()
            | Some _ ->
              match responses_member_string_opt (if is_delta then "delta" else "text") json with
              | None -> ()
              | Some text ->
                let part=responses_member_int_default part_field json in
                responses_reasoning_update state emit ~output_index (fun previous->
                  if is_delta then Responses_reasoning_stream.delta previous ~channel ~part text
                  else Responses_reasoning_stream.part_done previous ~channel ~part text))
       | "response.output_item.added" ->
         let output_index = responses_member_int_default "output_index" json in
         let item = json |> member "item" in
         (match responses_member_string_opt "type" item with
          | Some ("function_call" | "custom_tool_call") ->
            let (_ : int option) =
              responses_ensure_tool_block
                state
                emit
                ~output_index
                ~tool_id:(responses_tool_id_of_item item)
                ~tool_name:(responses_member_string_opt "name" item)
            in
            ()
          | Some _ | None -> ())
       | "response.output_item.done" ->
         let output_index=responses_member_int_default "output_index" json in
         responses_capture_output_item state emit ~output_index (json |> member "item")
       | "response.function_call_arguments.delta" ->
         (match responses_member_string_opt "delta" json with
          | Some delta when delta <> "" ->
            let output_index = responses_member_int_default "output_index" json in
            let index =
              responses_ensure_tool_block
                state
                emit
                ~output_index
                  (* [call_id] is the function-call identity on every official
                   arguments event. [item_id] identifies only the output item
                   and is never substituted for it. *)
                ~tool_id:(responses_member_string_opt "call_id" json)
                ~tool_name:None
            in
            (match index with
             | Some index ->
               emit (ContentBlockDelta { index; delta = InputJsonDelta delta })
             | None -> ())
          | Some _ | None -> ())
       | "response.completed" | "response.incomplete" ->
         let response = json |> member "response" in
         responses_capture_terminal_outputs state emit response;
         (* A [response.incomplete] terminal means the turn was cut off, so any
            in-progress tool call is partial. Carry that to the accumulator
            (which drops partial tool blocks at finalize) for ANY incomplete
            reason — [stop_reason = MaxTokens] alone only covers
            max_output_tokens, not e.g. content_filter. (#2073 follow-up.) *)
         (match responses_member_string_opt "status" response with
          | Some "incomplete" ->
            emit (StreamIncomplete { reason = responses_incomplete_reason response })
          | Some _ | None -> ());
         emit_terminal response
       | "response.failed" | "error" ->
         emit
           (SSEError
              { message = responses_error_message json
              ; error_type = responses_error_type json
              ; provider_status = None
              ; report = Types.Provider_stated
              ; raw = data_str
              })
       | "response.in_progress"
       | "response.content_part.added"
       | "response.content_part.done"
       | "response.function_call_arguments.done"
       | "response.reasoning_summary_part.added"
       | "response.reasoning_summary_part.done"
       | "response.queued" -> ()
       | other -> emit (SSEUnknownEventType { event_type = other; raw = data_str }));
      List.rev !events, None
    in
    match Json_util.decode_json_with decode data_str with
    | Ok result -> result
    | Error reason -> [ SSEParseFailed { raw = data_str; reason } ], None)
;;

(* A 200 response the transport accepted as SSE but whose body carries no
   [data:] payload at all: some providers and gateways answer with a bare
   JSON error object instead of an event stream. Read the envelope the same
   way an in-stream chunk would, so the declared status (429/5xx) reaches
   retry classification instead of surfacing as an incomplete stream. [None]
   keeps the caller's previous behaviour for anything that is not an error
   envelope. *)
let sse_error_event_of_bodiless_body ~raw body =
  match Yojson.Safe.from_string body with
  | exception (Yojson.Json_error _ | Invalid_argument _) -> None
  | (`Assoc _ as json) ->
    (match
       Option.bind
         (Json_util.assoc_member_opt "error" json)
         Openai_error_envelope.of_error_value
     with
     | None -> None
     | Some envelope ->
       Some
         (Types.SSEError
            { message = envelope.message
            ; error_type = envelope.error_type
            ; provider_status = envelope.provider_status
            ; report = envelope.report
            ; raw
            }))
  | (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) -> None
;;

(** {1 Gemini SSE Streaming}

    {!Gemini_wire} reads one payload into a {!Gemini_wire.gemini_chunk}. The
    functions below turn that chunk into stream events and keep the block
    state in {!openai_stream_state}. *)

let gemini_message_start_for_model (state : openai_stream_state) raw_model =
  match Model_id.of_string raw_model with
  | Error reason ->
    raise
      (Backend_gemini.Gemini_api_error
         (Printf.sprintf "gemini.modelVersion invalid: %s" reason))
  | Ok model_id ->
    (match state.gemini_message_model with
     | None ->
       state.gemini_message_model <- Some model_id;
       Some (MessageStart { id = ""; model = Model_id.to_string model_id; usage = None })
     | Some observed when Model_id.equal observed model_id -> None
     | Some _ ->
       raise
         (Backend_gemini.Gemini_api_error
            "gemini.modelVersion changed within one streamed response"))
;;

let gemini_chunk_to_events_impl
      (state : openai_stream_state)
      (chunk : Gemini_wire.gemini_chunk)
  : sse_event list * Telemetry_event.t option
  =
  let open Yojson.Safe.Util in
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  (match chunk.Gemini_wire.gem_model with
   | Some model -> Option.iter emit (gemini_message_start_for_model state model)
   | None -> ());
  let has_thought_part =
    List.exists
      (fun part ->
         Cli_common_json.member_bool "thought" part
         &&
         match part |> member "text" |> to_string_option with
         | Some text when text <> "" -> true
         | Some empty_text ->
           let (_ : string) = empty_text in
           false
         | None -> false)
      chunk.Gemini_wire.gem_parts
  in
  (match state.thinking_state, has_thought_part with
   | Not_thinking, true | Thinking_done, true ->
     state.thinking_state <- Thinking_started (Unix.gettimeofday ())
   | Thinking_started t0, false ->
     let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
     state.thinking_state <- Thinking_done;
     telemetry_event
     := Some
          (Telemetry_event.Thinking_complete
             { provider = state.provider; model = state.model; thinking_duration_ms })
   | Not_thinking, false | Thinking_done, false | Thinking_started _, true -> ());
  List.iteri
    (fun part_index part ->
       let is_thought = Cli_common_json.member_bool "thought" part in
       let part_thought_signature = Backend_gemini.thought_signature_of_part part in
       let emit_signed_part ~target ~content_type ~delta thought_signature =
         (match target with
          | Backend_gemini.Gemini_text_part -> state.text_block_started <- false
          | Backend_gemini.Gemini_thought_part -> state.thinking_block_started <- false
          | Backend_gemini.Gemini_image_part
          | Backend_gemini.Gemini_audio_part
          | Backend_gemini.Gemini_document_part -> ());
         let carrier_index = state.next_block_index in
         let carrier_payload =
           Backend_gemini.gemini_part_thought_signature_payload ~target ~thought_signature
         in
         emit
           (ContentBlockStart
              { index = carrier_index
              ; content_type = "redacted_thinking"
              ; tool_id = Some carrier_payload
              ; tool_name = None
              });
         let content_index = carrier_index + 1 in
         emit
           (ContentBlockStart
              { index = content_index; content_type; tool_id = None; tool_name = None });
         emit (ContentBlockDelta { index = content_index; delta });
         state.next_block_index <- content_index + 1
       in
       let emit_function_call_delta () =
         match part |> member "functionCall" with
         | `Assoc _ as fc ->
           let name = Cli_common_json.member_str "name" fc in
           let args =
             match fc |> member "args" with
             | `Null -> `Assoc []
             | args -> args
           in
           let provider_tool_id = fc |> member "id" |> to_string_option in
           let thought_signature = part_thought_signature in
           let resolution, start =
             resolve_tool_block
               state
               ~protocol:"gemini"
               ~wire_index:part_index
               ~provider_tool_id
               ~tool_name:(Some name)
               ~index_policy:
                 (match thought_signature with
                  | Some _ -> Next_after_carrier
                  | None -> Next_available)
               ~idless_semantics:Complete_occurrence
           in
           (match resolution with
            | Tool_block_rejected error -> emit error
            | Tool_block_resolved { block_index = idx; identity } ->
              (match start with
               | Some start ->
                 (match thought_signature with
                  | Some thought_signature ->
                    let payload =
                      Backend_gemini.gemini_thought_signature_payload
                        ~tool_use_id:identity.id
                        ~thought_signature
                    in
                    let carrier_index = idx - 1 in
                    emit
                      (ContentBlockStart
                         { index = carrier_index
                         ; content_type = "redacted_thinking"
                         ; tool_id = Some payload
                         ; tool_name = None
                         })
                  | None -> ());
                 emit start
               | None -> ());
              emit
                (ContentBlockDelta
                   { index = idx; delta = InputJsonSnapshot (Yojson.Safe.to_string args) }))
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ()
       in
       let emit_textual_part text =
         match part_thought_signature with
         | Some thought_signature ->
           if is_thought
           then
             emit_signed_part
               ~target:Backend_gemini.Gemini_thought_part
               ~content_type:"thinking"
               ~delta:(ThinkingDelta text)
               thought_signature
           else
             emit_signed_part
               ~target:Backend_gemini.Gemini_text_part
               ~content_type:"text"
               ~delta:(TextDelta text)
               thought_signature
         | None when String.equal text "" -> ()
         | None ->
           if is_thought
           then (
             if not state.thinking_block_started
             then (
               state.thinking_block_index <- state.next_block_index;
               emit
                 (ContentBlockStart
                    { index = state.next_block_index
                    ; content_type = "thinking"
                    ; tool_id = None
                    ; tool_name = None
                    });
               state.thinking_block_started <- true;
               state.next_block_index <- state.next_block_index + 1);
             emit
               (ContentBlockDelta
                  { index = state.thinking_block_index; delta = ThinkingDelta text }))
           else (
             if not state.text_block_started
             then (
               state.text_block_index <- state.next_block_index;
               emit
                 (ContentBlockStart
                    { index = state.next_block_index
                    ; content_type = "text"
                    ; tool_id = None
                    ; tool_name = None
                    });
               state.text_block_started <- true;
               state.next_block_index <- state.next_block_index + 1);
             emit
               (ContentBlockDelta
                  { index = state.text_block_index; delta = TextDelta text }))
       in
       let emit_media_part inline_data =
         let target, block =
           Backend_gemini.media_content_block_of_inline_data inline_data
         in
         let content_type, delta =
           match block with
           | Image { media_type; source } ->
             "image", MediaDelta { media_type; source }
           | Audio { media_type; source } ->
             "audio", MediaDelta { media_type; source }
           | Document { media_type; source } ->
             "document", MediaDelta { media_type; source }
           | Text _
           | Thinking _
           | ReasoningDetails _
           | RedactedThinking _
           | ToolUse _
           | ToolResult _ ->
             raise
               (Backend_gemini.Gemini_api_error
                  "Gemini inlineData decoder produced a non-media content block")
         in
         match part_thought_signature with
         | Some thought_signature ->
           emit_signed_part ~target ~content_type ~delta thought_signature
         | None ->
           let index = state.next_block_index in
           emit
             (ContentBlockStart { index; content_type; tool_id = None; tool_name = None });
           emit (ContentBlockDelta { index; delta });
           state.next_block_index <- index + 1
       in
       let emit_non_text_part () =
         match part |> member "functionCall" with
         | `Assoc _ -> emit_function_call_delta ()
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
           (match part |> member "inlineData" with
            | `Assoc _ as inline_data -> emit_media_part inline_data
            | `Null ->
              (match part_thought_signature with
               | Some _ ->
                 raise
                   (Backend_gemini.Gemini_api_error
                      "Gemini thoughtSignature is attached to an unsupported Part")
               | None -> ())
            | _ ->
              raise
                (Backend_gemini.Gemini_api_error "Gemini inlineData must be an object"))
       in
       match part |> member "text" |> to_string_option with
       | Some text when not (String.equal text "") -> emit_textual_part text
       | Some empty_text ->
         (match part |> member "functionCall" with
          | `Assoc _ -> emit_function_call_delta ()
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
            (match part |> member "inlineData" with
             | `Assoc _ as inline_data -> emit_media_part inline_data
             | `Null -> emit_textual_part empty_text
             | _ ->
               raise
                 (Backend_gemini.Gemini_api_error "Gemini inlineData must be an object")))
       | None -> emit_non_text_part ())
    chunk.Gemini_wire.gem_parts;
  (* Finish reason *)
  (match chunk.Gemini_wire.gem_finish_reason with
   | Some (Gemini_wire.Gemini_candidate_finish_reason reason) ->
     let stop_reason =
       Backend_gemini.stop_reason_of_finish_reason
         ~has_tool_use:(Hashtbl.length state.tool_block_indices > 0)
         reason
     in
     emit
       (MessageDelta
          { stop_reason = Some stop_reason
          ; usage = Option.map Types.delta_usage_of_api_usage chunk.Gemini_wire.gem_usage
          });
     emit MessageStop
   | Some (Gemini_wire.Gemini_prompt_block_reason _) ->
     emit
       (MessageDelta
          { stop_reason = Some Refusal
          ; usage = Option.map Types.delta_usage_of_api_usage chunk.Gemini_wire.gem_usage
          });
     emit MessageStop
   | None -> ());
  List.rev !events, !telemetry_event
;;

let rec validate_gemini_parts position = function
  | [] -> Ok ()
  | part :: rest ->
    (match Gemini_wire.validate_gemini_part ~position part with
     | Error _ as error -> error
     | Ok () -> validate_gemini_parts (position + 1) rest)
;;

type gemini_chunk_to_events_error = { reason : string }

let gemini_chunk_to_events state chunk =
  match validate_gemini_parts 0 chunk.Gemini_wire.gem_parts with
  | Error reason -> Error { reason = "gemini_sse_chunk_shape_failure: " ^ reason }
  | Ok () ->
    (try Ok (gemini_chunk_to_events_impl state chunk) with
     | Backend_gemini.Gemini_api_error reason ->
       Error { reason = "gemini_sse_chunk_decode_failure: " ^ reason }
     | Yojson.Safe.Util.Type_error (reason, _) ->
       Error { reason = "gemini_sse_chunk_decode_type_error: " ^ reason }
     | Yojson.Safe.Util.Undefined (reason, _) ->
       Error { reason = "gemini_sse_chunk_decode_undefined: " ^ reason }
     | Invalid_argument reason ->
       Error { reason = "gemini_sse_chunk_decode_invalid_argument: " ^ reason })
;;

(** {1 Ollama NDJSON Streaming}

    Ollama [/api/chat] with [stream:true] emits one JSON object per
    line. Non-final lines carry a [message.content] delta; the final
    line has [done:true] together with [done_reason] and the four
    timing fields ([prompt_eval_count] / [prompt_eval_duration] /
    [eval_count] / [eval_duration]) that the Openai compat path on
    [/v1/chat/completions] strips out. *)

type ollama_tool_call_delta =
  { oll_tc_index : int
  ; oll_tc_id : string option
  ; oll_tc_name : string option
  ; oll_tc_arguments : tool_call_arguments option
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

let ollama_required_fields json =
  let open Yojson.Safe.Util in
  match
    json |> member "model" |> to_string_option, json |> member "done" |> to_bool_option
  with
  | Some model, Some is_done when not (Api_common.string_is_blank model) ->
    Some (model, is_done)
  | Some _, Some _ | None, _ | _, None -> None
;;

type ollama_line_shape =
  | Ollama_data_fields of string * bool
  | Ollama_provider_error_fields of
      { message : string
      ; error_type : string option
      }
  | Ollama_malformed_fields of string

let ollama_line_shape json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `String message -> Ollama_provider_error_fields { message; error_type = None }
  | `Assoc error_fields ->
    let error = `Assoc error_fields in
    let message =
      error |> member "message" |> to_string_option |> Option.value ~default:""
    in
    let error_type = error |> member "type" |> to_string_option in
    Ollama_provider_error_fields { message; error_type }
  | `Null ->
    (match ollama_required_fields json with
     | Some (model, is_done) -> Ollama_data_fields (model, is_done)
     | None -> Ollama_malformed_fields "ollama_ndjson_missing_required_field")
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    Ollama_malformed_fields "ollama_ndjson_error_field_type"
;;

let parse_ollama_ndjson_chunk data_str : ollama_ndjson_parse_result =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string data_str in
    match ollama_line_shape json with
    | Ollama_provider_error_fields { message; error_type } ->
      Ollama_provider_error { message; error_type; raw = data_str }
    | Ollama_malformed_fields reason -> Ollama_parse_failed { reason; raw = data_str }
    | Ollama_data_fields (oll_model, oll_is_done) ->
      let oll_done_reason = json |> member "done_reason" |> to_string_option in
      let message = json |> member "message" in
      let oll_delta_content =
        match message with
        | `Assoc _ ->
          let s = message |> member "content" |> to_string_option in
          (match s with
           | Some "" -> None
           | other -> other)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
      in
      let oll_delta_thinking =
        match message with
        | `Assoc _ ->
          let s = message |> member "thinking" |> to_string_option in
          (match s with
           | Some "" -> None
           | other -> other)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
      in
      let oll_tool_calls =
        match message with
        | `Assoc _ ->
          (match message |> member "tool_calls" with
           | `List items ->
             List.mapi
               (fun idx tc ->
                  let func = tc |> member "function" in
                  let oll_tc_name = func |> member "name" |> to_string_option in
                  let oll_tc_id = tc |> member "id" |> to_string_option in
                  let oll_tc_arguments =
                    match func |> member "arguments" with
                    | `Null -> None
                    | (`Assoc _ | `List _) as v ->
                      Some (Args_complete (Yojson.Safe.to_string v))
                    | `String s -> Some (Args_fragment s)
                    | other -> Some (Args_complete (Yojson.Safe.to_string other))
                  in
                  { oll_tc_index = idx; oll_tc_id; oll_tc_name; oll_tc_arguments })
               items
           | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> [])
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
      in
      (* Token-count usage. Ollama only emits these on the done chunk.
         When both counts are zero we return None, matching the
         non-streaming path in [Backend_ollama.parse_ollama_response]
         so that a downstream consumer's usage-trust classification sees
         [Usage_missing] instead of [zero_token_usage_reported]. *)
      let oll_usage =
        let input = json |> member "prompt_eval_count" |> to_int_option in
        let output = json |> member "eval_count" |> to_int_option in
        match input, output with
        | None, None -> None
        | Some _, None | None, Some _ | Some _, Some _ ->
          let input_tokens = Option.value ~default:0 input in
          let output_tokens = Option.value ~default:0 output in
          if input_tokens = 0 && output_tokens = 0
          then None
          else
            Some
              { input_tokens
              ; output_tokens
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
      in
      (* inference_timings: same wire-format the non-streaming
         Backend_ollama.parse_ollama_response builds, so downstream
         (record_llm_tok_s_metrics) is byte-identical between the two
         paths. Durations are nanoseconds on the wire; convert to ms
         and tok/s here. *)
      let oll_timings =
        let prompt_n = json |> member "prompt_eval_count" |> to_int_option in
        let prompt_ns = json |> member "prompt_eval_duration" |> to_int_option in
        let predicted_n = json |> member "eval_count" |> to_int_option in
        let predicted_ns = json |> member "eval_duration" |> to_int_option in
        let any_set =
          Option.is_some prompt_n
          || Option.is_some prompt_ns
          || Option.is_some predicted_n
          || Option.is_some predicted_ns
        in
        if not any_set
        then None
        else (
          let ms_of_ns ns_opt = Option.map (fun ns -> float_of_int ns /. 1e6) ns_opt in
          let per_second n_opt ns_opt =
            match n_opt, ns_opt with
            | Some n, Some ns when ns > 0 ->
              Some (float_of_int n /. (float_of_int ns /. 1e9))
            | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
          in
          Some
            { prompt_n
            ; prompt_ms = ms_of_ns prompt_ns
            ; prompt_per_second = per_second prompt_n prompt_ns
            ; predicted_n
            ; predicted_ms = ms_of_ns predicted_ns
            ; predicted_per_second = per_second predicted_n predicted_ns
            ; cache_n = None
            })
      in
      Ollama_chunk
        { oll_model
        ; oll_delta_content
        ; oll_delta_thinking
        ; oll_tool_calls
        ; oll_done_reason
        ; oll_is_done
        ; oll_usage
        ; oll_timings
        }
  with
  | Yojson.Json_error message ->
    Ollama_parse_failed { reason = "json_error: " ^ message; raw = data_str }
  | Type_error (message, _) ->
    Ollama_parse_failed { reason = "type_error: " ^ message; raw = data_str }
;;

(** Convert a parsed {!ollama_chunk} into {!sse_event} list.
    Reuses {!openai_stream_state} for block index tracking. *)
let ollama_chunk_to_events (state : openai_stream_state) (chunk : ollama_chunk)
  : sse_event list * Telemetry_event.t option
  =
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  let emit_thinking_delta text =
    (match state.thinking_state with
     | Not_thinking -> state.thinking_state <- Thinking_started (Unix.gettimeofday ())
     | Thinking_started _ | Thinking_done -> ());
    if not state.thinking_block_started
    then (
      state.thinking_block_index <- state.next_block_index;
      emit
        (ContentBlockStart
           { index = state.next_block_index
           ; content_type = "thinking"
           ; tool_id = None
           ; tool_name = None
           });
      state.thinking_block_started <- true;
      state.next_block_index <- state.next_block_index + 1);
    emit
      (ContentBlockDelta
         { index = state.thinking_block_index; delta = ThinkingDelta text })
  in
  let emit_text_delta text =
    if not state.text_block_started
    then (
      state.text_block_index <- state.next_block_index;
      emit
        (ContentBlockStart
           { index = state.next_block_index
           ; content_type = "text"
           ; tool_id = None
           ; tool_name = None
           });
      state.text_block_started <- true;
      state.next_block_index <- state.next_block_index + 1);
    emit (ContentBlockDelta { index = state.text_block_index; delta = TextDelta text })
  in
  (* Thinking content delta *)
  (match chunk.oll_delta_thinking with
   | Some text when text <> "" -> emit_thinking_delta text
   | Some empty_thinking ->
     let (_ : string) = empty_thinking in
     (match state.thinking_state with
      | Thinking_started t0 ->
        let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
        state.thinking_state <- Thinking_done;
        telemetry_event
        := Some
             (Telemetry_event.Thinking_complete
                { provider = state.provider; model = state.model; thinking_duration_ms })
      | Not_thinking | Thinking_done -> ())
   | None ->
     (match state.thinking_state with
      | Thinking_started t0 ->
        let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
        state.thinking_state <- Thinking_done;
        telemetry_event
        := Some
             (Telemetry_event.Thinking_complete
                { provider = state.provider; model = state.model; thinking_duration_ms })
      | Not_thinking | Thinking_done -> ()));
  (* Text content delta. A template-parser model puts reasoning in this
     channel wrapped in tags; split it the way the OpenAI-compatible
     projection does so the reply block carries the reply and nothing else. *)
  (match chunk.oll_delta_content with
   | Some text when text <> "" ->
     (match state.inline_reasoning with
      | None -> emit_text_delta text
      | Some split ->
        emit_inline_segments state emit (Inline_reasoning_split.feed_segments split text))
   | Some empty_text ->
     let (_ : string) = empty_text in
     ()
   | None -> ());
  (* Tool calls. Ollama native streams can emit complete calls in separate
     chunks; each chunk's JSON array restarts its positional index. Therefore
     an id-less [Args_complete] item is a new occurrence even when a prior
     chunk used the same array index. String argument fragments remain routed
     by wire index until their call completes. *)
  List.iter
    (fun (tc : ollama_tool_call_delta) ->
       let idless_semantics =
         match non_blank_provider_tool_id tc.oll_tc_id, tc.oll_tc_arguments with
         | Some _, (Some (Args_fragment _ | Args_complete _) | None) ->
           Continue_by_wire_index
         | None, Some (Args_complete _) -> Complete_occurrence
         | None, (Some (Args_fragment _) | None) -> Continue_by_wire_index
       in
       let block_idx =
         resolve_tool_block
           state
           ~protocol:"ollama"
           ~wire_index:tc.oll_tc_index
           ~provider_tool_id:tc.oll_tc_id
           ~tool_name:tc.oll_tc_name
           ~index_policy:Next_available
           ~idless_semantics
       in
       let resolution, start = block_idx in
       Option.iter emit start;
       match resolution, tc.oll_tc_arguments with
       | Tool_block_resolved { block_index; _ }, Some (Args_fragment args) when args <> ""
         -> emit (ContentBlockDelta { index = block_index; delta = InputJsonDelta args })
       | Tool_block_resolved { block_index; _ }, Some (Args_complete args) when args <> ""
         ->
         emit (ContentBlockDelta { index = block_index; delta = InputJsonSnapshot args })
       | Tool_block_resolved _, Some (Args_fragment _ | Args_complete _)
       | Tool_block_resolved _, None -> ()
       | Tool_block_rejected error, _ -> emit error)
    chunk.oll_tool_calls;
  (* Terminal chunk: emit MessageDelta with stop_reason + usage. *)
  if chunk.oll_is_done
  then (
    (* Bytes the inline-reasoning splitter was holding back belong to this
       message; an unterminated tag means the stream was cut mid-thought.
       Paths that never see a done chunk (provider error, truncated stream)
       retain an incomplete outcome. Previously emitted deltas are already
       observable; terminal validation cannot retract them. *)
    (match state.inline_reasoning with
     | None -> ()
     | Some split ->
       emit_inline_segments state emit (Inline_reasoning_split.flush_segments split));
    let stop_reason =
      match chunk.oll_done_reason with
      (* Non-streaming parsing can reject before returning content. Streaming
         may already have delivered deltas, so absence stays [None] and the
         accumulator returns typed [Stream_incomplete] at finalization. *)
      | None -> None
      | Some reason ->
        Some
          (Stop_reason_wire.of_finish
             (Stop_reason_wire.wire_finish_of_string reason)
             ~has_tool_blocks:(chunk.oll_tool_calls <> []))
    in
    List.iter emit (openai_open_block_stops state);
    emit
      (MessageDelta
         { stop_reason
         ; usage =
             Option.map
               (fun (u : Types.api_usage) : Types.delta_usage ->
                  { input_tokens = Some u.input_tokens
                  ; output_tokens = Some u.output_tokens
                  ; cache_creation_input_tokens = None
                  ; cache_read_input_tokens = None
                  ; cost_usd = u.cost_usd
                  })
               chunk.oll_usage
         });
    emit MessageStop);
  List.rev !events, !telemetry_event
;;

[@@@coverage off]
(* ── parse_ollama_ndjson_chunk tests ──────────────────────── *)

let%test "parse_ollama_ndjson_chunk: content delta line" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":"hi"},"done":false}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    c.oll_model = "qwen3:8b"
    && c.oll_delta_content = Some "hi"
    && c.oll_delta_thinking = None
    && c.oll_tool_calls = []
    && (not c.oll_is_done)
    && c.oll_usage = None
    && c.oll_timings = None
;;

let%test "parse_ollama_ndjson_chunk: done line carries timings + usage" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},
       "done_reason":"stop","done":true,
       "prompt_eval_count":15,"prompt_eval_duration":300000000,
       "eval_count":50,"eval_duration":1000000000}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    c.oll_is_done
    && c.oll_done_reason = Some "stop"
    && (match c.oll_usage with
        | Some u -> u.input_tokens = 15 && u.output_tokens = 50
        | None -> false)
    &&
      (match c.oll_timings with
      | Some t ->
        t.predicted_n = Some 50
        && t.prompt_n = Some 15
        && (match t.predicted_per_second with
            | Some v -> abs_float (v -. 50.0) < 0.001
            | None -> false)
        &&
          (match t.prompt_per_second with
          | Some v -> abs_float (v -. 50.0) < 0.001
          | None -> false)
      | None -> false)
;;

let%test "parse_ollama_ndjson_chunk: zero eval_duration → per_second None" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},
       "done":true,"eval_count":10,"eval_duration":0}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_chunk c ->
    (match c.oll_timings with
     | Some t -> t.predicted_n = Some 10 && t.predicted_per_second = None
     | None -> false)
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
;;

let%test "parse_ollama_ndjson_chunk: tool_calls fully formed in done line" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":"",
       "tool_calls":[{"function":{"name":"foo","arguments":{"x":1}}}]},
       "done":true,"done_reason":"tool_calls"}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    (match c.oll_tool_calls with
     | [ tc ] ->
       tc.oll_tc_name = Some "foo"
       &&
         (match tc.oll_tc_arguments with
         | Some (Args_fragment args | Args_complete args) ->
           let json = Yojson.Safe.from_string args in
           json |> Yojson.Safe.Util.member "x" |> Yojson.Safe.Util.to_int = 1
         | None -> false)
     | unexpected_tool_calls ->
       let (_ : ollama_tool_call_delta list) = unexpected_tool_calls in
       false)
;;

let%test "parse_ollama_ndjson_chunk: malformed json is explicit" =
  match parse_ollama_ndjson_chunk "{not valid" with
  | Ollama_parse_failed _ -> true
  | Ollama_chunk _ | Ollama_provider_error _ -> false
;;

let%test "parse_ollama_ndjson_chunk: provider error is explicit" =
  match parse_ollama_ndjson_chunk {|{"error":"model failed"}|} with
  | Ollama_provider_error { message; error_type = None; raw } ->
    message = "model failed" && raw = {|{"error":"model failed"}|}
  | Ollama_chunk _ | Ollama_parse_failed _ -> false
  | Ollama_provider_error { error_type = Some _; _ } -> false
;;

let%test "parse_ollama_ndjson_chunk: missing provider message does not copy raw" =
  let raw = {|{"error":{"type":"server_error","detail":"opaque"}}|} in
  match parse_ollama_ndjson_chunk raw with
  | Ollama_provider_error { message; error_type = Some "server_error"; raw = r } ->
    message = "" && r = raw
  | Ollama_chunk _ | Ollama_parse_failed _ -> false
  | Ollama_provider_error { error_type = None; _ } -> false
  | Ollama_provider_error { error_type = Some _; _ } -> false
;;

let%test "parse_ollama_ndjson_chunk: done with zero token counts keeps chunk" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},
       "done_reason":"stop","done":true,
       "prompt_eval_count":0,"eval_count":0}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_chunk c -> c.oll_is_done && c.oll_usage = None
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
;;

(* ── ollama_chunk_to_events tests ─────────────────────────── *)

let%test "ollama_chunk_to_events: content delta emits Start+Delta" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = Some "hello"
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = None
    ; oll_is_done = false
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ ContentBlockStart { index = 0; content_type = "text"; _ }
    ; ContentBlockDelta { index = 0; delta = TextDelta "hello" }
    ] -> true
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: subsequent content delta reuses block" =
  let state = create_openai_stream_state () in
  let mk text =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = Some text
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = None
    ; oll_is_done = false
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let _ = ollama_chunk_to_events state (mk "he") in
  let events, _tel = ollama_chunk_to_events state (mk "llo") in
  (* Second chunk: only Delta, no new Start *)
  match events with
  | [ ContentBlockDelta { index = 0; delta = TextDelta "llo" } ] -> true
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: done with stop_reason emits MessageDelta" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = Some "stop"
    ; oll_is_done = true
    ; oll_usage =
        Some
          { input_tokens = 10
          ; output_tokens = 20
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ MessageDelta { stop_reason = Some EndTurn; usage = Some u }; MessageStop ] ->
    u.input_tokens = Some 10 && u.output_tokens = Some 20
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: overflow reason stays typed" =
  let state = create_openai_stream_state () in
  let chunk : ollama_chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = Some "model_context_window_exceeded"
    ; oll_is_done = true
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  match fst (ollama_chunk_to_events state chunk) with
  | [ MessageDelta { stop_reason = Some ContextWindowExceeded; usage = None }
    ; MessageStop
    ] -> true
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = None })::(MessageStop)::_::_
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = None })::(InlineContentReplay _ | ResponsesOutputItems _ | Ping | ( Connected | ( MessageStart _ | ( ContentBlockStart _ | ( ContentBlockDelta _ | ( ContentBlockStop _ | ( MessageDelta _ | ( SSEError _ | ( NDJSONError _ | ( SSEParseFailed _ | ( NDJSONParseFailed _ | ( SSEUnknownEventType _ | ( SSEUnsupportedPart _ | ( SSEUnsupportedResponse _ | ( Timeout _ | ( StreamIncomplete _ ))))))))))))))))::_
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = None })::[]
  | (MessageDelta { stop_reason = Some (ContextWindowExceeded); usage = Some _ })::_
  | (MessageDelta { stop_reason = Some (EndTurn | (StopToolUse | (MaxTokens | (StopSequence | (Refusal | (ContentFilter | (RepetitionTruncation | (PauseTurn | (Compaction | (UnmatchedToolCalls | Unknown _)))))))))); usage = _ })::_
  | (MessageDelta { stop_reason = None; usage = _ })::_
  | (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ ))))))))))))))))::_
  | [] -> false
;;

let%test "ollama_chunk_to_events: done with zero usage → usage=None" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls = []
    ; oll_done_reason = Some "stop"
    ; oll_is_done = true
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ MessageDelta { stop_reason = Some EndTurn; usage = None }; MessageStop ] -> true
  | ((MessageDelta { stop_reason = Some (EndTurn); usage = None })::(MessageStop)::_::_ | (MessageDelta { stop_reason = Some (EndTurn); usage = None })::(InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | ( ContentBlockStop _ | ( MessageDelta _ | ( SSEError _ | ( NDJSONError _ | ( SSEParseFailed _ | ( NDJSONParseFailed _ | ( SSEUnknownEventType _ | ( SSEUnsupportedPart _ | ( SSEUnsupportedResponse _ | ( Timeout _ | ( StreamIncomplete _ ))))))))))))))))::_ | (MessageDelta { stop_reason = Some (EndTurn); usage = None })::[] | (MessageDelta { stop_reason = Some (EndTurn); usage = Some _ })::_ | (MessageDelta { stop_reason = Some (StopToolUse | (MaxTokens | (StopSequence | (Refusal | (ContentFilter | (RepetitionTruncation | (PauseTurn | (Compaction | (ContextWindowExceeded | (UnmatchedToolCalls | Unknown _)))))))))); usage = _ })::_ | (MessageDelta { stop_reason = None; usage = _ })::_ | (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ ))))))))))))))))::_ | []) as unexpected_events -> let (_ : sse_event list) = unexpected_events in
    false
;;

let%test "ollama_chunk_to_events: tool_calls emit Start+InputJsonSnapshot" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = None
    ; oll_tool_calls =
        [ { oll_tc_index = 0
          ; oll_tc_id = None
          ; oll_tc_name = Some "search"
          ; oll_tc_arguments = Some (Args_complete {|{"q":"hello"}|})
          }
        ]
    ; oll_done_reason = Some "tool_calls"
    ; oll_is_done = true
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some tool_id
        ; tool_name = Some "search"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonSnapshot args }
      (* [openai_open_block_stops] closes every block this state opened once the
         terminal chunk arrives, so the tool block's stop belongs between the
         arguments and the message end. *)
    ; ContentBlockStop { index = 0 }
    ; MessageDelta { stop_reason = Some StopToolUse; _ }
    ; MessageStop
    ] -> String.starts_with ~prefix:"call_agent_core_" tool_id && args = {|{"q":"hello"}|}
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: thinking delta emits thinking block first" =
  let state = create_openai_stream_state () in
  let chunk =
    { oll_model = "qwen3:8b"
    ; oll_delta_content = None
    ; oll_delta_thinking = Some "considering"
    ; oll_tool_calls = []
    ; oll_done_reason = None
    ; oll_is_done = false
    ; oll_usage = None
    ; oll_timings = None
    }
  in
  let events, _tel = ollama_chunk_to_events state chunk in
  match events with
  | [ ContentBlockStart { index = 0; content_type = "thinking"; _ }
    ; ContentBlockDelta { index = 0; delta = ThinkingDelta "considering" }
    ] -> true
  | []
  | [ ( MessageStart _
      | ContentBlockStart _
      | ContentBlockDelta
          { delta =
              ( TextDelta _
              | TextSnapshot _
              | (ThinkingDelta _ | ThinkingSnapshot _)
              | ThinkingSignatureDelta _
              | RedactedThinkingSnapshot _
              | ReasoningDetailsDelta _
              | InputJsonDelta _
              | InputJsonSnapshot _
              | MediaDelta _ )
          ; _
          }
      | ContentBlockStop _
      | MessageDelta
          { stop_reason =
              ( None
              | Some
                  ( EndTurn
                  | StopToolUse
                  | MaxTokens
                  | StopSequence
                  | Refusal
                  | ContentFilter
                  | RepetitionTruncation
                  | PauseTurn
                  | Compaction
                  | ContextWindowExceeded
                  | UnmatchedToolCalls
                  | Unknown _ ) )
          ; _
          }
      | MessageStop
      | InlineContentReplay _ | ResponsesOutputItems _ | Ping
      | SSEError _
      | NDJSONError _
      | SSEParseFailed _
      | NDJSONParseFailed _
      | SSEUnknownEventType _
      | SSEUnsupportedPart _
      | SSEUnsupportedResponse _
      | Connected
      | Timeout _
      | StreamIncomplete _
       )
    ]
  | _ :: _ :: _ -> false
;;

let%test "ollama_chunk_to_events: inline think tags split across chunks stay out of the \
          reply"
  =
  (* An ollama-served template model that ignores think:false renders
     <think>...</think> inside [message.content]; a declared template model
     splits it here, tags fragmented across chunk boundaries included. *)
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed content =
    let line =
      Printf.sprintf
        {|{"model":"qwen3:8b","message":{"role":"assistant","content":"%s"},"done":false}|}
        content
    in
    match parse_ollama_ndjson_chunk line with
    | Ollama_chunk chunk -> fst (ollama_chunk_to_events state chunk)
    | Ollama_provider_error _ | Ollama_parse_failed _ -> []
  in
  (* Bound in order: [@] does not fix the order its arguments are evaluated in,
     and a stream fed backwards proves nothing. *)
  let first = feed "<thi" in
  let second = feed "nk>mid</th" in
  let third = feed "ink>answer" in
  let events = first @ second @ third in
  List.filter_map test_thinking_text events = [ "mid" ]
  && List.filter_map test_reply_text events = [ "answer" ]
;;

let%test "ollama_chunk_to_events: a cut thought is released as reasoning at done" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed line =
    match parse_ollama_ndjson_chunk line with
    | Ollama_chunk chunk -> fst (ollama_chunk_to_events state chunk)
    | Ollama_provider_error _ | Ollama_parse_failed _ -> []
  in
  let opened =
    feed
      {|{"model":"qwen3:8b","message":{"role":"assistant","content":"<think>cut off"},"done":false}|}
  in
  let terminal =
    feed
      {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}|}
  in
  let events = opened @ terminal in
  List.filter_map test_thinking_text events = [ "cut off" ]
  && List.filter_map test_reply_text events = []
;;

let%test "ollama_chunk_to_events: text resuming after a think block stays well-formed"
  =
  (* Each channel transition opens a fresh index, preserving the original
     order in both the live deltas and the final indexed block sequence. *)
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let feed content =
    let line =
      Printf.sprintf
        {|{"model":"qwen3:8b","message":{"role":"assistant","content":"%s"},"done":false}|}
        content
    in
    match parse_ollama_ndjson_chunk line with
    | Ollama_chunk chunk -> fst (ollama_chunk_to_events state chunk)
    | Ollama_provider_error _ | Ollama_parse_failed _ -> []
  in
  let first = feed "answer " in
  let second = feed "<think>more</think>" in
  let third = feed " tail" in
  let events = first @ second @ third in
  let starts =
    List.filter_map
      (function
        | ContentBlockStart { index; content_type; _ } -> Some (index, content_type)
        | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | Connected | MessageStart _ | ContentBlockDelta _ | ContentBlockStop _
        | MessageDelta _ | SSEError _ | NDJSONError _ | SSEParseFailed _ | NDJSONParseFailed _
        | SSEUnknownEventType _ | SSEUnsupportedPart _ | SSEUnsupportedResponse _ | Timeout _
        | StreamIncomplete _ -> None)
      events
  in
  List.filter_map test_thinking_text events = [ "more" ]
  && List.filter_map test_reply_text events = [ "answer "; " tail" ]
  && starts = [ 0, "text"; 1, "thinking"; 2, "text" ]
;;

(* parse_sse_event regression: the previous implementation returned [None]
   for both unknown event types and JSON parse failures, silently dropping
   the chunk. Downstream consumers then proceeded as if the chunk were a
   harmless heartbeat (like Ping), eventually finalizing without seeing
   MessageStop and presenting a phantom completion. The accumulator could
   not distinguish "no event in this chunk" from "we lost data here".
   These regression tests pin the new contract: the parser surfaces a
   structured failure event so the accumulator can react. *)

let%test "parse_sse_event: unknown event type yields SSEUnknownEventType" =
  let raw = "{\"type\":\"future_event_v3\"}" in
  match parse_sse_event None raw with
  | Some (SSEUnknownEventType { event_type; raw = r }) ->
    event_type = "future_event_v3" && r = raw
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: malformed JSON yields SSEParseFailed" =
  let raw = "{not valid json" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = r; reason }) -> r = raw && String.length reason > 0
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: type field missing yields SSEParseFailed" =
  (* A valid JSON object without its discriminator is malformed protocol data,
     not a future event type. Preserve that distinction for the stream error
     classifier; do not manufacture an empty event type. *)
  let raw = "{\"id\":\"foo\"}" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_missing"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: blank explicit event type yields SSEParseFailed" =
  let raw = "{}" in
  match parse_sse_event (Some "  ") raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_blank"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: non-string payload type yields SSEParseFailed" =
  let raw = "{\"type\":42}" in
  match parse_sse_event None raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_event_type_not_string"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: non-object payload yields SSEParseFailed" =
  let raw = "[]" in
  match parse_sse_event (Some "ping") raw with
  | Some (SSEParseFailed { raw = observed_raw; reason }) ->
    observed_raw = raw && reason = "sse_payload_must_be_object"
  | (Some (MessageStop | (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let%test "parse_sse_event: known event still parses normally" =
  (* Sanity: refactor must not regress the happy path. *)
  let raw = "{\"type\":\"message_stop\"}" in
  match parse_sse_event None raw with
  | Some MessageStop -> true
  | (Some (InlineContentReplay _ | ResponsesOutputItems _ | Ping | (Connected | (MessageStart _ | (ContentBlockStart _ | (ContentBlockDelta _ | (ContentBlockStop _ | (MessageDelta _ | (SSEError _ | (NDJSONError _ | (SSEParseFailed _ | (NDJSONParseFailed _ | (SSEUnknownEventType _ | (SSEUnsupportedPart _ | (SSEUnsupportedResponse _ | (Timeout _ | (StreamIncomplete _ )))))))))))))))) | None) as unexpected_event -> let (_ : sse_event option) = unexpected_event in
    false
;;

let[@warning "-32"] test_block_starts (events : sse_event list) =
  List.filter_map (function
    | ContentBlockStart {index;content_type;_} -> Some (index,content_type)
    | MessageStart _ | ContentBlockDelta _ | ContentBlockStop _ | MessageDelta _
    | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | SSEError _ | NDJSONError _ | SSEParseFailed _
    | NDJSONParseFailed _ | SSEUnknownEventType _ | SSEUnsupportedPart _
    | SSEUnsupportedResponse _ | Connected | Timeout _ | StreamIncomplete _ -> None) events
;;

let[@warning "-32"] test_block_deltas (events : sse_event list) =
  List.filter_map (function
    | ContentBlockDelta {index;delta} -> Some (index,delta)
    | MessageStart _ | ContentBlockStart _ | ContentBlockStop _ | MessageDelta _
    | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | SSEError _ | NDJSONError _ | SSEParseFailed _
    | NDJSONParseFailed _ | SSEUnknownEventType _ | SSEUnsupportedPart _
    | SSEUnsupportedResponse _ | Connected | Timeout _ | StreamIncomplete _ -> None) events
;;

let[@warning "-32"] test_is_parse_failed : sse_event -> bool = function
  | SSEParseFailed _ -> true
  | MessageStart _ | ContentBlockStart _ | ContentBlockDelta _ | ContentBlockStop _
  | MessageDelta _ | MessageStop | InlineContentReplay _ | ResponsesOutputItems _ | Ping | SSEError _ | NDJSONError _
  | NDJSONParseFailed _ | SSEUnknownEventType _ | SSEUnsupportedPart _
  | SSEUnsupportedResponse _ | Connected | Timeout _ | StreamIncomplete _ -> false
;;

let[@warning "-32"] test_thinking_text : content_delta -> string option = function
  | ThinkingDelta text | ThinkingSnapshot text -> Some text
  | TextDelta _ | TextSnapshot _ | ThinkingSignatureDelta _ | RedactedThinkingSnapshot _
  | ReasoningDetailsDelta _ | InputJsonDelta _ | InputJsonSnapshot _ | MediaDelta _ -> None
;;

let[@warning "-32"] test_visible_text : content_delta -> string option = function
  | TextDelta text -> Some text
  | TextSnapshot _ | (ThinkingDelta _ | ThinkingSnapshot _) | ThinkingSignatureDelta _ | RedactedThinkingSnapshot _
  | ReasoningDetailsDelta _ | InputJsonDelta _ | InputJsonSnapshot _ | MediaDelta _ -> None
;;

let%test "native details and inline reasoning retain distinct block payloads" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let chunk = { (test_content_chunk "A<think>B</think>C") with
    delta_reasoning_details = Some {delta_reasoning_content = Some "native"; delta_details = []} } in
  let events, _ = openai_chunk_to_events state chunk in
  let starts = test_block_starts events in
  let deltas = test_block_deltas events in
  starts = [0,"reasoning_details";1,"text";2,"thinking";3,"text"]
  && List.exists (fun (index, delta) -> index = 2 && test_thinking_text delta = Some "B") deltas
  && not (List.exists (fun (index, delta) -> index = 0 && Option.is_some (test_thinking_text delta)) deltas)
;;

let%test "inline answer emits incrementally after reasoning before terminal" =
  let state = create_openai_stream_state ~inline_reasoning:true () in
  let first, _ = openai_chunk_to_events state (test_content_chunk "<think>private</think>hel") in
  let second, _ = openai_chunk_to_events state (test_content_chunk "lo") in
  let visible events = List.filter_map (fun (_, delta) -> test_visible_text delta) (test_block_deltas events) in
  visible first = ["hel"] && visible second = ["lo"]
;;

let%test "rejected tool chunk restores inline mode and held tag bytes" =
  let check prefix rejected continuation expected =
    let state = create_openai_stream_state ~inline_reasoning:true () in
    let tool id =
      { tc_index = 0; tc_id = id; tc_name = Some "fixture";
        tc_arguments = Some (Args_fragment "") } in
    let initial = { (test_content_chunk prefix) with delta_tool_calls = [tool None] } in
    let before, _ = openai_chunk_to_events state initial in
    (* A provider identity cannot replace the synthesized identity of that
       existing call. The preceding content in this same chunk must roll back. *)
    let invalid = { (test_content_chunk rejected) with
      delta_tool_calls = [tool (Some "late-provider-id")] } in
    let rejected_events, _ = openai_chunk_to_events state invalid in
    let after, _ = openai_chunk_to_events state
      { (test_content_chunk continuation) with finish_reason = Some "stop" } in
    let payloads = List.filter_map (fun (_, delta) ->
      match test_visible_text delta with
      | Some text -> Some (`Text text)
      | None -> Option.map (fun text -> `Thinking text) (test_thinking_text delta))
      (test_block_deltas (before @ after)) in
    List.length rejected_events = 1 && List.for_all test_is_parse_failed rejected_events
    && payloads = expected
  in
  check "<thi" "nk>discarded</think>" "nk>private</think>reply"
    [`Thinking "private"; `Text "reply"]
  && check "<think>private</thi" "nk>discarded" "nk>reply"
    [`Thinking "private"; `Text "reply"]
;;
