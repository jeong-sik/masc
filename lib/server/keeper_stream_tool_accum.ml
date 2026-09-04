(* See keeper_stream_tool_accum.mli. Kept as a parallel turn-local collector to
   [Keeper_stream_media_accum] rather than a shared abstraction, for the same
   reason that one gives: the SSE bridge owns live translation and this owns
   durable persistence, so they stay on their own side of the AGENT_CORE-stream /
   chat-store boundary. *)

type open_block = {
  opened_at : int;
  stream_scope : int;
  provider_message_id : string option;
  raw_call_id : string;
  raw_call_name : string;
  call_id : string;
  call_name : string;
  execution_id : Ids.Execution_id.t option;
  (* Fragments arrive in order and are concatenated at finalize; a snapshot
     replaces them because the provider sends it as the whole argument object,
     not as one more fragment. *)
  args_fragments : string list;
}

type finalized_block = {
  block_index : int;
  stream_scope : int;
  provider_message_id : string option;
  raw_call_id : string;
  call : Keeper_chat_store.tool_call;
}

type turn_binding =
  { stream_scope : int
  ; sources : (int * int) list
  ; source_tool_use_count : int
  }

type execution_binding =
  { turn : int
  ; planned_index : int
  ; occurrence : Keeper_chat_events.tool_stream_occurrence
  ; execution_id : Ids.Execution_id.t
  }

type stream_phase =
  | Accepting_content
  | Stop_reason_seen of Agent_core.Types.stop_reason
  | Message_stopped

type t = {
  mutable blocks : (int * open_block) list;
  (* A conflicting start makes the whole provider block untrustworthy.  Keep
     its index closed until the matching terminator arrives; otherwise a third
     start could resurrect the first call's fragments under a new identity. *)
  mutable invalid_indices : int list;
  mutable finalized : (int * finalized_block) list;
  mutable quarantined : (int * int) list;
  mutable protocol_errors :
    ( Keeper_chat_events.stream_protocol_error_kind
      * Keeper_chat_events.tool_stream_occurrence
      * string )
      list;
  mutable current_stream_scope : int;
  mutable next_stream_scope : int;
  mutable current_message_id : string option;
  mutable current_message_start :
    (string * string * Agent_core.Types.api_usage option) option;
  mutable message_open : bool;
  mutable message_seen : bool;
  mutable current_scope_progress_seen : bool;
  mutable stream_phase : stream_phase;
  mutable invalid_scopes : int list;
  mutable runtime_attempt_seen : bool;
  (* Agent Core seals a streamed scope with the exact admission mapping before
     execution. Provider ids remain correlation data and never select a row. *)
  mutable turns : (int * turn_binding) list;
  mutable unmapped_turns : (int * int) list;
  mutable executions : execution_binding list;
  mutable next_opened_at : int;
}

let create () =
  { blocks = []
  ; invalid_indices = []
  ; finalized = []
  ; quarantined = []
  ; protocol_errors = []
  ; current_stream_scope = 0
  ; next_stream_scope = 1
  ; current_message_id = None
  ; current_message_start = None
  ; message_open = false
  ; message_seen = false
  ; current_scope_progress_seen = false
  ; stream_phase = Accepting_content
  ; invalid_scopes = []
  ; runtime_attempt_seen = false
  ; turns = []
  ; unmapped_turns = []
  ; executions = []
  ; next_opened_at = 0
  }

let current_stream_scope t = t.current_stream_scope

let block_for_index t index = List.assoc_opt index t.blocks

let replace_block t index block =
  t.blocks <- (index, block) :: List.remove_assoc index t.blocks

let drop_block t index = t.blocks <- List.remove_assoc index t.blocks

let invalidate_index t index =
  drop_block t index;
  if not (List.mem index t.invalid_indices)
  then t.invalid_indices <- index :: t.invalid_indices

let discard_open_scope t stream_scope =
  t.blocks <-
    List.filter
      (fun (_, (block : open_block)) -> block.stream_scope <> stream_scope)
      t.blocks;
;;

let invalidate_current_scope t =
  if not (List.mem t.current_stream_scope t.invalid_scopes)
  then t.invalid_scopes <- t.current_stream_scope :: t.invalid_scopes
;;

let current_scope_is_invalid t =
  List.mem t.current_stream_scope t.invalid_scopes
;;

let advance_to_empty_scope t =
  discard_open_scope t t.current_stream_scope;
  t.current_stream_scope <- t.next_stream_scope;
  t.next_stream_scope <- t.next_stream_scope + 1;
  t.current_message_id <- None;
  t.current_message_start <- None;
  t.message_open <- false;
  t.message_seen <- false;
  t.current_scope_progress_seen <- false;
  t.stream_phase <- Accepting_content;
  t.invalid_indices <- []
;;

let scope_is_sealed t stream_scope =
  List.exists
    (fun (_, (binding : turn_binding)) -> binding.stream_scope = stream_scope)
    t.turns
  || List.exists (fun (_, scope) -> scope = stream_scope) t.unmapped_turns
;;

let current_scope_is_sealed t = scope_is_sealed t t.current_stream_scope

let fail_current_scope t =
  if not (current_scope_is_sealed t) then invalidate_current_scope t
;;

let start_runtime_attempt t =
  let previous_scope =
    if t.runtime_attempt_seen && not (current_scope_is_sealed t)
    then Keeper_chat_events.Abandon_previous_scope
    else Keeper_chat_events.Preserve_previous_scope
  in
  (if t.runtime_attempt_seen
   then (
    (* A candidate may have closed a syntactically complete ToolUse block and
       then failed before Agent Core sealed its source map. Quarantine that
       uncommitted scope before advancing; otherwise a later fallback failure
       could persist the earlier candidate as normal delivery evidence. *)
    fail_current_scope t;
    advance_to_empty_scope t;
    (* Agent Core turn ordinals restart inside a fallback/outer retry. Their
       source bindings therefore belong to the active attempt, not the whole
       HTTP request. Only already sealed delivery/execution evidence remains
       append-only across that boundary. *)
    t.turns <- [];
    t.unmapped_turns <- [])
   else t.runtime_attempt_seen <- true);
  previous_scope
;;

let record_protocol_error t kind occurrence detail =
  t.protocol_errors <- (kind, occurrence, detail) :: t.protocol_errors
;;

let quarantine t ~kind ~stream_scope ~block_index detail =
  if not (List.mem (stream_scope, block_index) t.quarantined)
  then t.quarantined <- (stream_scope, block_index) :: t.quarantined;
  record_protocol_error t kind
    { Keeper_chat_events.stream_scope
    ; provider_message_id = None
    ; block_index
    }
    detail
;;

let quarantine_open_scope t ~kind ~detail =
  t.blocks
  |> List.filter (fun (_, (block : open_block)) ->
    block.stream_scope = t.current_stream_scope)
  |> List.iter (fun (index, (block : open_block)) ->
    quarantine t ~kind ~stream_scope:block.stream_scope ~block_index:index
      (Printf.sprintf "%s at stream_scope=%d block_index=%d"
         detail block.stream_scope index))
;;

let message_start_equal
    (left_id, left_model, left_usage)
    (right_id, right_model, right_usage) =
  String.equal left_id right_id
  && String.equal left_model right_model
  && Option.equal ( = ) left_usage right_usage
;;

let current_scope_has_tool_occurrence t =
  List.exists
    (fun (_, (block : open_block)) ->
       block.stream_scope = t.current_stream_scope)
    t.blocks
  || List.exists
       (fun (_, (block : finalized_block)) ->
          block.stream_scope = t.current_stream_scope)
       t.finalized
;;

let prepare_message_start t ~id ~model ~usage =
  let incoming_start = id, model, usage in
  let exact_open_replay =
    t.stream_phase = Accepting_content
    && Option.equal message_start_equal
         (Some incoming_start) t.current_message_start
  in
  if
    t.message_seen
    && t.stream_phase = Accepting_content
    && not t.current_scope_progress_seen
    && not exact_open_replay
    && not (current_scope_is_invalid t)
    && not (current_scope_has_tool_occurrence t)
  then
    (* Official clients may reject an oversized input after emitting only the
       provider turn prelude, then retry with a smaller history inside the same
       runtime candidate. That retry has no outer Runtime_attempt_started
       observation. A different MessageStart is therefore the first exact
       boundary available here. It is safe to advance only while the abandoned
       scope has no tool occurrence; post-tool retries stay fail-closed. *)
    advance_to_empty_scope t
;;

let start_message_scope t ~id ~model ~usage =
  let incoming_start = id, model, usage in
  let message_id =
    if String.trim id = "" then None else Some id
  in
  if
    t.stream_phase = Accepting_content
    && t.message_seen
    && Option.equal message_start_equal
         (Some incoming_start) t.current_message_start
  then
    (* Exact prelude replay within one still-open producer call. *)
    t.message_open <- true
  else if not t.message_seen
  then (
    t.current_message_id <- message_id;
    t.current_message_start <- Some incoming_start;
    t.message_open <- true;
    t.message_seen <- true)
  else
    (* A provider-call boundary is established only after the current scope is
       sealed by Agent Core. Any other MessageStart in this unsealed scope is
       the producer's [message_start_conflict], including an exact prelude
       replay after [MessageStop]. *)
    (quarantine_open_scope t
       ~kind:Keeper_chat_events.Tool_message_start_conflict
       ~detail:"different MessageStart superseded an open tool occurrence";
     invalidate_current_scope t;
     t.message_open <- false)
;;

let ensure_message_scope t =
  if t.message_open
  then ()
  else if not t.message_seen
  then (
    t.message_open <- true;
    t.message_seen <- true)
  else if t.stream_phase = Accepting_content
  then t.message_open <- true
  else invalidate_current_scope t
;;

let finalized_at_current_index t index =
  List.filter
    (fun (_, (finalized : finalized_block)) ->
       finalized.stream_scope = t.current_stream_scope
       && finalized.block_index = index)
    t.finalized
;;

let quarantine_finalized_tool_delta t ~kind ~index ~delta_kind =
  match finalized_at_current_index t index with
  | [] -> false
  | finalized ->
    List.iter
      (fun (_, (block : finalized_block)) ->
         quarantine t ~kind ~stream_scope:block.stream_scope ~block_index:index
           (Printf.sprintf
              "%s delta arrived after tool block stop at stream_scope=%d block_index=%d"
              delta_kind block.stream_scope index))
      finalized;
    true
;;

let invalidate_header_conflict t ~index ~detail =
  let finalized = finalized_at_current_index t index in
  let conflicted = Option.is_some (block_for_index t index) || finalized <> [] in
  (match block_for_index t index with
   | Some block ->
     quarantine t ~kind:Keeper_chat_events.Tool_start_duplicate_index
       ~stream_scope:block.stream_scope ~block_index:index
       (Printf.sprintf "%s at stream_scope=%d block_index=%d"
          detail block.stream_scope index)
   | None ->
     finalized
     |> List.iter (fun (_, (block : finalized_block)) ->
       quarantine t ~kind:Keeper_chat_events.Tool_start_duplicate_index
         ~stream_scope:block.stream_scope ~block_index:index
         (Printf.sprintf "%s at stream_scope=%d block_index=%d"
            detail block.stream_scope index)));
  invalidate_index t index;
  conflicted
;;

let quarantine_incompatible_tool_delta t ~index ~delta_kind =
  let detail stream_scope =
    Printf.sprintf
      "non-input %s delta arrived for tool block at stream_scope=%d block_index=%d"
      delta_kind stream_scope index
  in
  match block_for_index t index with
  | Some block ->
    quarantine t ~kind:Keeper_chat_events.Tool_delta_invalid_kind
      ~stream_scope:block.stream_scope ~block_index:index
      (detail block.stream_scope);
    invalidate_index t index;
    true
  | None ->
    quarantine_finalized_tool_delta t
      ~kind:Keeper_chat_events.Tool_delta_invalid_kind ~index ~delta_kind
;;

let take_protocol_errors t =
  let errors = List.rev t.protocol_errors in
  t.protocol_errors <- [];
  errors
;;

let finalize_block t index =
  match block_for_index t index with
  | None -> ()
  | Some block ->
    drop_block t index;
    let args = String.concat "" (List.rev block.args_fragments) in
    let call : Keeper_chat_store.tool_call =
      { call_id = block.call_id
      ; execution_id = block.execution_id
      ; call_name = block.call_name
      ; args
      }
    in
    t.finalized <-
      ( block.opened_at
      , { block_index = index
        ; stream_scope = block.stream_scope
        ; provider_message_id = block.provider_message_id
        ; raw_call_id = block.raw_call_id
        ; call
        } )
      :: t.finalized

let append_fragment t index fragment =
  match block_for_index t index with
  | None -> ()
  | Some block ->
    replace_block t index
      { block with args_fragments = fragment :: block.args_fragments }

let replace_fragments t index snapshot =
  match block_for_index t index with
  | None -> ()
  | Some block -> replace_block t index { block with args_fragments = [ snapshot ] }

let unique ints = List.length ints = List.length (List.sort_uniq Int.compare ints)

let source_exists_exactly_once t ~stream_scope ~block_index =
  let open_count =
    List.fold_left
      (fun count (index, (block : open_block)) ->
         if index = block_index && block.stream_scope = stream_scope
         then count + 1
         else count)
      0
      t.blocks
  in
  let finalized_count =
    List.fold_left
      (fun count (_, (finalized : finalized_block)) ->
         if
           finalized.block_index = block_index
           && finalized.stream_scope = stream_scope
         then count + 1
         else count)
      0
      t.finalized
  in
  open_count + finalized_count = 1
;;

let validate_closed_scope t ~stream_scope ~streamed_block_indices =
  let has_unfinalized_blocks =
    List.exists
      (fun (_, (block : open_block)) -> block.stream_scope = stream_scope)
      t.blocks
  in
  if List.mem stream_scope t.invalid_scopes
  then Error (Printf.sprintf "stream scope %d is invalid" stream_scope)
  else if has_unfinalized_blocks
  then Error "turn closed with an unfinalized streamed tool block"
  else if not (unique streamed_block_indices)
  then Error "stream scope contains duplicate trusted tool block indices"
  else if List.exists (fun (scope, _) -> scope = stream_scope) t.quarantined
  then
    Error
      (Printf.sprintf
         "stream scope %d contains a quarantined tool occurrence"
         stream_scope)
  else Ok ()
;;

let seal_turn t ~turn ~(tool_source_map : Agent_core.Hooks.admitted_tool_source_map) =
  let admitted_tool_sources = tool_source_map.admitted_tool_sources in
  let source_tool_use_count = tool_source_map.source_tool_use_count in
  let stream_scope = t.current_stream_scope in
  let streamed_block_indices =
    t.finalized
    |> List.filter_map (fun (_, (finalized : finalized_block)) ->
      if finalized.stream_scope = stream_scope
      then Some finalized.block_index
      else None)
    |> List.sort Int.compare
  in
  let source_pairs =
    List.map
      (fun (source : Agent_core.Hooks.admitted_tool_use_source) ->
         source.planned_index, source.source_tool_use_ordinal)
      admitted_tool_sources
  in
  let planned_indices = List.map fst source_pairs in
  let source_tool_indices = List.map snd source_pairs in
  let expected_planned_indices = List.init (List.length source_pairs) Fun.id in
  let closed_scope =
    validate_closed_scope t ~stream_scope ~streamed_block_indices
  in
  if turn < 0
  then Error "Agent Core turn must be non-negative"
  else if source_tool_use_count < 0
  then Error "pre-admission ToolUse inventory must be non-negative"
  else if
    not
      (List.for_all
         (fun (planned, source_tool_use_ordinal) ->
            planned >= 0 && source_tool_use_ordinal >= 0)
         source_pairs)
  then Error "tool source coordinates must be non-negative"
  else if not (unique planned_indices)
  then Error "tool source mapping repeats a planned_index"
  else if not (unique source_tool_indices)
  then Error "tool source mapping assigns one pre-admission ToolUse twice"
  else if not (List.equal Int.equal planned_indices expected_planned_indices)
  then Error "tool source list must be ordered by contiguous planned_index"
  else if
    not
      (List.equal
         Int.equal
         source_tool_indices
         (List.sort_uniq Int.compare source_tool_indices))
  then Error "tool source ordinals must be strictly increasing"
  else
    match closed_scope with
    | Error detail -> Error detail
    | Ok () when List.length streamed_block_indices <> source_tool_use_count ->
      Error
        (Printf.sprintf
           "stream scope %d has %d trusted tool blocks but Agent Core observed %d pre-admission ToolUse blocks"
           stream_scope (List.length streamed_block_indices) source_tool_use_count)
    | Ok () ->
    let sources_result =
      List.fold_left
        (fun result (planned_index, source_tool_use_ordinal) ->
           let ( let* ) = Result.bind in
           let* sources = result in
           match List.nth_opt streamed_block_indices source_tool_use_ordinal with
           | None ->
             Error
               (Printf.sprintf
                  "pre-admission tool index %d does not exist in stream scope %d"
                  source_tool_use_ordinal stream_scope)
           | Some block_index ->
             if source_exists_exactly_once t ~stream_scope ~block_index
             then Ok ((planned_index, block_index) :: sources)
             else
               Error
                 (Printf.sprintf
                    "stream scope %d block %d is not one exact tool occurrence"
                    stream_scope block_index))
        (Ok [])
        source_pairs
      |> Result.map List.rev
    in
    let ( let* ) = Result.bind in
    let* sources = sources_result in
    if List.mem_assoc turn t.unmapped_turns
    then Error (Printf.sprintf "Agent Core turn %d closed without source mapping" turn)
    else match List.assoc_opt turn t.turns with
    | Some recorded
      when recorded.stream_scope = stream_scope
           && List.equal ( = ) recorded.sources sources
           && recorded.source_tool_use_count = source_tool_use_count ->
      Ok ()
    | Some _ ->
      Error (Printf.sprintf "Agent Core turn %d was already sealed differently" turn)
    | None ->
      (match
         List.find_opt
           (fun (_, (binding : turn_binding)) ->
              binding.stream_scope = stream_scope)
           t.turns
       with
       | Some (recorded_turn, _) ->
         Error
           (Printf.sprintf
              "stream scope %d already belongs to Agent Core turn %d"
              stream_scope recorded_turn)
       | None ->
         t.turns <-
           (turn, { stream_scope; sources; source_tool_use_count }) :: t.turns;
         Ok ())
;;

let close_turn_without_sources t ~turn =
  let stream_scope = t.current_stream_scope in
  let streamed_block_indices =
    t.finalized
    |> List.filter_map (fun (_, (finalized : finalized_block)) ->
      if finalized.stream_scope = stream_scope
      then Some finalized.block_index
      else None)
    |> List.sort Int.compare
  in
  if turn < 0
  then Error "Agent Core turn must be non-negative"
  else match validate_closed_scope t ~stream_scope ~streamed_block_indices with
  | Error detail -> Error detail
  | Ok () ->
    (match List.assoc_opt turn t.unmapped_turns with
     | Some recorded_scope when recorded_scope = stream_scope -> Ok ()
     | Some _ ->
       Error (Printf.sprintf "unmapped Agent Core turn %d closed twice" turn)
     | None ->
       if List.mem_assoc turn t.turns
       then Error (Printf.sprintf "Agent Core turn %d already has exact sources" turn)
       else if
         List.exists
           (fun (_, (binding : turn_binding)) ->
              binding.stream_scope = stream_scope)
           t.turns
         || List.exists
              (fun (_, recorded_scope) -> recorded_scope = stream_scope)
              t.unmapped_turns
       then
         Error (Printf.sprintf "stream scope %d already belongs to another turn" stream_scope)
       else (
         t.unmapped_turns <- (turn, stream_scope) :: t.unmapped_turns;
         Ok ()))
;;

let occurrence_equal
    (left : Keeper_chat_events.tool_stream_occurrence)
    (right : Keeper_chat_events.tool_stream_occurrence) =
  left.stream_scope = right.stream_scope
  && left.block_index = right.block_index
;;

let record_execution_id t ~tool_call_id ~turn ~planned_index ~execution_id =
  let ( let* ) = Result.bind in
  let* binding =
    match List.assoc_opt turn t.turns with
    | Some binding -> Ok binding
    | None when List.mem_assoc turn t.unmapped_turns ->
      Error (Printf.sprintf "Agent Core turn %d closed without exact tool sources" turn)
    | None -> Error (Printf.sprintf "Agent Core turn %d was not sealed" turn)
  in
  let* block_index =
    match List.assoc_opt planned_index binding.sources with
    | Some block_index -> Ok block_index
    | None ->
      Error
        (Printf.sprintf
           "Agent Core turn %d has no planned_index %d"
           turn planned_index)
  in
  let stream_scope = binding.stream_scope in
  if List.mem (stream_scope, block_index) t.quarantined
  then Error "tool result names a quarantined streamed occurrence"
  else
    let open_matches =
      List.filter
        (fun (index, (block : open_block)) ->
           index = block_index && block.stream_scope = stream_scope)
        t.blocks
    in
    let finalized_matches =
      List.filter
        (fun (_, (finalized : finalized_block)) ->
           finalized.block_index = block_index
           && finalized.stream_scope = stream_scope)
        t.finalized
    in
    let occurrence ~provider_message_id =
      { Keeper_chat_events.stream_scope; provider_message_id; block_index }
    in
    let provider_id_matches raw_call_id =
      let correlation = String.trim tool_call_id in
      if correlation = "" || String.equal raw_call_id tool_call_id
      then Ok ()
      else
        Error
          (Printf.sprintf
             "tool result provider id conflicts at turn=%d planned_index=%d"
             turn planned_index)
    in
    let execution_is_available target_occurrence =
      match
        List.find_opt
          (fun owner -> Ids.Execution_id.equal owner.execution_id execution_id)
          t.executions
      with
      | None -> Ok ()
      | Some owner
        when owner.turn = turn
             && owner.planned_index = planned_index
             && occurrence_equal owner.occurrence target_occurrence ->
        Ok ()
      | Some _ ->
        Error "canonical execution_id already belongs to another streamed occurrence"
    in
    let remember target_occurrence =
      if
        not
          (List.exists
             (fun owner ->
                owner.turn = turn
                && owner.planned_index = planned_index
                && occurrence_equal owner.occurrence target_occurrence)
             t.executions)
      then
        t.executions <-
          { turn; planned_index; occurrence = target_occurrence; execution_id }
          :: t.executions;
      Ok target_occurrence
    in
    match open_matches, finalized_matches with
    | [ index, block ], [] ->
      let target_occurrence = occurrence ~provider_message_id:block.provider_message_id in
      let* () = provider_id_matches block.raw_call_id in
      let* () = execution_is_available target_occurrence in
      (match block.execution_id with
       | Some recorded when not (Ids.Execution_id.equal recorded execution_id) ->
         Error "streamed occurrence already has a different canonical execution_id"
       | Some _ -> remember target_occurrence
       | None ->
         replace_block t index { block with execution_id = Some execution_id };
         remember target_occurrence)
    | [], [ opened_at, finalized ] ->
      let target_occurrence =
        occurrence ~provider_message_id:finalized.provider_message_id
      in
      let* () = provider_id_matches finalized.raw_call_id in
      let* () = execution_is_available target_occurrence in
      (match finalized.call.execution_id with
       | Some recorded when not (Ids.Execution_id.equal recorded execution_id) ->
         Error "streamed occurrence already has a different canonical execution_id"
       | Some _ -> remember target_occurrence
       | None ->
         t.finalized <-
           ( opened_at
           , { finalized with
               call = { finalized.call with execution_id = Some execution_id }
             } )
           :: List.remove_assoc opened_at t.finalized;
         remember target_occurrence)
    | [], [] ->
      Error
        (Printf.sprintf
           "tool result names no collected occurrence: turn=%d planned_index=%d"
           turn planned_index)
    | open_matches, finalized_matches ->
      Error
        (Printf.sprintf
           "tool result occurrence turn=%d planned_index=%d matched %d open and %d finalized calls"
           turn planned_index (List.length open_matches)
           (List.length finalized_matches))

(* [sse_event_is_deliverable_progress_signal] answers a [content_type = "tool_use"]
   check alone (agent_core's [Streaming.sse_event_is_deliverable_progress_signal]),
   independent of whether identity fields are populated. Keeping that check
   separate from the identity check below lets the malformed-but-tool-typed
   case (deliverable, no id/name) be told apart from a genuinely non-tool
   start (not deliverable): the bridge voids the former
   (Tool_start_missing_identity, keeper_chat_agent_core_stream_bridge.ml's
   ContentBlockStart handler) and leaves the latter's index untouched. *)
let stream_start_is_tool_progress (evt : Agent_core.Types.sse_event) =
  match evt with
  | Agent_core.Types.ContentBlockStart _ ->
    Agent_core.Llm_provider.Streaming.sse_event_is_deliverable_progress_signal evt
  | _ -> false

let stream_start_has_tool_name (evt : Agent_core.Types.sse_event) =
  match evt with
  | Agent_core.Types.ContentBlockStart
      { tool_id = Some id; tool_name = Some name; _ } ->
    String.trim id <> "" && String.trim name <> ""
  | _ -> false

let stream_start_is_tool evt =
  stream_start_is_tool_progress evt && stream_start_has_tool_name evt

let finalize_open_blocks t =
  t.blocks
  |> List.map fst
  |> List.iter (finalize_block t)
;;

let content_event_allowed t (evt : Agent_core.Types.sse_event) =
  match evt, t.stream_phase with
  | (Agent_core.Types.ContentBlockStart _ | Agent_core.Types.ContentBlockDelta _),
    Accepting_content -> true
  | Agent_core.Types.ContentBlockStop _,
    (Accepting_content | Stop_reason_seen _) -> true
  | (Agent_core.Types.ContentBlockStart _ | Agent_core.Types.ContentBlockDelta _
    | Agent_core.Types.ContentBlockStop _),
    (Stop_reason_seen _ | Message_stopped) -> false
  | _ -> true
;;

let on_event t (evt : Agent_core.Types.sse_event) =
  if scope_is_sealed t t.current_stream_scope then advance_to_empty_scope t;
  (match evt with
   | Agent_core.Types.MessageStart { id; model; usage } ->
     prepare_message_start t ~id ~model ~usage
   | _ -> ());
  (match evt with
   | Agent_core.Types.MessageStart _
   | Agent_core.Types.Connected
   | Agent_core.Types.Ping
   | Agent_core.Types.Timeout _ -> ()
   | _ -> t.current_scope_progress_seen <- true);
  if not (content_event_allowed t evt)
  then invalidate_current_scope t
  else if current_scope_is_invalid t
  then ()
  else
  match evt with
  | Agent_core.Types.MessageStart { id; model; usage } ->
    start_message_scope t ~id ~model ~usage
  | Agent_core.Types.MessageDelta { stop_reason; _ } ->
    (match t.stream_phase, stop_reason with
     | Accepting_content, None -> ()
     | Accepting_content, Some stop_reason ->
       finalize_open_blocks t;
       t.stream_phase <- Stop_reason_seen stop_reason;
       t.message_open <- false
     | Stop_reason_seen _, None -> ()
     | Stop_reason_seen recorded, Some replay when recorded = replay -> ()
     | Stop_reason_seen _, Some _
     | Message_stopped, None
     | Message_stopped, Some _ -> invalidate_current_scope t)
  | Agent_core.Types.ContentBlockStart { index; tool_id; tool_name; _ } ->
    ensure_message_scope t;
    if current_scope_is_invalid t
    then ()
    else if stream_start_is_tool evt then (
      match tool_id, tool_name with
      | Some raw_call_id, Some raw_call_name ->
        let call_id = raw_call_id in
        let call_name = String.trim raw_call_name in
        let stream_scope = t.current_stream_scope in
        let provider_message_id = t.current_message_id in
        let finalized_at_index =
          List.filter
            (fun (_, (finalized : finalized_block)) ->
              finalized.stream_scope = stream_scope
              && finalized.block_index = index)
            t.finalized
        in
        (match finalized_at_index with
         | [ _, _ ] ->
           quarantine t ~kind:Keeper_chat_events.Tool_start_duplicate_index
             ~stream_scope ~block_index:index
             (Printf.sprintf
                "tool block start arrived after stop at stream_scope=%d block_index=%d"
                stream_scope index);
           invalidate_index t index;
           invalidate_current_scope t
         | [] ->
           (match block_for_index t index with
      (* Providers may replay a start event after its JSON deltas. It is the
         same open block, not a replacement, so retaining it preserves the
         already received fragments. A conflicting replay is malformed and is
         dropped rather than combining two calls under one block index. *)
      (* DET-OK: these are exact equality checks on the provider's opaque
         identifiers; neither absence nor a new identity is defaulted. *)
      | Some block
        when String.equal block.raw_call_id raw_call_id
             && String.equal block.raw_call_name raw_call_name
             && block.args_fragments = [] ->
        ()
      | Some block ->
        quarantine t ~kind:Keeper_chat_events.Tool_start_duplicate_index
          ~stream_scope:block.stream_scope ~block_index:index
          (Printf.sprintf
             "ambiguous repeated tool start at stream_scope=%d block_index=%d"
             block.stream_scope index);
        invalidate_index t index
        ; invalidate_current_scope t
      | None ->
        if List.mem index t.invalid_indices
        then invalidate_current_scope t
        else
          let opened_at = t.next_opened_at in
          t.next_opened_at <- opened_at + 1;
          replace_block t index
            { opened_at
            ; stream_scope
            ; provider_message_id
            ; raw_call_id
            ; raw_call_name
            ; call_id
            ; call_name
            ; execution_id = None
            ; args_fragments = []
            })
         | conflicts ->
           List.iter
             (fun (_, (finalized : finalized_block)) ->
                quarantine t
                  ~kind:Keeper_chat_events.Tool_start_duplicate_index
                  ~stream_scope:finalized.stream_scope
                  ~block_index:finalized.block_index
                  (Printf.sprintf
                     "conflicting finalized tool identity at stream_scope=%d block_index=%d"
                     finalized.stream_scope finalized.block_index))
             conflicts;
           invalidate_index t index;
           invalidate_current_scope t)
      | None, _ | _, None ->
        (* [stream_start_is_tool] proves this arm unreachable, but keep the
           malformed event fail-closed if the shared predicate changes. *)
        invalidate_index t index;
        invalidate_current_scope t)
    else if stream_start_is_tool_progress evt
    then
      (* Deliverable tool-use content type but missing/blank identity: the
         live bridge voids this index (Tool_start_missing_identity)
         until its terminator, so a later valid start at the same index must
         not resurrect it as a fresh block. *)
      (let (_ : bool) =
         invalidate_header_conflict t ~index
           ~detail:"malformed tool-use block header conflicts with occupied index"
       in
       invalidate_current_scope t)
    else
      let conflicted =
        invalidate_header_conflict t ~index
          ~detail:"non-tool content block header conflicts with occupied index"
      in
      if conflicted then invalidate_current_scope t
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.InputJsonDelta fragment } ->
    (match block_for_index t index with
     | Some _ -> append_fragment t index fragment
     | None ->
       let conflicted =
         quarantine_finalized_tool_delta t
           ~kind:Keeper_chat_events.Tool_args_without_start
           ~index ~delta_kind:"input-json"
       in
       invalidate_index t index;
       if conflicted then invalidate_current_scope t)
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.InputJsonSnapshot snapshot } ->
    (match block_for_index t index with
     | Some _ -> replace_fragments t index snapshot
     | None ->
       let conflicted =
         quarantine_finalized_tool_delta t
           ~kind:Keeper_chat_events.Tool_args_without_start
           ~index ~delta_kind:"input-json"
       in
       invalidate_index t index;
       if conflicted then invalidate_current_scope t)
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.TextDelta _ | Agent_core.Types.TextSnapshot _ } ->
    if quarantine_incompatible_tool_delta t ~index ~delta_kind:"text"
    then invalidate_current_scope t
    else invalidate_index t index
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.ThinkingDelta _ } ->
    if quarantine_incompatible_tool_delta t ~index ~delta_kind:"thinking"
    then invalidate_current_scope t
    else invalidate_index t index
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.ReasoningDetailsDelta _ } ->
    if
      quarantine_incompatible_tool_delta t ~index ~delta_kind:"reasoning-details"
    then invalidate_current_scope t
    else invalidate_index t index
  | Agent_core.Types.ContentBlockDelta
      { index; delta = Agent_core.Types.ThinkingSignatureDelta _ } ->
    if
      quarantine_incompatible_tool_delta t ~index ~delta_kind:"thinking-signature"
    then invalidate_current_scope t
    else invalidate_index t index
  | Agent_core.Types.ContentBlockDelta { index; delta = Agent_core.Types.MediaDelta _ } ->
    (* Canonical Agent Core streams announce media before its delta. Keep this
       direct-consumer defense for malformed/bypassing callers: a bare media
       delta still occupies the index, so a later tool start cannot create a
       durable row the live bridge rejected. A delta landing on an open tool
       block leaves that block in place while quarantining its scope. *)
    if quarantine_incompatible_tool_delta t ~index ~delta_kind:"media"
    then invalidate_current_scope t
    else invalidate_index t index
  | Agent_core.Types.ContentBlockStop { index } ->
    if List.mem index t.invalid_indices
    then ()
    else finalize_block t index
  | Agent_core.Types.MessageStop ->
    (match t.stream_phase with
     | Message_stopped -> ()
     | Accepting_content ->
       finalize_open_blocks t;
       t.message_open <- false;
       t.stream_phase <- Message_stopped;
       invalidate_current_scope t
     | Stop_reason_seen _ ->
       finalize_open_blocks t;
       t.message_open <- false;
       t.stream_phase <- Message_stopped)
  | Agent_core.Types.SSEError _
  | Agent_core.Types.NDJSONError _
  | Agent_core.Types.SSEParseFailed _
  | Agent_core.Types.NDJSONParseFailed _
  | Agent_core.Types.SSEUnknownEventType _
  | Agent_core.Types.SSEUnsupportedPart _
  | Agent_core.Types.SSEUnsupportedResponse _
  (* A repeat ends the generation, not just its tool blocks: the text this
     scope carries is the repetition itself. *)
  | Agent_core.Types.StreamRepeating _ -> invalidate_current_scope t
  | Agent_core.Types.StreamIncomplete { reason } ->
    let stream_scope = t.current_stream_scope in
    let (_ : string) = reason in
    (* Incomplete disposition drops ToolUse blocks in the canonical producer
       while preserving valid text/media. Mirror that projection without
       poisoning the whole scope: remove every tool occurrence in this scope,
       so a subsequent source-free close remains valid. The live bridge emits
       the reader-facing quarantine diagnostic. *)
    discard_open_scope t stream_scope;
    t.finalized <-
      List.filter
        (fun (_, (block : finalized_block)) ->
           block.stream_scope <> stream_scope)
        t.finalized
  | Agent_core.Types.Connected
  | Agent_core.Types.Ping
  | Agent_core.Types.Timeout _ -> ()
;;

let to_tool_calls t =
  t.finalized
  |> List.filter (fun (_, (finalized : finalized_block)) ->
    (not (List.mem finalized.stream_scope t.invalid_scopes))
    && not (List.mem (finalized.stream_scope, finalized.block_index) t.quarantined))
  |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
  |> List.map (fun (_, finalized) -> finalized.call)

let to_tool_calls_for_failure t =
  fail_current_scope t;
  to_tool_calls t
;;
