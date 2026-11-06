open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_encode
open Keeper_skill_activation_ledger_decode_parts
open Keeper_skill_activation_ledger_decode_activation

let exact_key_equal (left : activation) (right : activation) =
  String.equal left.skill_tool_use_id right.skill_tool_use_id
;;

let validate_async_child (activation : activation)
      (child : Keeper_skill_async_delivery.child_activation)
      (delivery : Keeper_skill_async_delivery.t) =
  let invalid detail = Error (Invalid_async_result_evidence detail) in
  if not (String.equal (activation_frame_sha256 activation) child.activation_sha256)
  then invalid "original activation frame differs"
  else if not (Ids.Turn_ref.equal activation.turn_ref delivery.original_turn_ref)
  then invalid "original child turn differs"
  else match activation.invocation with
    | Nested_composition_invocation {scope;_} when
        String.equal scope.composition_run_id (Keeper_tool_plan.Composition_run_id.to_string delivery.composition_run_id)
        && String.equal scope.parent_tool_use_id delivery.logical_parent_tool_use_id -> Ok ()
    | Nested_composition_invocation _ | Instruction_invocation _ | Composition_invocation _ ->
      invalid "handoff does not belong to the original admitted child run"
;;

let validate_async_result ~expected_trace_id ~activations (delivery : Keeper_skill_async_delivery.t) =
  if not (String.equal (Ids.Turn_ref.trace_id delivery.original_turn_ref)
      (Keeper_id.Trace_id.to_string expected_trace_id)) then Error Turn_ref_session_mismatch
  else List.fold_left (fun result (child : Keeper_skill_async_delivery.child_activation) ->
    let id = child.skill_tool_use_id in
    let* () = result in
    match List.find_opt (fun (activation : activation) -> String.equal activation.skill_tool_use_id id) activations with
    | None -> Error (Unknown_event_activation id)
    | Some activation -> validate_async_child activation child delivery)
    (Ok ()) delivery.child_activations
;;

let validate_async_action_fact ~delivery ~async_actions action =
  let invalid detail = Invalid_async_action_evidence detail in
  let* () = Keeper_skill_async_action.validate_delivery delivery action |> Result.map_error invalid in
  match List.find_opt (fun known -> String.equal (Keeper_skill_async_action.occurrence_identity known)
      (Keeper_skill_async_action.occurrence_identity action)) async_actions with
  | None -> Ok ()
  | Some known when Keeper_skill_async_action.same_occurrence_fact known action -> Ok ()
  | Some _ -> Error (invalid "physical occurrence differs across causal links")
;;

let validate_async_action ~expected_trace_id ~activations ~async_result_deliveries ~async_actions action =
  let invalid detail = Invalid_async_action_evidence detail in
  match List.find_opt (fun delivery -> String.equal (Keeper_skill_async_delivery.identity delivery)
      action.Keeper_skill_async_action.delivery_sha256) async_result_deliveries with
  | None -> Error (invalid "unknown causal delivery")
  | Some delivery ->
    let* () = validate_async_result ~expected_trace_id ~activations delivery in
    validate_async_action_fact ~delivery ~async_actions action
;;

let async_evidence_of_yojson ~expected_trace_id ~(activation : activation) json =
  let* fields = object_field "async_evidence" json in
  let* () = exact_fields ~object_name:"async_evidence"
    ~allowed:["async_result_deliveries"; "async_actions"] fields in
  let* result_deliveries = match List.assoc_opt "async_result_deliveries" fields with
    | Some (`List rows) -> List.fold_left (fun result json ->
      let* values = result in
      let* delivery = Keeper_skill_async_delivery.of_json json
        |> Result.map_error (fun detail -> Invalid_async_result_evidence detail) in
      let* () = if String.equal (Ids.Turn_ref.trace_id delivery.original_turn_ref)
          (Keeper_id.Trace_id.to_string expected_trace_id) then Ok () else Error Turn_ref_session_mismatch in
      let* child = match List.find_opt (fun (child : Keeper_skill_async_delivery.child_activation) ->
          String.equal child.skill_tool_use_id activation.skill_tool_use_id) delivery.child_activations with
        | None -> Error (Invalid_async_result_evidence "handoff has no selected child")
        | Some child -> Ok child in
      let* () = validate_async_child activation child delivery in
      if List.exists (fun known -> String.equal (Keeper_skill_async_delivery.identity known)
          (Keeper_skill_async_delivery.identity delivery)) values
      then Error (Invalid_async_result_evidence "duplicate physical handoff") else Ok (delivery :: values))
      (Ok []) rows |> Result.map List.rev
    | Some _ | None -> Error (Expected_object {field="async_result_deliveries"}) in
  let* action_observations = match List.assoc_opt "async_actions" fields with
    | Some (`List rows) -> List.fold_left (fun result json ->
      let* values = result in
      let* action = Keeper_skill_async_action.of_json json
        |> Result.map_error (fun detail -> Invalid_async_action_evidence detail) in
      let* delivery = match List.find_opt (fun delivery -> String.equal
          (Keeper_skill_async_delivery.identity delivery) action.Keeper_skill_async_action.delivery_sha256)
          result_deliveries with
        | None -> Error (Invalid_async_action_evidence "unknown selected causal delivery")
        | Some delivery -> Ok delivery in
      let* () = validate_async_action_fact ~delivery ~async_actions:values action in
      if List.exists (fun known -> String.equal (Keeper_skill_async_action.identity known)
          (Keeper_skill_async_action.identity action)) values
      then Error (Invalid_async_action_evidence "duplicate causal occurrence") else Ok (action :: values))
      (Ok []) rows |> Result.map List.rev
    | Some _ | None -> Error (Expected_object {field="async_actions"}) in
  Ok { result_deliveries; action_observations }
;;

let of_projection_yojson json =
  let* fields = object_field "ledger" json in
  let* () =
    exact_fields
      ~object_name:"ledger"
      ~allowed:
        [ "schema"
        ; "workspace_key"
        ; "session_id"
        ; "revision"
        ; "activations"
        ; "transition_rejections"
        ; "async_result_deliveries"
        ; "async_actions"
        ]
      fields
  in
  let* observed_schema = string_field "schema" fields in
  let* () =
    if String.equal observed_schema schema
    then Ok ()
    else Error (Unsupported_schema observed_schema)
  in
  let* session_id = string_field "session_id" fields in
  let* session_id =
    Keeper_id.Trace_id.of_string session_id
    |> Result.map_error (fun _ -> Invalid_session_id session_id)
  in
  let* workspace_key = string_field "workspace_key" fields in
  let* () =
    Skill_catalog_snapshot.snapshot_revision_of_string workspace_key
    |> Result.map ignore
    |> Result.map_error (fun error -> Invalid_workspace_key error)
  in
  let* declared_revision = string_field "revision" fields in
  let* () =
    Skill_catalog_snapshot.snapshot_revision_of_string declared_revision
    |> Result.map ignore
    |> Result.map_error (fun error -> Invalid_ledger_revision error)
  in
  let* activations =
    match List.assoc_opt "activations" fields with
    | Some (`List values) ->
      List.fold_left
        (fun result value ->
           let* reversed = result in
           let* activation = decode_activation ~expected_trace_id:session_id value in
           Ok (activation :: reversed))
        (Ok [])
        values
      |> Result.map List.rev
    | Some _ | None -> Error (Expected_object { field = "activations" })
  in
  let rec ensure_unique = function
    | [] -> Ok ()
    | activation :: rest ->
      if List.exists (exact_key_equal activation) rest
      then Error Duplicate_skill_tool_use_id
      else ensure_unique rest
  in
  let* () = ensure_unique activations in
  let* transition_rejections =
    match List.assoc_opt "transition_rejections" fields with
    | Some (`List values) ->
      List.fold_left
        (fun result value ->
           let* reversed = result in
           let* rejection =
             decode_transition_rejection ~expected_trace_id:session_id value
           in
           Ok (rejection :: reversed))
        (Ok [])
        values
      |> Result.map List.rev
    | Some _ | None -> Error (Expected_object { field = "transition_rejections" })
  in
  let* () =
    List.fold_left
      (fun result rejection ->
         let* () = result in
         let skill_tool_use_id = rejection_skill_tool_use_id rejection in
         match
           List.find_opt
             (fun (activation : activation) ->
                String.equal activation.skill_tool_use_id skill_tool_use_id)
             activations
         with
         | None -> Error (Orphan_transition_rejection skill_tool_use_id)
         | Some activation ->
           if
             Ids.Turn_ref.equal
               activation.turn_ref
               (rejection_activation_turn_ref rejection)
           then Ok ()
           else
             Error
               (Transition_rejection_activation_mismatch skill_tool_use_id))
      (Ok ())
      transition_rejections
  in
  let* async_result_deliveries = match List.assoc_opt "async_result_deliveries" fields with
    | Some (`List rows) ->
      List.fold_left (fun result json ->
        let* values = result in
        let* value = Keeper_skill_async_delivery.of_json json
          |> Result.map_error (fun detail -> Invalid_async_result_evidence detail) in
        let* () = validate_async_result ~expected_trace_id:session_id ~activations value in
        if List.exists (fun known -> String.equal (Keeper_skill_async_delivery.identity known)
            (Keeper_skill_async_delivery.identity value)) values
        then Error (Invalid_async_result_evidence "duplicate physical handoff") else Ok (value::values))
        (Ok []) rows |> Result.map List.rev
    | Some _ | None -> Error (Expected_object {field="async_result_deliveries"}) in
  let* async_actions = match List.assoc_opt "async_actions" fields with
    | Some (`List rows) -> List.fold_left (fun result json ->
        let* values = result in
        let* value = Keeper_skill_async_action.of_json json
          |> Result.map_error (fun detail -> Invalid_async_action_evidence detail) in
        let* () = validate_async_action ~expected_trace_id:session_id ~activations ~async_result_deliveries ~async_actions:values value in
        if List.exists (fun known -> String.equal (Keeper_skill_async_action.identity known)
            (Keeper_skill_async_action.identity value)) values
        then Error (Invalid_async_action_evidence "duplicate causal occurrence") else Ok (value::values))
        (Ok []) rows |> Result.map List.rev
    | Some _ | None -> Error (Expected_object {field="async_actions"}) in
  let ledger =
    make
      ~workspace_key
      ~session_id
      ~activations
      ~transition_rejections
      ~async_result_deliveries
      ~async_actions
  in
  if String.equal (revision ledger) declared_revision
  then Ok ledger
  else Error Ledger_revision_mismatch
;;
