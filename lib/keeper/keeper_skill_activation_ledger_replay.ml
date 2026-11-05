open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_decode_parts
open Keeper_skill_activation_ledger_decode_ledger
open Keeper_skill_activation_ledger_events

(* The ledger while rows are applied to it. Each activation sits in a cell
   an event updates in place, so applying a row costs the same however many
   activations came before it. A builder serves one batch of rows and is
   dropped when any of them fails. *)
type builder =
  { builder_workspace_key : workspace_key
  ; builder_session_id : Keeper_id.Trace_id.t
  ; cells : (string, activation ref) Hashtbl.t
  ; mutable cells_newest_first : activation ref list
  ; mutable rejections_newest_first : transition_rejection list
  ; mutable async_deliveries_newest_first : Keeper_skill_async_delivery.t list
  ; mutable async_actions_newest_first : Keeper_skill_async_action.t list
  }

let builder_of_ledger (ledger : t) =
  let cells = Hashtbl.create (List.length ledger.activations) in
  let cells_newest_first =
    List.fold_left
      (fun newest_first (activation : activation) ->
         let cell = ref activation in
         Hashtbl.replace cells activation.skill_tool_use_id cell;
         cell :: newest_first)
      []
      ledger.activations
  in
  { builder_workspace_key = ledger.workspace_key
  ; builder_session_id = ledger.session_id
  ; cells
  ; cells_newest_first
  ; rejections_newest_first = List.rev ledger.transition_rejections
  ; async_deliveries_newest_first = List.rev ledger.async_result_deliveries
  ; async_actions_newest_first = List.rev ledger.async_actions
  }
;;

let ledger_of_builder builder =
  make
    ~workspace_key:builder.builder_workspace_key
    ~session_id:builder.builder_session_id
    ~activations:(List.rev_map (fun cell -> !cell) builder.cells_newest_first)
    ~transition_rejections:(List.rev builder.rejections_newest_first)
    ~async_result_deliveries:(List.rev builder.async_deliveries_newest_first)
    ~async_actions:(List.rev builder.async_actions_newest_first)
;;

let update_cell builder skill_tool_use_id update =
  match Hashtbl.find_opt builder.cells skill_tool_use_id with
  | None -> Error (Unknown_event_activation skill_tool_use_id)
  | Some cell ->
    let* updated = update !cell in
    cell := updated;
    Ok ()
;;

let update_cells builder updates =
  List.fold_left
    (fun result (skill_tool_use_id, update) ->
       let* () = result in
       update_cell builder skill_tool_use_id update)
    (Ok ())
    updates
;;

(* Apply one event, holding it to what the decoder requires of a whole
   activation: a unique invocation id, a delivery only after the activation's
   turn and only once, actions only after the delivery's turn and never
   twice, and a rejection only for the activation of its own turn. *)
let apply_event builder = function
  | Activation_recorded activation ->
    if Hashtbl.mem builder.cells activation.skill_tool_use_id
    then Error Duplicate_skill_tool_use_id
    else if Option.is_some activation.delivery || activation.actions <> []
    then Error (Activation_recorded_with_evidence activation.skill_tool_use_id)
    else (
      let cell = ref activation in
      Hashtbl.replace builder.cells activation.skill_tool_use_id cell;
      builder.cells_newest_first <- cell :: builder.cells_newest_first;
      Ok ())
  | Deliveries_observed deliveries ->
    update_cells
      builder
      (List.map
         (fun (skill_tool_use_id, (delivery : delivery)) ->
            ( skill_tool_use_id
            , fun (activation : activation) ->
                match activation.delivery with
                | Some _ -> Error (Delivery_already_observed skill_tool_use_id)
                | None ->
                  let delivery_turn = delivery_boundary_turn delivery.boundary in
                  let before_activation =
                    match delivery.boundary with
                    | Model_response _ -> delivery_turn <= activation.agent_core_turn
                    | Official_client_result_handoff _ ->
                      delivery_turn < activation.agent_core_turn
                  in
                  if before_activation
                  then Error (Invalid_delivery_agent_core_turn delivery_turn)
                  else Ok { activation with delivery = Some delivery } ))
         deliveries)
  | Action_observed { skill_tool_use_ids; action } ->
    update_cells
      builder
      (List.map
         (fun skill_tool_use_id ->
            ( skill_tool_use_id
            , fun (activation : activation) ->
                match activation.delivery with
                | None -> Error (Action_target_not_delivered skill_tool_use_id)
                | Some delivery ->
                  if action.agent_core_turn < delivery_boundary_turn delivery.boundary
                  then Error (Invalid_action_agent_core_turn action.agent_core_turn)
                  else if
                    List.exists
                      (fun (known : action) -> known.identity = action.identity)
                      activation.actions
                  then Error Duplicate_action_identity
                  else Ok { activation with actions = activation.actions @ [ action ] }
            ))
         skill_tool_use_ids)
  | Async_action_observed action ->
    let activations = List.map (fun cell -> !cell) builder.cells_newest_first in
    let* () = validate_async_action ~expected_trace_id:builder.builder_session_id ~activations
      ~async_result_deliveries:builder.async_deliveries_newest_first ~async_actions:builder.async_actions_newest_first action in
    if List.exists (fun known -> String.equal (Keeper_skill_async_action.identity known)
        (Keeper_skill_async_action.identity action)) builder.async_actions_newest_first
    then Error (Invalid_async_action_evidence "duplicate causal occurrence")
    else (builder.async_actions_newest_first <- action :: builder.async_actions_newest_first; Ok ())
  | Async_result_delivered delivery ->
    let activations = List.map (fun cell -> !cell) builder.cells_newest_first in
    let* () = validate_async_result ~expected_trace_id:builder.builder_session_id ~activations delivery in
    if List.exists (fun known -> String.equal (Keeper_skill_async_delivery.identity known)
        (Keeper_skill_async_delivery.identity delivery)) builder.async_deliveries_newest_first
    then Error (Invalid_async_result_evidence "duplicate physical handoff")
    else (builder.async_deliveries_newest_first <- delivery :: builder.async_deliveries_newest_first; Ok ())
  | Transition_rejected rejection ->
    let skill_tool_use_id = rejection_skill_tool_use_id rejection in
    (match Hashtbl.find_opt builder.cells skill_tool_use_id with
     | None -> Error (Orphan_transition_rejection skill_tool_use_id)
     | Some cell ->
       if Ids.Turn_ref.equal (!cell).turn_ref (rejection_activation_turn_ref rejection)
       then (
         builder.rejections_newest_first
         <- rejection :: builder.rejections_newest_first;
         Ok ())
       else Error (Transition_rejection_activation_mismatch skill_tool_use_id))
;;

(* The complete rows of [bytes], each ended by its newline. Text after the
   last newline is a row still being appended and is not part of the store
   yet; a read under the store lock never returns one. *)
let complete_rows bytes =
  match List.rev (String.split_on_char '\n' bytes) with
  | [] -> Ok []
  | _being_appended :: newest_first ->
    let rows = List.rev newest_first in
    if List.exists (String.equal "") rows then Error Blank_event_row else Ok rows
;;

let parse_row row =
  match Yojson.Safe.from_string row with
  | json -> Ok json
  | exception Yojson.Json_error _ -> Error (Expected_object { field = "event" })
;;

let apply_event_rows ~expected_trace_id ledger rows =
  let builder = builder_of_ledger ledger in
  let* _ =
    List.fold_left
      (fun result row ->
         let* row_in_batch = result in
         let* json = parse_row row in
         let* event =
           decode_event ~expected_trace_id json
           |> Result.map_error (function
             | Missing_string { field } ->
               Missing_string_in_event_row
                 { field; row_in_batch
                 ; row_sha256 = Agent_core_sha256.(digest_string row |> to_hex)
                 }
             | (Expected_object _
               | Missing_string_in_event_row _
               | Duplicate_field _
               | Unexpected_field _
               | Unsupported_schema _
               | Invalid_source_id _
               | Invalid_skill_name _
               | Invalid_package_id _
               | Invalid_content_revision _
               | Invalid_snapshot_revision _
               | Invalid_workspace_key _
               | Invalid_session_id _
               | Invalid_origin_kind _
               | Invalid_task_id _
               | Empty_task_ids
               | Duplicate_task_id _
               | Invalid_tool_name _
               | Invalid_composition_execution_id
               | Invalid_nested_composition_scope _
               | Invalid_turn_ref _
               | Turn_ref_session_mismatch
               | Invalid_runtime_id
               | Invalid_skill_tool_use_id
               | Invalid_agent_core_turn _
               | Invalid_served_content_kind _
               | Invalid_served_content_path _
               | Invalid_served_content_bytes _
               | Invalid_served_content_sha256 _
               | Invalid_delivery_agent_core_turn _
               | Invalid_delivery_boundary_kind _
               | Invalid_delivery_time _
               | Invalid_action_identity_field
               | Invalid_action_tool_name_field _
               | Invalid_action_agent_core_turn _
               | Invalid_action_time _
               | Invalid_transition_rejection_kind _
               | Orphan_transition_rejection _
               | Transition_rejection_activation_mismatch _
               | Duplicate_action_identity
               | Invalid_activated_at _
               | Duplicate_skill_tool_use_id
               | Session_id_mismatch
               | Workspace_key_mismatch
               | Invalid_ledger_revision _
               | Ledger_revision_mismatch
               | Invalid_event_kind _
               | Blank_event_row
               | Activation_recorded_with_evidence _
               | Unknown_event_activation _
               | Delivery_already_observed _
               | Action_target_not_delivered _
               | Unterminated_header_row
               | Invalid_async_result_evidence _
               | Invalid_async_action_evidence _) as error -> error)
         in
         let* () = apply_event builder event in
         Ok (row_in_batch + 1))
      (Ok 1)
      rows
  in
  Ok (ledger_of_builder builder)
;;

(* This writer creates a store with its header and first event in one atomic
   step, so a store it made starts with a complete row. Bytes with no newline
   at all are some other file, not a crash residue to cut. *)
let starts_with_complete_row bytes = String.equal bytes "" || String.contains bytes '\n'

(* The whole store, from its first byte: the header, then every event. A
   store with no rows is a session that has recorded nothing; the Bool says
   whether the header is on disk. *)
let replay_store ~workspace_root ~expected_trace_id bytes =
  let base = empty ~workspace_root ~trace_id:expected_trace_id in
  let* () =
    if starts_with_complete_row bytes then Ok () else Error Unterminated_header_row
  in
  let* rows = complete_rows bytes in
  match rows with
  | [] -> Ok (base, false)
  | header :: events ->
    let* header = parse_row header in
    let* () =
      decode_header
        ~expected_workspace_key:base.workspace_key
        ~expected_trace_id
        header
    in
    let* ledger = apply_event_rows ~expected_trace_id base events in
    Ok (ledger, true)
;;
