(* See openai_stream_state.mli for module rationale. *)

open Types

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
           | Some { origin = Provider_supplied; _ } -> open_and_record ()
           | None -> reject Missing_block_identity)
        | Some (Tool_index_ambiguous _) | None -> open_and_record ()))
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
