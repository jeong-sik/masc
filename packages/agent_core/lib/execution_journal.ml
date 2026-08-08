open Result_syntax
module Event = Execution_event
module Store = Execution_event_store

let reverse_append_cooperatively values tail =
  let rec loop reversed = function
    | [] -> reversed
    | value :: rest ->
      Eio.Fiber.yield ();
      loop (value :: reversed) rest
  in
  loop tail values
;;

let reverse_cooperatively values = reverse_append_cooperatively values []

let reverse_filter_map_cooperatively f values =
  let rec loop filtered = function
    | [] -> filtered
    | value :: rest ->
      let filtered =
        match f value with
        | None -> filtered
        | Some value -> value :: filtered
      in
      Eio.Fiber.yield ();
      loop filtered rest
  in
  loop [] values
;;

let append_cooperatively left right =
  reverse_append_cooperatively (reverse_cooperatively left) right
;;

module Event_id_set = Set.Make (struct
    type t = Event.Event_id.t

    let compare = Event.Event_id.compare
  end)

module Node_id_map = Map.Make (struct
    type t = Event.Node_id.t

    let compare = Event.Node_id.compare
  end)

module Node_id_set = Set.Make (struct
    type t = Event.Node_id.t

    let compare = Event.Node_id.compare
  end)

module Run_id_map = Map.Make (struct
    type t = Event.Run_id.t

    let compare = Event.Run_id.compare
  end)

module Occurrence = struct
  type t =
    | Agent_turn of int
    | Provider_attempt of int
    | Tool_invocation of int

  let compare left right =
    match left, right with
    | Agent_turn left, Agent_turn right
    | Provider_attempt left, Provider_attempt right
    | Tool_invocation left, Tool_invocation right -> Int.compare left right
    | Agent_turn _, (Provider_attempt _ | Tool_invocation _) -> -1
    | Provider_attempt _, Agent_turn _ -> 1
    | Provider_attempt _, Tool_invocation _ -> -1
    | Tool_invocation _, (Agent_turn _ | Provider_attempt _) -> 1
  ;;
end

module Occurrence_map = Map.Make (Occurrence)

type run =
  { id : Event.Run_id.t
  ; root : Event.Node_id.t
  }

let run_id run = run.id
let run_root run = run.root

let equal_run left right =
  Event.Run_id.equal left.id right.id && Event.Node_id.equal left.root right.root
;;

type 'a event_record =
  { event : Event.t
  ; value : 'a
  }

type node_status =
  | Open
  | Closed of Event.terminal event_record

type materialized =
  | Agent_run_state
  | Agent_turn_state
  | Provider_attempt_state of { response : Llm_provider.Types.api_response option }
  | Output_block_state of { snapshot : Llm_provider.Types.content_block option }
  | Tool_invocation_state of
      { input : Llm_provider.Types.content_block option
      ; result : Llm_provider.Types.content_block option
      }
  | Tool_attempt_state

type node_view =
  { node : Event.node
  ; opened : Event.node event_record
  ; status : node_status
  ; updates : Event.node_update event_record list
  ; children : Event.node event_record list
  ; materialized : materialized
  ; through_seq : int
  }

type run_status =
  | Running
  | Finished of Event.terminal event_record

type run_view =
  { run : run
  ; opened : Event.node event_record
  ; parent_attempt : Event.Node_id.t option
  ; status : run_status
  ; through_seq : int
  }

type cursor = Store.cursor

let cursor_seq = Store.cursor_seq
let cursor_to_yojson = Store.cursor_to_yojson
let cursor_of_yojson = Store.cursor_of_yojson

type invariant_violation =
  | Sequence_mismatch of
      { expected : int
      ; actual : int
      }
  | Duplicate_event_id of Event.Event_id.t
  | Unknown_parent_event of Event.Event_id.t
  | Unknown_cause_event of Event.Event_id.t
  | Correlation_mismatch of
      { expected : Event.Correlation_id.t
      ; actual : Event.Correlation_id.t
      }
  | Event_run_mismatch of
      { envelope_run_id : Event.Run_id.t
      ; payload_run_id : Event.Run_id.t
      }
  | Duplicate_node_id of Event.Node_id.t
  | Unknown_node of Event.Node_id.t
  | Duplicate_run_id of Event.Run_id.t
  | Unknown_run of Event.Run_id.t
  | Run_already_finished of Event.Run_id.t
  | Node_already_closed of Event.Node_id.t
  | Parent_required of Event.Node_id.t
  | Unknown_parent_node of Event.Node_id.t
  | Parent_node_closed of Event.Node_id.t
  | Cross_run_parent of
      { node_run_id : Event.Run_id.t
      ; parent_run_id : Event.Run_id.t
      }
  | Invalid_parent_kind of
      { parent : Event.Node_id.t
      ; child : Event.Node_id.t
      }
  | Child_run_parent_not_tool_attempt of Event.Node_id.t
  | Root_parent_event_mismatch
  | Parent_event_mismatch of
      { expected : Event.Event_id.t
      ; actual : Event.Event_id.t option
      }
  | Invalid_update_for_node of Event.Node_id.t
  | Provider_response_already_materialized of Event.Node_id.t
  | Output_snapshot_already_materialized of Event.Node_id.t
  | Output_snapshot_kind_mismatch of
      { node : Event.Node_id.t
      ; expected : Event.output_block_kind
      ; actual : Event.content_block_classification
      }
  | Output_delta_after_snapshot of Event.Node_id.t
  | Output_snapshot_not_materialized of Event.Node_id.t
  | Tool_input_already_materialized of Event.Node_id.t
  | Tool_input_snapshot_not_tool_use of Event.Node_id.t
  | Tool_input_snapshot_identity_mismatch of Event.Node_id.t
  | Tool_input_delta_after_snapshot of Event.Node_id.t
  | Tool_input_not_materialized of Event.Node_id.t
  | Tool_invocation_requires_atomic_open
  | Occurrence_already_opened of Event.Node_id.t
  | Tool_occurrence_conflict of
      { parent : Event.Node_id.t
      ; planned_index : int
      ; existing : Event.Node_id.t
      }
  | Tool_result_already_materialized of Event.Node_id.t
  | Tool_result_snapshot_not_tool_result of Event.Node_id.t
  | Tool_result_snapshot_identity_mismatch of Event.Node_id.t
  | Tool_result_while_children_open of Event.Node_id.t
  | Tool_result_not_materialized of Event.Node_id.t
  | Child_after_tool_result of Event.Node_id.t
  | Node_has_open_children of Event.Node_id.t
  | Run_has_open_nodes of Event.Run_id.t
  | Root_must_use_finish_run of Event.Node_id.t
  | Agent_run_must_use_start_run
  | Top_level_run_already_exists
[@@deriving show]

type error =
  | Invalid_argument of string
  | Invalid_event of string
  | Identity_failure of string
  | Empty_batch
  | Durable_batch_owner_mismatch
  | Direct_mutation_forbidden
  | Durable_writer_owner_mismatch
  | Durable_store_unavailable
  | Durable_construction_cleanup_failed of
      { construction_error : error
      ; cleanup_error : Store.error
      }
  | Reconciliation_scope_mismatch
  | Reconciliation_correlation_mismatch
  | Reconciliation_content_conflict of
      { first_seq : int
      ; last_seq : int
      }
  | Reconciliation_conflict of
      { base_seq : int
      ; final_seq : int
      ; current_seq : int
      }
  | Reconciliation_store_diverged of
      { first_seq : int
      ; last_seq : int
      }
  | Projection_index_diverged of
      { expected_seq : int
      ; high_watermark : int
      }
  | Stale_batch of
      { expected_last_seq : int
      ; actual_last_seq : int
      }
  | Cursor_scope_mismatch
  | Cursor_ahead of
      { after_seq : int
      ; last_seq : int
      }
  | Persistence_failure of Store.error
  | Invariant_violation of invariant_violation

let rec error_to_string = function
  | Invalid_argument detail -> "invalid execution journal argument: " ^ detail
  | Invalid_event detail -> "invalid execution event: " ^ detail
  | Identity_failure detail -> "execution journal identity allocation failed: " ^ detail
  | Empty_batch -> "execution journal batch contains no semantic mutations"
  | Durable_batch_owner_mismatch ->
    "execution journal durable capability does not own the staged batch"
  | Direct_mutation_forbidden ->
    "execution journal direct mutation is forbidden after durable writer claim"
  | Durable_writer_owner_mismatch ->
    "execution journal durable writer claim does not own this journal"
  | Durable_store_unavailable ->
    "execution journal durable writer has no persistent store"
  | Durable_construction_cleanup_failed { construction_error; cleanup_error } ->
    "execution journal durable construction failed with "
    ^ error_to_string construction_error
    ^ "; unpublished store cleanup also failed: "
    ^ Store.error_to_string cleanup_error
  | Reconciliation_scope_mismatch ->
    "execution journal batch reconciliation scope does not match"
  | Reconciliation_correlation_mismatch ->
    "execution journal batch reconciliation correlation does not match"
  | Reconciliation_content_conflict { first_seq; last_seq } ->
    Printf.sprintf
      "execution journal batch reconciliation content differs at sequence range %d..%d"
      first_seq
      last_seq
  | Reconciliation_conflict { base_seq; final_seq; current_seq } ->
    Printf.sprintf
      "execution journal batch reconciliation expected current sequence %d or %d but \
       found %d"
      base_seq
      final_seq
      current_seq
  | Reconciliation_store_diverged { first_seq; last_seq } ->
    Printf.sprintf
      "execution journal reducer contains sequence range %d..%d absent from its durable \
       store"
      first_seq
      last_seq
  | Projection_index_diverged { expected_seq; high_watermark } ->
    Printf.sprintf
      "execution journal projection index is missing sequence %d below high watermark %d"
      expected_seq
      high_watermark
  | Stale_batch { expected_last_seq; actual_last_seq } ->
    Printf.sprintf
      "execution journal batch base is stale: expected last sequence %d but found %d"
      expected_last_seq
      actual_last_seq
  | Cursor_scope_mismatch -> "execution journal cursor belongs to another scope"
  | Cursor_ahead { after_seq; last_seq } ->
    Printf.sprintf
      "execution journal cursor %d is ahead of last sequence %d"
      after_seq
      last_seq
  | Persistence_failure error ->
    "execution journal persistence failed: " ^ Store.error_to_string error
  | Invariant_violation violation -> show_invariant_violation violation
;;

type commit_error_disposition =
  | Reconcile_required
  | Final_failure

let commit_error_disposition = function
  | Persistence_failure (Store.Commit_outcome_unknown _) -> Reconcile_required
  | Invalid_argument _
  | Invalid_event _
  | Identity_failure _
  | Empty_batch
  | Durable_batch_owner_mismatch
  | Direct_mutation_forbidden
  | Durable_writer_owner_mismatch
  | Durable_store_unavailable
  | Durable_construction_cleanup_failed _
  | Reconciliation_scope_mismatch
  | Reconciliation_correlation_mismatch
  | Reconciliation_content_conflict _
  | Reconciliation_conflict _
  | Reconciliation_store_diverged _
  | Projection_index_diverged _
  | Stale_batch _
  | Cursor_scope_mismatch
  | Cursor_ahead _
  | Persistence_failure _
  | Invariant_violation _ -> Final_failure
;;

module Durable_read = struct
  module Scope_id = Store.Scope_id

  type unexpected_store_error =
    | Writer_already_active
    | Store_already_attached
    | Store_released
    | Store_release_forbidden
    | Resource_cleanup_failed
    | Construction_cleanup_failed
    | Store_already_exists
    | Correlation_mismatch
    | Sequence_conflict
    | Committed_content_conflict
    | Cursor_scope_mismatch
    | Cursor_ahead
    | Store_poisoned
    | Commit_outcome_unknown

  type storage_failure =
    | Invalid_store_argument of string
    | Store_identity_failure of string
    | Store_io_failure of
        { operation : string
        ; detail : string
        }
    | Store_codec_failure of string
    | Store_not_found
    | Store_initialization_incomplete
    | Store_initialization_conflict
    | Unsupported_store_version of
        { expected : int
        ; actual : int
        }
    | Corrupt_store of
        { offset : int64
        ; detail : string
        }
    | Commit_authority_identity_changed
    | Commit_authority_regressed of
        { previous_committed_offset : int64
        ; actual_committed_offset : int64
        ; previous_last_seq : int
        ; actual_last_seq : int
        }
    | Unexpected_store_failure of
        { kind : unexpected_store_error
        ; detail : string
        }

  type snapshot = Store.read_only_snapshot

  let unexpected_store_failure (kind : unexpected_store_error) error =
    Unexpected_store_failure { kind; detail = Store.error_to_string error }
  ;;

  let storage_failure (error : Store.error) : storage_failure =
    match error with
    | Store.Invalid_argument detail -> Invalid_store_argument detail
    | Store.Identity_failure detail -> Store_identity_failure detail
    | Store.Io_failure { operation; detail } -> Store_io_failure { operation; detail }
    | Store.Codec_failure failure ->
      Store_codec_failure (Execution_codec_executor.failure_to_string failure)
    | Store.Store_not_found -> Store_not_found
    | Store.Store_initialization_incomplete -> Store_initialization_incomplete
    | Store.Store_initialization_conflict -> Store_initialization_conflict
    | Store.Unsupported_store_version { expected; actual } ->
      Unsupported_store_version { expected; actual }
    | Store.Corrupt_store { offset; detail } -> Corrupt_store { offset; detail }
    | Store.Commit_authority_identity_changed -> Commit_authority_identity_changed
    | Store.Commit_authority_regressed
        { previous_committed_offset
        ; actual_committed_offset
        ; previous_last_seq
        ; actual_last_seq
        } ->
      Commit_authority_regressed
        { previous_committed_offset
        ; actual_committed_offset
        ; previous_last_seq
        ; actual_last_seq
        }
    | Store.Writer_already_active as error ->
      unexpected_store_failure Writer_already_active error
    | Store.Store_already_attached as error ->
      unexpected_store_failure Store_already_attached error
    | Store.Store_released as error -> unexpected_store_failure Store_released error
    | Store.Store_release_forbidden as error ->
      unexpected_store_failure Store_release_forbidden error
    | Store.Resource_cleanup_failed _ as error ->
      unexpected_store_failure Resource_cleanup_failed error
    | Store.Construction_cleanup_failed _ as error ->
      unexpected_store_failure Construction_cleanup_failed error
    | Store.Store_already_exists as error ->
      unexpected_store_failure Store_already_exists error
    | Store.Correlation_mismatch as error ->
      unexpected_store_failure Correlation_mismatch error
    | Store.Sequence_conflict _ as error ->
      unexpected_store_failure Sequence_conflict error
    | Store.Committed_content_conflict _ as error ->
      unexpected_store_failure Committed_content_conflict error
    | Store.Cursor_scope_mismatch as error ->
      unexpected_store_failure Cursor_scope_mismatch error
    | Store.Cursor_ahead _ as error -> unexpected_store_failure Cursor_ahead error
    | Store.Store_poisoned _ as error -> unexpected_store_failure Store_poisoned error
    | Store.Commit_outcome_unknown _ as error ->
      unexpected_store_failure Commit_outcome_unknown error
  ;;

  let read_snapshot ~codec ~dir ?previous () =
    Store.read_only_snapshot ~codec ~dir ?previous () |> Result.map_error storage_failure
  ;;

  let same_snapshot left right = left == right
  let scope_id (snapshot : snapshot) = snapshot.scope_id
  let committed_offset (snapshot : snapshot) = snapshot.committed_offset
  let last_seq (snapshot : snapshot) = snapshot.last_seq
  let appended_events (snapshot : snapshot) = snapshot.appended_events
end

module Reducer = struct
  type node_record =
    { node : Event.node
    ; opened : Event.node event_record
    ; status : node_status
    ; last_event_id : Event.Event_id.t
    ; open_children : Node_id_set.t
    ; children_rev : Event.node event_record list
    ; occurrences : Event.Node_id.t Occurrence_map.t
    ; updates_rev : Event.node_update event_record list
    ; provider_response : Llm_provider.Types.api_response option
    ; output_snapshot : Llm_provider.Types.content_block option
    ; tool_input : Llm_provider.Types.content_block option
    ; tool_result : Llm_provider.Types.content_block option
    }

  type run_record =
    { view : run_view
    ; open_nodes : Node_id_set.t
    }

  type t =
    { last_seq : int
    ; correlation_id : Event.Correlation_id.t option
    ; event_ids : Event_id_set.t
    ; nodes : node_record Node_id_map.t
    ; runs : run_record Run_id_map.t
    }

  let empty =
    { last_seq = 0
    ; correlation_id = None
    ; event_ids = Event_id_set.empty
    ; nodes = Node_id_map.empty
    ; runs = Run_id_map.empty
    }
  ;;

  let last_seq state = state.last_seq
  let correlation_id state = state.correlation_id
  let find_node_record state node_id = Node_id_map.find_opt node_id state.nodes

  let materialized (record : node_record) =
    match Event.node_kind record.node with
    | Event.Agent_run _ -> Agent_run_state
    | Event.Agent_turn _ -> Agent_turn_state
    | Event.Provider_attempt _ ->
      Provider_attempt_state { response = record.provider_response }
    | Event.Output_block _ -> Output_block_state { snapshot = record.output_snapshot }
    | Event.Tool_invocation _ ->
      Tool_invocation_state { input = record.tool_input; result = record.tool_result }
    | Event.Tool_attempt -> Tool_attempt_state
  ;;

  let node_view_from_histories state (record : node_record) ~updates ~children =
    { node = record.node
    ; opened = record.opened
    ; status = record.status
    ; updates
    ; children
    ; materialized = materialized record
    ; through_seq = state.last_seq
    }
  ;;

  let find_node state node_id =
    Option.map
      (fun record ->
         node_view_from_histories
           state
           record
           ~updates:(List.rev record.updates_rev)
           ~children:(List.rev record.children_rev))
      (find_node_record state node_id)
  ;;

  let find_run_record state run_id = Run_id_map.find_opt run_id state.runs

  let find_run state run_id =
    Option.map
      (fun (record : run_record) -> { record.view with through_seq = state.last_seq })
      (find_run_record state run_id)
  ;;

  let latest_node_event state node_id =
    Option.map (fun record -> record.last_event_id) (find_node_record state node_id)
  ;;

  let open_subtree_postorder state root =
    let prepend_open_children (record : node_record) tail =
      let rec loop work = function
        | [] -> work
        | child :: rest ->
          let child_id = Event.node_id child.value in
          let work =
            if Node_id_set.mem child_id record.open_children
            then `Enter child_id :: work
            else work
          in
          Eio.Fiber.yield ();
          loop work rest
      in
      loop tail record.children_rev
    in
    let rec loop work reverse_postorder =
      match work with
      | [] -> Ok (reverse_cooperatively reverse_postorder)
      | `Exit node_id :: rest ->
        Eio.Fiber.yield ();
        loop rest (node_id :: reverse_postorder)
      | `Enter node_id :: rest ->
        (match find_node_record state node_id with
         | None -> Error (Unknown_node node_id)
         | Some record ->
           let work = prepend_open_children record (`Exit node_id :: rest) in
           Eio.Fiber.yield ();
           loop work reverse_postorder)
    in
    loop [ `Enter root ] []
  ;;

  let validate_event_references state event =
    match Event.parent_event_id event with
    | None -> Ok ()
    | Some event_id ->
      if Event_id_set.mem event_id state.event_ids
      then Ok ()
      else Error (Unknown_parent_event event_id)
  ;;

  let validate_event_causes state event =
    List.fold_left
      (fun result cause ->
         let* () = result in
         match cause with
         | Event.External_event _ -> Ok ()
         | Event.Internal_event event_id ->
           if Event_id_set.mem event_id state.event_ids
           then Ok ()
           else Error (Unknown_cause_event event_id))
      (Ok ())
      (Event.causes event)
  ;;

  let validate_correlation state event =
    let actual = Event.correlation_id event in
    match state.correlation_id with
    | None -> Ok ()
    | Some expected when Event.Correlation_id.equal expected actual -> Ok ()
    | Some expected -> Error (Correlation_mismatch { expected; actual })
  ;;

  let event_parent = Event.parent_event_id

  let validate_root_parent event =
    match event_parent event with
    | None -> Ok ()
    | Some _ -> Error Root_parent_event_mismatch
  ;;

  let validate_parent_event event expected =
    let actual = event_parent event in
    match actual with
    | Some actual when Event.Event_id.equal expected actual -> Ok ()
    | None | Some _ -> Error (Parent_event_mismatch { expected; actual })
  ;;

  let validate_event_run event payload_run_id =
    let envelope_run_id = Event.run_id event in
    if Event.Run_id.equal envelope_run_id payload_run_id
    then Ok ()
    else Error (Event_run_mismatch { envelope_run_id; payload_run_id })
  ;;

  let ensure_node_open node_id (record : node_record) =
    match record.status with
    | Open -> Ok ()
    | Closed _ -> Error (Node_already_closed node_id)
  ;;

  let ensure_run_running run_id (record : run_record) =
    match record.view.status with
    | Running -> Ok ()
    | Finished _ -> Error (Run_already_finished run_id)
  ;;

  let parent_accepts_child parent_kind child_kind =
    match parent_kind, child_kind with
    | Event.Agent_run _, Event.Agent_turn _ -> true
    | Event.Agent_turn _, Event.Provider_attempt _ -> true
    | Event.Provider_attempt _, (Event.Output_block _ | Event.Tool_invocation _) -> true
    | Event.Tool_invocation _, Event.Tool_attempt -> true
    | Event.Tool_attempt, Event.Tool_invocation _ -> true
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_invocation _
        | Event.Tool_attempt )
      , _ ) -> false
  ;;

  let occurrence parent_kind child_kind =
    match parent_kind, child_kind with
    | Event.Agent_run _, Event.Agent_turn { ordinal } ->
      Some (Occurrence.Agent_turn ordinal)
    | Event.Agent_turn _, Event.Provider_attempt { ordinal; target = _ } ->
      Some (Occurrence.Provider_attempt ordinal)
    | ( (Event.Provider_attempt _ | Event.Tool_attempt)
      , Event.Tool_invocation { schedule; _ } ) ->
      Some (Occurrence.Tool_invocation schedule.planned_index)
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_invocation _
        | Event.Tool_attempt )
      , _ ) -> None
  ;;

  let ensure_occurrence_available parent_id parent_record child_kind =
    let existing =
      Option.bind
        (occurrence (Event.node_kind parent_record.node) child_kind)
        (fun key -> Occurrence_map.find_opt key parent_record.occurrences)
    in
    match existing, child_kind with
    | None, _ -> Ok ()
    | Some existing, Event.Tool_invocation { schedule; _ } ->
      Error
        (Tool_occurrence_conflict
           { parent = parent_id; planned_index = schedule.planned_index; existing })
    | Some existing, _ -> Error (Occurrence_already_opened existing)
  ;;

  let validate_update (record : node_record) node_id update =
    match Event.node_kind record.node, update with
    | Event.Provider_attempt _, Event.Provider_event _ -> Ok ()
    | Event.Provider_attempt _, Event.Provider_response_snapshot _ ->
      if Option.is_some record.provider_response
      then Error (Provider_response_already_materialized node_id)
      else Ok ()
    | Event.Output_block _, Event.Output_delta _ ->
      if Option.is_some record.output_snapshot
      then Error (Output_delta_after_snapshot node_id)
      else Ok ()
    | Event.Output_block { block_kind = expected; _ }, Event.Output_snapshot block ->
      if Option.is_some record.output_snapshot
      then Error (Output_snapshot_already_materialized node_id)
      else (
        let actual = Event.classify_content_block block in
        match actual with
        | Event.Output_content actual when actual = expected -> Ok ()
        | Event.Output_content _ | Event.Tool_use_content | Event.Tool_result_content ->
          Error (Output_snapshot_kind_mismatch { node = node_id; expected; actual }))
    | Event.Tool_invocation _, Event.Tool_input_delta _ ->
      if Option.is_some record.tool_input
      then Error (Tool_input_delta_after_snapshot node_id)
      else Ok ()
    | ( Event.Tool_invocation { provider_tool_use_id; tool_name; _ }
      , Event.Tool_input_snapshot block ) ->
      if Option.is_some record.tool_input
      then Error (Tool_input_already_materialized node_id)
      else (
        match block with
        | Llm_provider.Types.ToolUse { id; name; _ }
          when String.equal name tool_name
               && Option.fold ~none:true ~some:(String.equal id) provider_tool_use_id ->
          Ok ()
        | Llm_provider.Types.ToolUse _ ->
          Error (Tool_input_snapshot_identity_mismatch node_id)
        | Llm_provider.Types.Text _
        | Llm_provider.Types.Thinking _
        | Llm_provider.Types.ReasoningDetails _
        | Llm_provider.Types.RedactedThinking _
        | Llm_provider.Types.ToolResult _
        | Llm_provider.Types.Image _
        | Llm_provider.Types.Document _
        | Llm_provider.Types.Audio _ -> Error (Tool_input_snapshot_not_tool_use node_id))
    | Event.Tool_invocation _, Event.Tool_result block ->
      if Option.is_none record.tool_input
      then Error (Tool_input_not_materialized node_id)
      else if Option.is_some record.tool_result
      then Error (Tool_result_already_materialized node_id)
      else if not (Node_id_set.is_empty record.open_children)
      then Error (Tool_result_while_children_open node_id)
      else (
        match block, record.tool_input with
        | ( Llm_provider.Types.ToolResult { tool_use_id; _ }
          , Some (Llm_provider.Types.ToolUse { id; _ }) )
          when String.equal tool_use_id id -> Ok ()
        | Llm_provider.Types.ToolResult _, Some (Llm_provider.Types.ToolUse _) ->
          Error (Tool_result_snapshot_identity_mismatch node_id)
        | Llm_provider.Types.ToolResult _, (None | Some _) ->
          Error (Tool_input_not_materialized node_id)
        | ( ( Llm_provider.Types.Text _
            | Llm_provider.Types.Thinking _
            | Llm_provider.Types.ReasoningDetails _
            | Llm_provider.Types.RedactedThinking _
            | Llm_provider.Types.ToolUse _
            | Llm_provider.Types.Image _
            | Llm_provider.Types.Document _
            | Llm_provider.Types.Audio _ )
          , _ ) -> Error (Tool_result_snapshot_not_tool_result node_id))
    | Event.Tool_attempt, Event.Tool_progress _ -> Ok ()
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_invocation _
        | Event.Tool_attempt )
      , _ ) -> Error (Invalid_update_for_node node_id)
  ;;

  let add_node state node event =
    let node_id = Event.node_id node in
    let opened = { event; value = node } in
    let record =
      { node
      ; opened
      ; status = Open
      ; last_event_id = Event.event_id event
      ; open_children = Node_id_set.empty
      ; children_rev = []
      ; occurrences = Occurrence_map.empty
      ; updates_rev = []
      ; provider_response = None
      ; output_snapshot = None
      ; tool_input = None
      ; tool_result = None
      }
    in
    let nodes = Node_id_map.add node_id record state.nodes in
    let* nodes =
      match Event.parent_node_id node with
      | None -> Ok nodes
      | Some parent_id ->
        (match Node_id_map.find_opt parent_id nodes with
         | None -> Error (Unknown_parent_node parent_id)
         | Some parent_record ->
           let occurrences =
             match
               occurrence (Event.node_kind parent_record.node) (Event.node_kind node)
             with
             | None -> parent_record.occurrences
             | Some key -> Occurrence_map.add key node_id parent_record.occurrences
           in
           let parent_record =
             { parent_record with
               open_children = Node_id_set.add node_id parent_record.open_children
             ; children_rev = opened :: parent_record.children_rev
             ; occurrences
             }
           in
           Ok (Node_id_map.add parent_id parent_record nodes))
    in
    Ok { state with nodes }
  ;;

  let open_agent_run state event node =
    let node_id = Event.node_id node in
    let run_id = Event.node_run_id node in
    if Run_id_map.mem run_id state.runs
    then Error (Duplicate_run_id run_id)
    else
      let* parent_attempt =
        match Event.parent_node_id node with
        | None ->
          let* () = validate_root_parent event in
          let+ () =
            if Run_id_map.is_empty state.runs
            then Ok ()
            else Error Top_level_run_already_exists
          in
          None
        | Some parent_id ->
          (match find_node_record state parent_id with
           | None -> Error (Unknown_parent_node parent_id)
           | Some parent_record ->
             let* () = ensure_node_open parent_id parent_record in
             (match Event.node_kind parent_record.node with
              | Event.Tool_attempt ->
                let+ () = validate_parent_event event parent_record.last_event_id in
                Some parent_id
              | _ -> Error (Child_run_parent_not_tool_attempt parent_id)))
      in
      let run = { id = run_id; root = node_id } in
      let run_record =
        { view =
            { run
            ; opened = { event; value = node }
            ; parent_attempt
            ; status = Running
            ; through_seq = 0
            }
        ; open_nodes = Node_id_set.singleton node_id
        }
      in
      let* state = add_node state node event in
      Ok { state with runs = Run_id_map.add run_id run_record state.runs }
  ;;

  let open_non_root state event node =
    let node_id = Event.node_id node in
    let run_id = Event.node_run_id node in
    let* run_record =
      match find_run_record state run_id with
      | None -> Error (Unknown_run run_id)
      | Some run_record -> Ok run_record
    in
    let* () = ensure_run_running run_id run_record in
    let* parent_id =
      match Event.parent_node_id node with
      | None -> Error (Parent_required node_id)
      | Some parent_id -> Ok parent_id
    in
    let* parent_record =
      match find_node_record state parent_id with
      | None -> Error (Unknown_parent_node parent_id)
      | Some parent_record -> Ok parent_record
    in
    let* () =
      match parent_record.status with
      | Open -> Ok ()
      | Closed _ -> Error (Parent_node_closed parent_id)
    in
    let parent_run_id = Event.node_run_id parent_record.node in
    let* () =
      if Event.Run_id.equal run_id parent_run_id
      then Ok ()
      else Error (Cross_run_parent { node_run_id = run_id; parent_run_id })
    in
    let* () =
      if parent_accepts_child (Event.node_kind parent_record.node) (Event.node_kind node)
      then Ok ()
      else Error (Invalid_parent_kind { parent = parent_id; child = node_id })
    in
    let* () =
      ensure_occurrence_available parent_id parent_record (Event.node_kind node)
    in
    let* () =
      (* Ordering fences per parent kind. The match is exhaustive on parent
         kind (parent_accepts_child already admitted the pair) so widening the
         accepted pairs forces a compile-time review of this fence. *)
      match Event.node_kind parent_record.node with
      | Event.Tool_invocation _ ->
        if Option.is_none parent_record.tool_input
        then Error (Tool_input_not_materialized parent_id)
        else if Option.is_some parent_record.tool_result
        then Error (Child_after_tool_result parent_id)
        else Ok ()
      | Event.Agent_run _
      | Event.Agent_turn _
      | Event.Provider_attempt _
      | Event.Output_block _
      | Event.Tool_attempt -> Ok ()
    in
    let* () = validate_parent_event event parent_record.last_event_id in
    let* state = add_node state node event in
    let run_record =
      { run_record with open_nodes = Node_id_set.add node_id run_record.open_nodes }
    in
    Ok { state with runs = Run_id_map.add run_id run_record state.runs }
  ;;

  let apply_open state event node =
    let node_id = Event.node_id node in
    let* () = validate_event_run event (Event.node_run_id node) in
    if Node_id_map.mem node_id state.nodes
    then Error (Duplicate_node_id node_id)
    else (
      match Event.node_kind node with
      | Event.Agent_run _ -> open_agent_run state event node
      | Event.Agent_turn _
      | Event.Provider_attempt _
      | Event.Output_block _
      | Event.Tool_invocation _
      | Event.Tool_attempt -> open_non_root state event node)
  ;;

  let apply_update state event node_id update =
    let* record =
      match find_node_record state node_id with
      | None -> Error (Unknown_node node_id)
      | Some record -> Ok record
    in
    let* () = ensure_node_open node_id record in
    let* () = validate_event_run event (Event.node_run_id record.node) in
    let* () = validate_parent_event event record.last_event_id in
    let* () = validate_update record node_id update in
    let updated =
      { record with
        last_event_id = Event.event_id event
      ; updates_rev = { event; value = update } :: record.updates_rev
      ; provider_response =
          (match update with
           | Event.Provider_response_snapshot value -> Some value
           | Event.Provider_event _
           | Event.Output_delta _
           | Event.Output_snapshot _
           | Event.Tool_input_delta _
           | Event.Tool_input_snapshot _
           | Event.Tool_progress _
           | Event.Tool_result _ -> record.provider_response)
      ; output_snapshot =
          (match update with
           | Event.Output_snapshot value -> Some value
           | Event.Provider_event _
           | Event.Provider_response_snapshot _
           | Event.Output_delta _
           | Event.Tool_input_delta _
           | Event.Tool_input_snapshot _
           | Event.Tool_progress _
           | Event.Tool_result _ -> record.output_snapshot)
      ; tool_input =
          (match update with
           | Event.Tool_input_snapshot value -> Some value
           | Event.Provider_event _
           | Event.Provider_response_snapshot _
           | Event.Output_delta _
           | Event.Output_snapshot _
           | Event.Tool_input_delta _
           | Event.Tool_progress _
           | Event.Tool_result _ -> record.tool_input)
      ; tool_result =
          (match update with
           | Event.Tool_result value -> Some value
           | Event.Provider_event _
           | Event.Provider_response_snapshot _
           | Event.Output_delta _
           | Event.Output_snapshot _
           | Event.Tool_input_delta _
           | Event.Tool_input_snapshot _
           | Event.Tool_progress _ -> record.tool_result)
      }
    in
    Ok { state with nodes = Node_id_map.add node_id updated state.nodes }
  ;;

  let detach_from_parent nodes node =
    match Event.parent_node_id node with
    | None -> Ok nodes
    | Some parent_id ->
      (match Node_id_map.find_opt parent_id nodes with
       | None -> Error (Unknown_parent_node parent_id)
       | Some parent_record ->
         let parent_record =
           { parent_record with
             open_children =
               Node_id_set.remove (Event.node_id node) parent_record.open_children
           }
         in
         Ok (Node_id_map.add parent_id parent_record nodes))
  ;;

  let apply_close state event node_id terminal =
    let* record =
      match find_node_record state node_id with
      | None -> Error (Unknown_node node_id)
      | Some record -> Ok record
    in
    let* () = ensure_node_open node_id record in
    let run_id = Event.node_run_id record.node in
    let* () = validate_event_run event run_id in
    let* () = validate_parent_event event record.last_event_id in
    let* () =
      if not (Node_id_set.is_empty record.open_children)
      then Error (Node_has_open_children node_id)
      else Ok ()
    in
    let* () =
      (* Materialization completeness per (node kind, terminal) pair. Both
         matches are exhaustive so adding a node kind or terminal forces a
         compile-time review of this gate. *)
      match Event.node_kind record.node with
      | Event.Tool_invocation _ ->
        (match terminal with
         | Event.Succeeded ->
           if Option.is_none record.tool_input
           then Error (Tool_input_not_materialized node_id)
           else if Option.is_none record.tool_result
           then Error (Tool_result_not_materialized node_id)
           else Ok ()
         | Event.Failed _ | Event.Cancelled _ -> Ok ())
      | Event.Output_block _ ->
        (match terminal with
         | Event.Succeeded ->
           if Option.is_none record.output_snapshot
           then Error (Output_snapshot_not_materialized node_id)
           else Ok ()
         | Event.Failed _ | Event.Cancelled _ -> Ok ())
      | Event.Agent_run _
      | Event.Agent_turn _
      | Event.Provider_attempt _
      | Event.Tool_attempt -> Ok ()
    in
    let closed_record =
      { node = record.node
      ; opened = record.opened
      ; status = Closed { event; value = terminal }
      ; last_event_id = Event.event_id event
      ; open_children = record.open_children
      ; children_rev = record.children_rev
      ; occurrences = record.occurrences
      ; updates_rev = record.updates_rev
      ; provider_response = record.provider_response
      ; output_snapshot = record.output_snapshot
      ; tool_input = record.tool_input
      ; tool_result = record.tool_result
      }
    in
    let* nodes =
      detach_from_parent (Node_id_map.add node_id closed_record state.nodes) record.node
    in
    match Event.node_kind record.node with
    | Event.Agent_run _ ->
      let* run_record =
        match find_run_record state run_id with
        | None -> Error (Unknown_run run_id)
        | Some run_record -> Ok run_record
      in
      let* () = ensure_run_running run_id run_record in
      let* () =
        if Event.Node_id.equal run_record.view.run.root node_id
        then Ok ()
        else Error Agent_run_must_use_start_run
      in
      let* () =
        if
          not
            (Node_id_set.equal
               run_record.open_nodes
               (Node_id_set.singleton run_record.view.run.root))
        then Error (Run_has_open_nodes run_id)
        else Ok ()
      in
      let finished_run =
        { view = { run_record.view with status = Finished { event; value = terminal } }
        ; open_nodes = Node_id_set.empty
        }
      in
      Ok { state with nodes; runs = Run_id_map.add run_id finished_run state.runs }
    | Event.Agent_turn _
    | Event.Provider_attempt _
    | Event.Output_block _
    | Event.Tool_invocation _
    | Event.Tool_attempt ->
      let* run_record =
        match find_run_record state run_id with
        | None -> Error (Unknown_run run_id)
        | Some run_record -> Ok run_record
      in
      let run_record =
        { run_record with open_nodes = Node_id_set.remove node_id run_record.open_nodes }
      in
      Ok { state with nodes; runs = Run_id_map.add run_id run_record state.runs }
  ;;

  let apply_payload state event =
    match Event.payload event with
    | Event.Node_opened node -> apply_open state event node
    | Event.Node_updated { node_id; update } -> apply_update state event node_id update
    | Event.Node_closed { node_id; terminal } -> apply_close state event node_id terminal
  ;;

  let apply state event =
    let expected = state.last_seq + 1 in
    let actual = Event.seq event in
    if actual <> expected
    then Error (Sequence_mismatch { expected; actual })
    else (
      let event_id = Event.event_id event in
      if Event_id_set.mem event_id state.event_ids
      then Error (Duplicate_event_id event_id)
      else
        let* () = validate_correlation state event in
        let* () = validate_event_references state event in
        let* () = validate_event_causes state event in
        let* state = apply_payload state event in
        let correlation_id =
          match state.correlation_id with
          | Some _ as correlation_id -> correlation_id
          | None -> Some (Event.correlation_id event)
        in
        Ok
          { state with
            last_seq = actual
          ; correlation_id
          ; event_ids = Event_id_set.add event_id state.event_ids
          })
  ;;
end

module Event_seq_map = Map.Make (Int)

type journal_state =
  { reducer : Reducer.t
  ; events_rev : Event.t list
  ; events_by_seq : Event.t Event_seq_map.t
  }

type snapshot =
  { scope_id : Store.Scope_id.t
  ; reducer : Reducer.t
  }

type writer_authority =
  | Unclaimed_writer
  | Direct_writer
  | Claimed_durable_writer of unit ref

type t =
  { scope_id : Store.Scope_id.t
  ; correlation_id : Event.Correlation_id.t
  ; store_writer : Store.writer option
  ; writer_gate : Eio.Mutex.t
  ; mu : Eio.Mutex.t
  ; mutable writer_authority : writer_authority
  ; mutable state : journal_state
  }

type durable_writer =
  { journal : t
  ; claim : unit ref
  }

let with_read journal f = Eio.Mutex.use_ro journal.mu (fun () -> f journal.state)
let with_state_write journal f = Eio.Mutex.use_rw ~protect:true journal.mu f
let with_writer_gate journal f = Eio.Mutex.use_ro journal.writer_gate f

let claim_direct_writer_locked journal =
  match journal.writer_authority with
  | Unclaimed_writer ->
    journal.writer_authority <- Direct_writer;
    Ok ()
  | Direct_writer -> Ok ()
  | Claimed_durable_writer _ -> Error Direct_mutation_forbidden
;;

let ensure_direct_writer_allowed_locked journal =
  match journal.writer_authority with
  | Unclaimed_writer | Direct_writer -> Ok ()
  | Claimed_durable_writer _ -> Error Direct_mutation_forbidden
;;

let validate_durable_writer_locked (writer : durable_writer) =
  match writer.journal.writer_authority with
  | Claimed_durable_writer claim when claim == writer.claim -> Ok ()
  | Unclaimed_writer | Direct_writer | Claimed_durable_writer _ ->
    Error Durable_writer_owner_mismatch
;;

let length journal = with_read journal (fun state -> Reducer.last_seq state.reducer)
let last_seq journal = with_read journal (fun state -> Reducer.last_seq state.reducer)

let events journal =
  let events_rev = with_read journal (fun state -> state.events_rev) in
  reverse_cooperatively events_rev
;;

let make_cursor scope_id seq =
  match Store.make_cursor ~scope_id ~seq with
  | Ok cursor -> cursor
  | Error detail -> invalid_arg detail
;;

let beginning_cursor journal = make_cursor journal.scope_id 0

let current_cursor journal =
  let seq = last_seq journal in
  make_cursor journal.scope_id seq
;;

type page =
  { events : Event.t list
  ; next_cursor : cursor
  ; high_watermark : cursor
  ; has_more : bool
  }

let read_page journal ~after ?through ~limit () =
  if limit <= 0
  then Error (Invalid_argument "page limit must be positive")
  else if not (Store.Scope_id.equal (Store.cursor_scope_id after) journal.scope_id)
  then Error Cursor_scope_mismatch
  else if
    match through with
    | Some through ->
      not (Store.Scope_id.equal (Store.cursor_scope_id through) journal.scope_id)
    | None -> false
  then Error Cursor_scope_mismatch
  else (
    let state = with_read journal Fun.id in
    let current_seq = Reducer.last_seq state.reducer in
    let after_seq = Store.cursor_seq after in
    let high_watermark = Option.fold ~none:current_seq ~some:Store.cursor_seq through in
    if high_watermark > current_seq
    then Error (Cursor_ahead { after_seq = high_watermark; last_seq = current_seq })
    else if after_seq > high_watermark
    then Error (Cursor_ahead { after_seq; last_seq = high_watermark })
    else (
      let page_event_count = min limit (high_watermark - after_seq) in
      let page_last_seq = after_seq + page_event_count in
      let rec collect seq events_rev =
        if seq > page_last_seq
        then Ok (reverse_cooperatively events_rev)
        else (
          match Event_seq_map.find_opt seq state.events_by_seq with
          | None ->
            Error (Projection_index_diverged { expected_seq = seq; high_watermark })
          | Some event ->
            Eio.Fiber.yield ();
            collect (seq + 1) (event :: events_rev))
      in
      let+ events = collect (after_seq + 1) [] in
      { events
      ; next_cursor = make_cursor journal.scope_id page_last_seq
      ; high_watermark = make_cursor journal.scope_id high_watermark
      ; has_more = page_last_seq < high_watermark
      }))
;;

let snapshot journal =
  let reducer = with_read journal (fun state -> state.reducer) in
  { scope_id = journal.scope_id; reducer }
;;

let snapshot_cursor (snapshot : snapshot) =
  make_cursor snapshot.scope_id (Reducer.last_seq snapshot.reducer)
;;

let snapshot_find_node (snapshot : snapshot) node_id =
  match Reducer.find_node_record snapshot.reducer node_id with
  | None -> None
  | Some record ->
    let updates = reverse_cooperatively record.updates_rev in
    let children = reverse_cooperatively record.children_rev in
    Some (Reducer.node_view_from_histories snapshot.reducer record ~updates ~children)
;;

let snapshot_find_run (snapshot : snapshot) run_id =
  Reducer.find_run snapshot.reducer run_id
;;

let find_node journal node_id = snapshot_find_node (snapshot journal) node_id
let find_run journal run_id = snapshot_find_run (snapshot journal) run_id

let identity_result = function
  | Ok value -> Ok value
  | Error detail -> Error (Identity_failure detail)
;;

let payload_result = function
  | Ok payload -> Ok payload
  | Error detail -> Error (Invalid_event detail)
;;

let append_to_state
      (state : journal_state)
      ~event_id
      ~correlation_id
      ~run_id
      ~parent_event_id
      ?(causes = [])
      payload
  =
  let parent_event_string = Option.map Event.Event_id.to_string parent_event_id in
  let envelope =
    Event_envelope.make
      ~event_id:(Event.Event_id.to_string event_id)
      ~correlation_id:(Event.Correlation_id.to_string correlation_id)
      ~run_id:(Event.Run_id.to_string run_id)
      ~seq:(Reducer.last_seq state.reducer + 1)
      ?parent_event_id:parent_event_string
      ~source_clock:Event_envelope.Wall
      ()
  in
  let* event =
    match Event.make_validated ~causes ~envelope payload with
    | Ok event -> Ok event
    | Error detail -> Error (Invalid_event detail)
  in
  let* reducer =
    match Reducer.apply state.reducer event with
    | Ok reducer -> Ok reducer
    | Error violation -> Error (Invariant_violation violation)
  in
  Ok
    ( { reducer
      ; events_rev = event :: state.events_rev
      ; events_by_seq = Event_seq_map.add (Event.seq event) event state.events_by_seq
      }
    , event )
;;

type 'a mutation =
  { next_state : journal_state
  ; events : Event.t list
  ; value : 'a
  }

let append_one
      journal
      (state : journal_state)
      ~event_id
      ~run_id
      ~parent_event_id
      ?causes
      payload
  =
  let+ next_state, event =
    append_to_state
      state
      ~event_id
      ~correlation_id:journal.correlation_id
      ~run_id
      ~parent_event_id
      ?causes
      payload
  in
  { next_state; events = [ event ]; value = event }
;;

type persistence =
  | Volatile
  | Durable

let persist_mutation journal (captured_state : journal_state) events =
  match journal.store_writer with
  | None -> Ok Volatile
  | Some store_writer ->
    let expected_next_seq = Reducer.last_seq captured_state.reducer + 1 in
    (match Store.append_batch store_writer ~expected_next_seq events with
     | Ok (Store.Stored | Store.Already_committed) -> Ok Durable
     | Error error -> Error (Persistence_failure error))
;;

let commit_mutation journal (captured_state : journal_state) mutation =
  let* persistence = persist_mutation journal captured_state mutation.events in
  let publish () =
    with_state_write journal (fun () ->
      if not (journal.state == captured_state)
      then Error (Invalid_event "execution writer gate invariant violated")
      else (
        journal.state <- mutation.next_state;
        Ok mutation.value))
  in
  match persistence with
  | Volatile ->
    Eio.Fiber.check ();
    publish ()
  | Durable ->
    (* The batch is already durable, and waiting on journal.mu is itself a
       cancellation point. A cancellation firing there would leave the handle
       permanently behind its own store: every later direct write stages the
       already-committed sequence again and fails compare_committed. Mirror
       the store's publication region and protect the acquisition too. *)
    Eio.Cancel.protect publish
;;

let with_write journal f =
  with_writer_gate journal (fun () ->
    let* () = ensure_direct_writer_allowed_locked journal in
    let captured_state = with_read journal Fun.id in
    let* mutation = f captured_state in
    let* () = claim_direct_writer_locked journal in
    commit_mutation journal captured_state mutation)
;;

let node_record_or_error (state : journal_state) node_id =
  match Reducer.find_node_record state.reducer node_id with
  | None -> Error (Invariant_violation (Unknown_node node_id))
  | Some record -> Ok record
;;

let node_last_event (state : journal_state) node_id =
  match Reducer.latest_node_event state.reducer node_id with
  | None -> Error (Invariant_violation (Unknown_node node_id))
  | Some event_id -> Ok event_id
;;

let stage_start_run ?parent_attempt ?causes journal state ~agent_name =
  let* run_id = identity_result (Event.Run_id.fresh ()) in
  let* root = identity_result (Event.Node_id.fresh ()) in
  let* event_id = identity_result (Event.Event_id.fresh ()) in
  let* node =
    match
      Event.make_node
        ~node_id:root
        ~run_id
        ~parent_node_id:parent_attempt
        ~kind:(Event.Agent_run { agent_name })
    with
    | Ok node -> Ok node
    | Error detail -> Error (Invalid_argument detail)
  in
  let* payload = payload_result (Event.validate_payload (Event.Node_opened node)) in
  let* parent_event_id =
    match parent_attempt with
    | None -> Ok None
    | Some node_id ->
      let+ event_id = node_last_event state node_id in
      Some event_id
  in
  let+ mutation =
    append_one journal state ~event_id ~run_id ~parent_event_id ?causes payload
  in
  { next_state = mutation.next_state
  ; events = mutation.events
  ; value = { id = run_id; root }, mutation.value
  }
;;

let validate_run_handle (state : journal_state) run =
  match Reducer.find_run state.reducer run.id with
  | None -> Error (Invariant_violation (Unknown_run run.id))
  | Some view when not (equal_run view.run run) ->
    Error (Invalid_argument "run handle does not match the journal run root")
  | Some { status = Finished _; _ } ->
    Error (Invariant_violation (Run_already_finished run.id))
  | Some { status = Running; _ } -> Ok ()
;;

let stage_open_node ?causes journal state ~run ~parent ~kind =
  match kind with
  | Event.Agent_run _ -> Error (Invariant_violation Agent_run_must_use_start_run)
  | Event.Agent_turn _
  | Event.Provider_attempt _
  | Event.Output_block _
  | Event.Tool_invocation _
  | Event.Tool_attempt ->
    let* node_id = identity_result (Event.Node_id.fresh ()) in
    let* event_id = identity_result (Event.Event_id.fresh ()) in
    let* node =
      match
        Event.make_node ~node_id ~run_id:run.id ~parent_node_id:(Some parent) ~kind
      with
      | Ok node -> Ok node
      | Error detail -> Error (Invalid_argument detail)
    in
    let* payload = payload_result (Event.validate_payload (Event.Node_opened node)) in
    let* () = validate_run_handle state run in
    let* parent_event_id = node_last_event state parent in
    let+ mutation =
      append_one
        journal
        state
        ~event_id
        ~run_id:run.id
        ~parent_event_id:(Some parent_event_id)
        ?causes
        payload
    in
    { next_state = mutation.next_state
    ; events = mutation.events
    ; value = node_id, mutation.value
    }
;;

let stage_update_node ?causes journal state ~node update =
  let* event_id = identity_result (Event.Event_id.fresh ()) in
  let* payload =
    payload_result
      (Event.validate_payload (Event.Node_updated { node_id = node; update }))
  in
  let* view = node_record_or_error state node in
  let* parent_event_id = node_last_event state node in
  append_one
    journal
    state
    ~event_id
    ~run_id:(Event.node_run_id view.node)
    ~parent_event_id:(Some parent_event_id)
    ?causes
    payload
;;

let stage_close_node ?causes journal state ~node terminal =
  let* event_id = identity_result (Event.Event_id.fresh ()) in
  let* terminal = payload_result (Event.validate_terminal terminal) in
  let payload = Event.close_payload ~node_id:node terminal in
  let* view = node_record_or_error state node in
  match Event.node_kind view.node with
  | Event.Agent_run _ -> Error (Invariant_violation (Root_must_use_finish_run node))
  | Event.Agent_turn _
  | Event.Provider_attempt _
  | Event.Output_block _
  | Event.Tool_invocation _
  | Event.Tool_attempt ->
    let* parent_event_id = node_last_event state node in
    append_one
      journal
      state
      ~event_id
      ~run_id:(Event.node_run_id view.node)
      ~parent_event_id:(Some parent_event_id)
      ?causes
      payload
;;

let stage_begin_tool_attempt journal state ~invocation =
  let* invocation_record = node_record_or_error state invocation in
  let* run =
    match Event.node_kind invocation_record.node, invocation_record.children_rev with
    | Event.Tool_invocation _, [] ->
      let run_id = Event.node_run_id invocation_record.node in
      (match Reducer.find_run state.reducer run_id with
       | Some { run; status = Running; _ } -> Ok run
       | Some { status = Finished _; _ } ->
         Error (Invariant_violation (Run_already_finished run_id))
       | None -> Error (Invariant_violation (Unknown_run run_id)))
    | Event.Tool_invocation _, _ :: _ ->
      Error (Invalid_argument "tool invocation already has an attempt")
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_attempt )
      , _ ) -> Error (Invalid_argument "tool attempt requires a Tool_invocation node")
  in
  stage_open_node journal state ~run ~parent:invocation ~kind:Event.Tool_attempt
;;

let stage_open_tool_invocation
      journal
      state
      ~run
      ~provider_attempt
      ~invocation
      ~tool_name
      ~input
  =
  let* provider_record = node_record_or_error state provider_attempt in
  let* () =
    match
      Event.node_kind provider_record.node, Event.parent_node_id provider_record.node
    with
    | Event.Provider_attempt _, Some turn_node ->
      let* turn_record = node_record_or_error state turn_node in
      (match Event.node_kind turn_record.node with
       | Event.Agent_turn { ordinal }
         when ordinal = Tool_contract.Invocation.turn invocation -> Ok ()
       | Event.Agent_turn _ ->
         Error
           (Invalid_argument "tool invocation turn does not match its provider attempt")
       | Event.Agent_run _
       | Event.Provider_attempt _
       | Event.Output_block _
       | Event.Tool_invocation _
       | Event.Tool_attempt ->
         Error
           (Invalid_argument
              "tool invocation requires a provider attempt under an agent turn"))
    | Event.Provider_attempt _, None ->
      Error
        (Invalid_argument
           "tool invocation requires a provider attempt under an agent turn")
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Output_block _
        | Event.Tool_invocation _
        | Event.Tool_attempt )
      , _ ) -> Error (Invalid_argument "tool invocation requires a provider attempt")
  in
  let tool_use_id = Tool_contract.Invocation.tool_use_id invocation in
  let planned_index = Tool_contract.Invocation.planned_index invocation in
  let* () =
    match
      Occurrence_map.find_opt
        (Occurrence.Tool_invocation planned_index)
        provider_record.occurrences
    with
    | None -> Ok ()
    | Some existing ->
      let* existing_record = node_record_or_error state existing in
      let exact_duplicate =
        match Event.node_kind existing_record.node, existing_record.tool_input with
        | ( Event.Tool_invocation
              { provider_tool_use_id; tool_name = existing_name; schedule; completion }
          , Some
              (Llm_provider.Types.ToolUse
                 { id = existing_id; name = input_name; input = existing_input }) ) ->
          Option.equal String.equal provider_tool_use_id (Some tool_use_id)
          && String.equal existing_name tool_name
          && Execution_tool_schedule.equal
               schedule
               (Tool_contract.Invocation.schedule invocation)
          && completion = Tool_contract.Invocation.completion invocation
          && String.equal existing_id tool_use_id
          && String.equal input_name tool_name
          && Yojson.Safe.equal existing_input input
        | ( ( Event.Agent_run _
            | Event.Agent_turn _
            | Event.Provider_attempt _
            | Event.Output_block _
            | Event.Tool_attempt )
          , _ )
        | Event.Tool_invocation _, (None | Some _) -> false
      in
      if exact_duplicate
      then Error (Invariant_violation (Occurrence_already_opened existing))
      else
        Error
          (Invariant_violation
             (Tool_occurrence_conflict
                { parent = provider_attempt; planned_index; existing }))
  in
  let* opened =
    stage_open_node
      journal
      state
      ~run
      ~parent:provider_attempt
      ~kind:
        (Event.Tool_invocation
           { provider_tool_use_id = Some tool_use_id
           ; tool_name
           ; schedule = Tool_contract.Invocation.schedule invocation
           ; completion = Tool_contract.Invocation.completion invocation
           })
  in
  let tool_use =
    Llm_provider.Types.ToolUse { id = tool_use_id; name = tool_name; input }
  in
  let+ materialized =
    stage_update_node
      journal
      opened.next_state
      ~node:(fst opened.value)
      (Event.Tool_input_snapshot tool_use)
  in
  let node, opened_event = opened.value in
  { next_state = materialized.next_state
  ; events = [ opened_event; materialized.value ]
  ; value = node, [ opened_event; materialized.value ]
  }
;;

let stage_settle_tool_attempt journal state ~attempt ~invocation ~result =
  let* attempt_record = node_record_or_error state attempt in
  let* () =
    match
      Event.node_kind attempt_record.node, Event.parent_node_id attempt_record.node
    with
    | Event.Tool_attempt, Some parent when Event.Node_id.equal parent invocation -> Ok ()
    | Event.Tool_attempt, (None | Some _) ->
      Error (Invalid_argument "tool attempt does not belong to the invocation")
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_invocation _ )
      , _ ) -> Error (Invalid_argument "tool settlement requires a Tool_attempt node")
  in
  let* invocation_record = node_record_or_error state invocation in
  let* () =
    match Event.node_kind invocation_record.node with
    | Event.Tool_invocation _ -> Ok ()
    | Event.Agent_run _
    | Event.Agent_turn _
    | Event.Provider_attempt _
    | Event.Output_block _
    | Event.Tool_attempt ->
      Error (Invalid_argument "tool settlement requires a Tool_invocation node")
  in
  let* attempt_closed = stage_close_node journal state ~node:attempt Event.Succeeded in
  let* result_committed =
    stage_update_node
      journal
      attempt_closed.next_state
      ~node:invocation
      (Event.Tool_result result)
  in
  let+ invocation_closed =
    stage_close_node journal result_committed.next_state ~node:invocation Event.Succeeded
  in
  { next_state = invocation_closed.next_state
  ; events = [ attempt_closed.value; result_committed.value; invocation_closed.value ]
  ; value = [ attempt_closed.value; result_committed.value; invocation_closed.value ]
  }
;;

let stage_settle_unattempted_tool_invocation journal state ~invocation ~result =
  let* invocation_record = node_record_or_error state invocation in
  let* () =
    match
      ( Event.node_kind invocation_record.node
      , invocation_record.tool_result
      , invocation_record.children_rev
      , invocation_record.status )
    with
    | Event.Tool_invocation _, None, [], Open -> Ok ()
    | Event.Tool_invocation _, (None | Some _), (_ :: _ | []), (Open | Closed _) ->
      Error
        (Invalid_argument
           "blocked settlement requires an open, unattempted tool invocation")
    | ( ( Event.Agent_run _
        | Event.Agent_turn _
        | Event.Provider_attempt _
        | Event.Output_block _
        | Event.Tool_attempt )
      , (None | Some _)
      , (_ :: _ | [])
      , (Open | Closed _) ) ->
      Error (Invalid_argument "blocked settlement requires a Tool_invocation node")
  in
  let* result_committed =
    stage_update_node journal state ~node:invocation (Event.Tool_result result)
  in
  let+ invocation_closed =
    stage_close_node journal result_committed.next_state ~node:invocation Event.Succeeded
  in
  { next_state = invocation_closed.next_state
  ; events = [ result_committed.value; invocation_closed.value ]
  ; value = [ result_committed.value; invocation_closed.value ]
  }
;;

let stage_finish_run ?causes journal state ~run terminal =
  let* event_id = identity_result (Event.Event_id.fresh ()) in
  let* terminal = payload_result (Event.validate_terminal terminal) in
  let payload = Event.close_payload ~node_id:run.root terminal in
  let* () = validate_run_handle state run in
  let* parent_event_id = node_last_event state run.root in
  append_one
    journal
    state
    ~event_id
    ~run_id:run.id
    ~parent_event_id:(Some parent_event_id)
    ?causes
    payload
;;

let stage_abort_run ?causes journal captured_state ~run terminal =
  match terminal with
  | Event.Succeeded ->
    Error (Invalid_argument "abort_run requires a failed or cancelled terminal")
  | Event.Failed _ | Event.Cancelled _ ->
    let* terminal = payload_result (Event.validate_terminal terminal) in
    let* () = validate_run_handle captured_state run in
    let* order =
      match Reducer.open_subtree_postorder captured_state.reducer run.root with
      | Ok order -> Ok order
      | Error violation -> Error (Invariant_violation violation)
    in
    let rec apply_closes state events_rev closed_by_node = function
      | [] -> Ok (state, events_rev)
      | node_id :: nodes ->
        let* event_id = identity_result (Event.Event_id.fresh ()) in
        let* record = node_record_or_error state node_id in
        let* parent_event_id = node_last_event state node_id in
        let payload = Event.close_payload ~node_id terminal in
        let child_causes =
          reverse_filter_map_cooperatively
            (fun (child : Event.node event_record) ->
               let child_id = Event.node_id child.value in
               Option.map
                 (fun event -> Event.Internal_event (Event.event_id event))
                 (Node_id_map.find_opt child_id closed_by_node))
            record.children_rev
        in
        let event_causes =
          append_cooperatively (Option.value causes ~default:[]) child_causes
        in
        let* next_state, event =
          append_to_state
            state
            ~event_id
            ~correlation_id:journal.correlation_id
            ~run_id:(Event.node_run_id record.node)
            ~parent_event_id:(Some parent_event_id)
            ~causes:event_causes
            payload
        in
        Eio.Fiber.yield ();
        apply_closes
          next_state
          (event :: events_rev)
          (Node_id_map.add node_id event closed_by_node)
          nodes
    in
    let+ next_state, events_rev =
      apply_closes captured_state [] Node_id_map.empty order
    in
    let events = reverse_cooperatively events_rev in
    { next_state; events; value = events }
;;

let start_run ?parent_attempt ?causes journal ~agent_name =
  with_write journal (fun state ->
    stage_start_run ?parent_attempt ?causes journal state ~agent_name)
;;

let open_node ?causes journal ~run ~parent ~kind =
  with_write journal (fun state ->
    stage_open_node ?causes journal state ~run ~parent ~kind)
;;

let update_node ?causes journal ~node update =
  with_write journal (fun state -> stage_update_node ?causes journal state ~node update)
;;

let close_node ?causes journal ~node terminal =
  with_write journal (fun state -> stage_close_node ?causes journal state ~node terminal)
;;

let finish_run ?causes journal ~run terminal =
  with_write journal (fun state -> stage_finish_run ?causes journal state ~run terminal)
;;

type batch =
  { journal : t
  ; base_state : journal_state
  ; staged_state : journal_state
  ; events_rev : Event.t list
  }

type batch_metadata =
  { base_cursor : cursor
  ; final_cursor : cursor
  ; correlation_id : Event.Correlation_id.t
  }

let begin_batch journal =
  let base_state = with_read journal Fun.id in
  { journal; base_state; staged_state = base_state; events_rev = [] }
;;

let begin_durable_batch (writer : durable_writer) = begin_batch writer.journal

let batch_length batch =
  Reducer.last_seq batch.staged_state.reducer - Reducer.last_seq batch.base_state.reducer
;;

let batch_metadata batch =
  { base_cursor =
      make_cursor batch.journal.scope_id (Reducer.last_seq batch.base_state.reducer)
  ; final_cursor =
      make_cursor batch.journal.scope_id (Reducer.last_seq batch.staged_state.reducer)
  ; correlation_id = batch.journal.correlation_id
  }
;;

let extend_batch batch mutation =
  ( { batch with
      staged_state = mutation.next_state
    ; events_rev = reverse_append_cooperatively mutation.events batch.events_rev
    }
  , mutation.value )
;;

module Transaction = struct
  type _ t =
    | Start_run :
        { parent_attempt : Event.Node_id.t option
        ; causes : Event.cause list
        ; agent_name : string
        }
        -> (run * Event.t) t
    | Open_node :
        { causes : Event.cause list
        ; run : run
        ; parent : Event.Node_id.t
        ; kind : Event.node_kind
        }
        -> (Event.Node_id.t * Event.t) t
    | Update_node :
        { causes : Event.cause list
        ; node : Event.Node_id.t
        ; update : Event.node_update
        }
        -> Event.t t
    | Close_node :
        { causes : Event.cause list
        ; node : Event.Node_id.t
        ; terminal : Event.terminal
        }
        -> Event.t t
    | Begin_tool_attempt :
        { invocation : Event.Node_id.t }
        -> (Event.Node_id.t * Event.t) t
    | Open_tool_invocation :
        { run : run
        ; provider_attempt : Event.Node_id.t
        ; invocation : Tool_contract.Invocation.t
        ; tool_name : string
        ; input : Yojson.Safe.t
        }
        -> (Event.Node_id.t * Event.t list) t
    | Settle_tool_attempt :
        { attempt : Event.Node_id.t
        ; invocation : Event.Node_id.t
        ; result : Llm_provider.Types.content_block
        }
        -> Event.t list t
    | Settle_unattempted_tool_invocation :
        { invocation : Event.Node_id.t
        ; result : Llm_provider.Types.content_block
        }
        -> Event.t list t
    | Finish_run :
        { causes : Event.cause list
        ; run : run
        ; terminal : Event.terminal
        }
        -> Event.t t
    | Abort_run :
        { causes : Event.cause list
        ; run : run
        ; terminal : Event.terminal
        }
        -> Event.t list t

  let start_run ?parent_attempt ?(causes = []) ~agent_name () =
    Start_run { parent_attempt; causes; agent_name }
  ;;

  let open_node ?(causes = []) ~run ~parent ~kind () =
    Open_node { causes; run; parent; kind }
  ;;

  let update_node ?(causes = []) ~node update = Update_node { causes; node; update }
  let close_node ?(causes = []) ~node terminal = Close_node { causes; node; terminal }
  let begin_tool_attempt ~invocation () = Begin_tool_attempt { invocation }

  let open_tool_invocation ~run ~provider_attempt ~invocation ~tool_name ~input () =
    Open_tool_invocation { run; provider_attempt; invocation; tool_name; input }
  ;;

  let settle_tool_attempt ~attempt ~invocation ~result () =
    Settle_tool_attempt { attempt; invocation; result }
  ;;

  let settle_unattempted_tool_invocation ~invocation ~result () =
    Settle_unattempted_tool_invocation { invocation; result }
  ;;

  let finish_run ?(causes = []) ~run terminal = Finish_run { causes; run; terminal }
  let abort_run ?(causes = []) ~run terminal = Abort_run { causes; run; terminal }
end

let stage : type value. batch -> value Transaction.t -> (batch * value, error) result =
  fun batch transaction ->
  let stage_mutation result =
    let+ mutation = result in
    extend_batch batch mutation
  in
  match transaction with
  | Transaction.Start_run { parent_attempt; causes; agent_name } ->
    stage_mutation
      (stage_start_run
         ?parent_attempt
         ~causes
         batch.journal
         batch.staged_state
         ~agent_name)
  | Transaction.Open_node { kind = Event.Tool_invocation _; _ } ->
    Error (Invariant_violation Tool_invocation_requires_atomic_open)
  | Transaction.Open_node { causes; run; parent; kind } ->
    stage_mutation
      (stage_open_node ~causes batch.journal batch.staged_state ~run ~parent ~kind)
  | Transaction.Update_node { causes; node; update } ->
    stage_mutation
      (stage_update_node ~causes batch.journal batch.staged_state ~node update)
  | Transaction.Close_node { causes; node; terminal } ->
    stage_mutation
      (stage_close_node ~causes batch.journal batch.staged_state ~node terminal)
  | Transaction.Begin_tool_attempt { invocation } ->
    stage_mutation (stage_begin_tool_attempt batch.journal batch.staged_state ~invocation)
  | Transaction.Open_tool_invocation
      { run; provider_attempt; invocation; tool_name; input } ->
    stage_mutation
      (stage_open_tool_invocation
         batch.journal
         batch.staged_state
         ~run
         ~provider_attempt
         ~invocation
         ~tool_name
         ~input)
  | Transaction.Settle_tool_attempt { attempt; invocation; result } ->
    stage_mutation
      (stage_settle_tool_attempt
         batch.journal
         batch.staged_state
         ~attempt
         ~invocation
         ~result)
  | Transaction.Settle_unattempted_tool_invocation { invocation; result } ->
    stage_mutation
      (stage_settle_unattempted_tool_invocation
         batch.journal
         batch.staged_state
         ~invocation
         ~result)
  | Transaction.Finish_run { causes; run; terminal } ->
    stage_mutation
      (stage_finish_run ~causes batch.journal batch.staged_state ~run terminal)
  | Transaction.Abort_run { causes; run; terminal } ->
    stage_mutation
      (stage_abort_run ~causes batch.journal batch.staged_state ~run terminal)
;;

let commit_batch_locked batch =
  if batch_length batch = 0
  then Error Empty_batch
  else (
    let actual_state = with_read batch.journal Fun.id in
    if not (actual_state == batch.base_state)
    then
      Error
        (Stale_batch
           { expected_last_seq = Reducer.last_seq batch.base_state.reducer
           ; actual_last_seq = Reducer.last_seq actual_state.reducer
           })
    else (
      let events = reverse_cooperatively batch.events_rev in
      commit_mutation
        batch.journal
        batch.base_state
        { next_state = batch.staged_state; events; value = events }))
;;

let commit_batch batch =
  with_writer_gate batch.journal (fun () ->
    let* () = ensure_direct_writer_allowed_locked batch.journal in
    if batch_length batch = 0
    then Error Empty_batch
    else
      let* () = claim_direct_writer_locked batch.journal in
      commit_batch_locked batch)
;;

let commit_durable_batch (writer : durable_writer) (batch : batch) =
  if writer.journal != batch.journal
  then Error Durable_batch_owner_mismatch
  else
    with_writer_gate writer.journal (fun () ->
      let* () = validate_durable_writer_locked writer in
      commit_batch_locked batch)
;;

type durable_batch_reconciliation =
  | Applied of Event.t list
  | Already_durable of Event.t list

let replay_exact_batch (state : journal_state) events =
  let rec loop (state : journal_state) = function
    | [] -> Ok state
    | event :: rest ->
      let* reducer =
        match Reducer.apply state.reducer event with
        | Ok reducer -> Ok reducer
        | Error violation -> Error (Invariant_violation violation)
      in
      Eio.Fiber.yield ();
      loop
        { reducer
        ; events_rev = event :: state.events_rev
        ; events_by_seq = Event_seq_map.add (Event.seq event) event state.events_by_seq
        }
        rest
  in
  loop state events
;;

let reconcile_durable_batch (writer : durable_writer) (batch : batch) =
  with_writer_gate writer.journal (fun () ->
    let* () = validate_durable_writer_locked writer in
    if batch_length batch = 0
    then Error Empty_batch
    else if not (Store.Scope_id.equal writer.journal.scope_id batch.journal.scope_id)
    then Error Reconciliation_scope_mismatch
    else if
      not
        (Event.Correlation_id.equal
           writer.journal.correlation_id
           batch.journal.correlation_id)
    then Error Reconciliation_correlation_mismatch
    else (
      let base_seq = Reducer.last_seq batch.base_state.reducer in
      let final_seq = Reducer.last_seq batch.staged_state.reducer in
      let actual_state = with_read writer.journal Fun.id in
      let current_seq = Reducer.last_seq actual_state.reducer in
      let events = reverse_cooperatively batch.events_rev in
      if current_seq = base_seq
      then
        let* next_state = replay_exact_batch actual_state events in
        let+ committed =
          commit_mutation
            writer.journal
            actual_state
            { next_state; events; value = events }
        in
        Applied committed
      else if current_seq = final_seq
      then (
        match writer.journal.store_writer with
        | None -> Error Durable_store_unavailable
        | Some store_writer ->
          (match
             Store.append_batch store_writer ~expected_next_seq:(base_seq + 1) events
           with
           | Ok Store.Already_committed -> Ok (Already_durable events)
           | Ok Store.Stored ->
             Error
               (Reconciliation_store_diverged
                  { first_seq = base_seq + 1; last_seq = final_seq })
           | Error (Store.Committed_content_conflict { first_seq; last_seq }) ->
             Error (Reconciliation_content_conflict { first_seq; last_seq })
           | Error error -> Error (Persistence_failure error)))
      else Error (Reconciliation_conflict { base_seq; final_seq; current_seq })))
;;

let abort_run ?causes journal ~run terminal =
  with_writer_gate journal (fun () ->
    let* () = ensure_direct_writer_allowed_locked journal in
    let captured_state = with_read journal Fun.id in
    let* mutation = stage_abort_run ?causes journal captured_state ~run terminal in
    let* () = claim_direct_writer_locked journal in
    commit_mutation journal captured_state mutation)
;;

let replay_validated_events events =
  let rec loop (state : journal_state) = function
    | [] -> Ok state
    | event :: rest ->
      let* reducer =
        match Reducer.apply state.reducer event with
        | Ok reducer -> Ok reducer
        | Error violation -> Error (Invariant_violation violation)
      in
      Eio.Fiber.yield ();
      loop
        { reducer
        ; events_rev = event :: state.events_rev
        ; events_by_seq = Event_seq_map.add (Event.seq event) event state.events_by_seq
        }
        rest
  in
  loop
    ({ reducer = Reducer.empty; events_rev = []; events_by_seq = Event_seq_map.empty }
     : journal_state)
    events
;;

type construction_source =
  | Volatile
  | Durable of
      { store : Store.t
      ; replay_events : Event.t list
      }

let create_internal ?correlation_id source =
  let* scope_id, correlation_id, state, store_writer =
    match source with
    | Volatile ->
      let* scope_id =
        match Store.Scope_id.fresh () with
        | Ok value -> Ok value
        | Error detail -> Error (Identity_failure detail)
      in
      let* correlation_id =
        match correlation_id with
        | Some correlation_id -> Ok correlation_id
        | None -> identity_result (Event.Correlation_id.fresh ())
      in
      Ok
        ( scope_id
        , correlation_id
        , { reducer = Reducer.empty
          ; events_rev = []
          ; events_by_seq = Event_seq_map.empty
          }
        , None )
    | Durable { store; replay_events } ->
      let store_correlation = Store.correlation_id store in
      let* () =
        match correlation_id with
        | None -> Ok ()
        | Some correlation_id
          when Event.Correlation_id.equal correlation_id store_correlation -> Ok ()
        | Some _ -> Error (Invalid_argument "store correlation identity mismatch")
      in
      let* state = replay_validated_events replay_events in
      let* store_writer =
        match Store.attach store with
        | Ok writer -> Ok writer
        | Error error -> Error (Persistence_failure error)
      in
      Ok (Store.scope_id store, store_correlation, state, Some store_writer)
  in
  Ok
    { scope_id
    ; correlation_id
    ; store_writer
    ; writer_gate = Eio.Mutex.create ()
    ; mu = Eio.Mutex.create ()
    ; writer_authority = Unclaimed_writer
    ; state
    }
;;

let create ?correlation_id () = create_internal ?correlation_id Volatile

let make_durable_writer journal =
  let claim = ref () in
  journal.writer_authority <- Claimed_durable_writer claim;
  { journal; claim }
;;

let durable_writer_journal (writer : durable_writer) = writer.journal

exception Durable_construction_cleanup_raised of error * exn
exception Journal_construction_cleanup_failed of exn * Store.error
exception Journal_construction_cleanup_raised of Eio.Exn.with_bt * Eio.Exn.with_bt

let () =
  Printexc.register_printer (function
    | Durable_construction_cleanup_raised (construction_error, cleanup_exn) ->
      Some
        ("durable journal construction failed ("
         ^ error_to_string construction_error
         ^ ") and unpublished store cleanup raised ("
         ^ Printexc.to_string cleanup_exn
         ^ ")")
    | Journal_construction_cleanup_failed (construction_exn, cleanup_error) ->
      Some
        ("durable journal construction raised ("
         ^ Printexc.to_string construction_exn
         ^ ") and unpublished store cleanup failed ("
         ^ Store.error_to_string cleanup_error
         ^ ")")
    | Journal_construction_cleanup_raised ((construction_exn, _), (cleanup_exn, _)) ->
      Some
        ("durable journal construction raised ("
         ^ Printexc.to_string construction_exn
         ^ ") and unpublished store cleanup also raised ("
         ^ Printexc.to_string cleanup_exn
         ^ ")")
    | _ -> None)
;;

let release_after_construction_error store construction_error =
  match Store.release_unpublished store with
  | Ok () -> Error construction_error
  | Error cleanup_error ->
    Error (Durable_construction_cleanup_failed { construction_error; cleanup_error })
  | exception cleanup_exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace
      (Durable_construction_cleanup_raised (construction_error, cleanup_exn))
      backtrace
;;

let journal_writer_of_store ~replay_events store =
  match create_internal (Durable { store; replay_events }) with
  | Ok journal -> Ok (make_durable_writer journal)
  | Error construction_error -> release_after_construction_error store construction_error
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    (match Store.release_unpublished store with
     | Ok () -> Printexc.raise_with_backtrace exn bt
     | Error cleanup_error ->
       Printexc.raise_with_backtrace
         (Journal_construction_cleanup_failed (exn, cleanup_error))
         bt
     | exception cleanup_exn ->
       let cleanup_bt = Printexc.get_raw_backtrace () in
       Printexc.raise_with_backtrace
         (Journal_construction_cleanup_raised ((exn, bt), (cleanup_exn, cleanup_bt)))
         bt)
;;

let create_durable_writer ~sw ~codec ~dir ?correlation_id () =
  let* store, initialization =
    match Store.create ~sw ~codec ~dir ?correlation_id () with
    | Ok result -> Ok result
    | Error error -> Error (Persistence_failure error)
  in
  let+ writer = journal_writer_of_store ~replay_events:[] store in
  writer, initialization
;;

let open_durable_writer ~sw ~codec ~dir =
  let* opened =
    match Store.open_existing ~sw ~codec ~dir with
    | Ok result -> Ok result
    | Error error -> Error (Persistence_failure error)
  in
  let+ writer =
    journal_writer_of_store ~replay_events:opened.replay_events opened.store
  in
  writer, opened.recovery
;;
