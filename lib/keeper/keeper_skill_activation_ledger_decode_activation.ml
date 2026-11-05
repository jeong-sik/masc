open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_decode_parts

let decode_invocation json =
  let* fields = object_field "invocation" json in
  let* kind = string_field "kind" fields in
  let* () =
    match kind with
    | "instruction" ->
      exact_fields
        ~object_name:"invocation"
        ~allowed:[ "kind"; "origin"; "served_content" ]
        fields
    | "composition" ->
      exact_fields
        ~object_name:"invocation"
        ~allowed:[ "kind"; "origin"; "tool_name"; "execution_id" ]
        fields
    | "nested_composition" ->
      exact_fields ~object_name:"invocation" ~allowed:[ "kind"; "origin"; "tool_name"; "scope" ] fields
    | observed -> Error (Invalid_served_content_kind observed)
  in
  let* origin_json =
    match List.assoc_opt "origin" fields with
    | Some value -> Ok value
    | None -> Error (Expected_object { field = "origin" })
  in
  match kind with
  | "instruction" ->
    let* origin = decode_instruction_origin origin_json in
    let* served_content_json =
      match List.assoc_opt "served_content" fields with
      | Some value -> Ok value
      | None -> Error (Expected_object { field = "served_content" })
    in
    let* served_content = decode_served_content served_content_json in
    Ok (Instruction_invocation { origin; served_content })
  | "composition" ->
    let* origin = decode_composition_origin origin_json in
    let* tool_name = string_field "tool_name" fields in
    if Safe_identifier.is_portable_name tool_name
    then (let* execution_id = string_field "execution_id" fields in
      if String.trim execution_id = "" then Error Invalid_composition_execution_id
      else Ok (Composition_invocation { origin; tool_name; execution_id = Ids.Execution_id.of_string execution_id }))
    else Error (Invalid_tool_name tool_name)
  | "nested_composition" ->
    let* origin = decode_composition_origin origin_json in
    let* tool_name = string_field "tool_name" fields in
    let* () = if Safe_identifier.is_portable_name tool_name then Ok () else Error (Invalid_tool_name tool_name) in
    let* fields = match List.assoc_opt "scope" fields with
      | Some json -> object_field "scope" json
      | None -> Error (Expected_object { field = "scope" }) in
    let* () = exact_fields ~object_name:"scope"
        ~allowed:[ "parent_tool_use_id"; "composition_run_id"; "alias" ] fields in
    let* parent_tool_use_id = string_field "parent_tool_use_id" fields in
    let* composition_run_id = string_field "composition_run_id" fields in
    let* alias = string_field "alias" fields in
    let* scope = nested_composition_scope ~parent_tool_use_id ~composition_run_id ~alias in
    Ok (Nested_composition_invocation { origin; tool_name; scope })
  | observed -> Error (Invalid_served_content_kind observed)
;;

let decode_transition_turn_ref ~expected_trace_id field fields =
  let* text = string_field field fields in
  let* turn_ref =
    match Ids.Turn_ref.of_string text with
    | Some turn_ref -> Ok turn_ref
    | None -> Error (Invalid_turn_ref text)
  in
  if
    String.equal
      (Ids.Turn_ref.trace_id turn_ref)
      (Keeper_id.Trace_id.to_string expected_trace_id)
  then Ok turn_ref
  else Error Turn_ref_session_mismatch
;;

let decode_transition_rejection ~expected_trace_id json =
  let* fields = object_field "transition_rejection" json in
  let* kind = string_field "kind" fields in
  let* () =
    let allowed =
      match kind with
      | "delivery_order" ->
        [ "kind"
        ; "skill_tool_use_id"
        ; "activation_turn_ref"
        ; "observed_turn_ref"
        ; "activation_agent_core_turn"
        ; "observed_agent_core_turn"
        ; "observed_at"
        ]
      | "delivery_conflict" ->
        [ "kind"
        ; "skill_tool_use_id"
        ; "activation_turn_ref"
        ; "observed_turn_ref"
        ; "observed_agent_core_turn"
        ; "observed_at"
        ]
      | "action_before_delivery" ->
        [ "kind"
        ; "skill_tool_use_id"
        ; "activation_turn_ref"
        ; "observed_turn_ref"
        ; "action_identity"
        ; "tool_name"
        ; "observed_agent_core_turn"
        ; "observed_at"
        ]
      | _ -> []
    in
    match allowed with
    | [] -> Error (Invalid_transition_rejection_kind kind)
    | allowed -> exact_fields ~object_name:"transition_rejection" ~allowed fields
  in
  let* skill_tool_use_id = string_field "skill_tool_use_id" fields in
  let* () =
    if String.equal (String.trim skill_tool_use_id) ""
    then Error Invalid_skill_tool_use_id
    else Ok ()
  in
  let* activation_turn_ref =
    decode_transition_turn_ref ~expected_trace_id "activation_turn_ref" fields
  in
  let* observed_turn_ref =
    decode_transition_turn_ref ~expected_trace_id "observed_turn_ref" fields
  in
  let* observed_agent_core_turn = int_field "observed_agent_core_turn" fields in
  let* () =
    if observed_agent_core_turn < 0
    then Error (Invalid_action_agent_core_turn observed_agent_core_turn)
    else Ok ()
  in
  let* observed_at = string_field "observed_at" fields in
  let* () =
    Time_codec.parse_rfc3339 observed_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_action_time observed_at)
  in
  match kind with
  | "delivery_order" ->
    let* activation_agent_core_turn =
      int_field "activation_agent_core_turn" fields
    in
    if activation_agent_core_turn < 0
    then Error (Invalid_agent_core_turn activation_agent_core_turn)
    else
      Ok
        (Delivery_order_rejected
           { skill_tool_use_id
           ; activation_turn_ref
           ; observed_turn_ref
           ; activation_agent_core_turn
           ; observed_agent_core_turn
           ; observed_at
           })
  | "delivery_conflict" ->
    Ok
      (Delivery_conflict_rejected
         { skill_tool_use_id
         ; activation_turn_ref
         ; observed_turn_ref
         ; observed_agent_core_turn
         ; observed_at
         })
  | "action_before_delivery" ->
    let* action_identity_json =
      match List.assoc_opt "action_identity" fields with
      | Some value -> Ok value
      | None -> Error Invalid_action_identity_field
    in
    let* action_identity = decode_action_identity action_identity_json in
    let* tool_name = string_field "tool_name" fields in
    let* () =
      if Safe_identifier.is_portable_name tool_name
      then Ok ()
      else Error (Invalid_action_tool_name_field tool_name)
    in
    Ok
      (Action_before_delivery_rejected
         { skill_tool_use_id
         ; activation_turn_ref
         ; observed_turn_ref
         ; action_identity
         ; tool_name
         ; observed_agent_core_turn
         ; observed_at
         })
  | observed -> Error (Invalid_transition_rejection_kind observed)
;;

let decode_activation ~expected_trace_id json =
  let* fields = object_field "activation" json in
  let* () =
    exact_fields
      ~object_name:"activation"
      ~allowed:
        [ "identity"
        ; "content_revision"
        ; "snapshot_revision"
        ; "turn_ref"
        ; "runtime_id"
        ; "skill_tool_use_id"
        ; "agent_core_turn"
        ; "invocation"
        ; "delivery"
        ; "actions"
        ; "activated_at"
        ]
      fields
  in
  let* identity_json =
    match List.assoc_opt "identity" fields with
    | Some value -> Ok value
    | None -> Error (Expected_object { field = "identity" })
  in
  let* identity = decode_identity identity_json in
  let* content = string_field "content_revision" fields in
  let* content_revision =
    Skill_reference.content_revision_of_string content
    |> Result.map_error (fun error -> Invalid_content_revision error)
  in
  let* snapshot = string_field "snapshot_revision" fields in
  let* snapshot_revision =
    Skill_catalog_snapshot.snapshot_revision_of_string snapshot
    |> Result.map_error (fun error -> Invalid_snapshot_revision error)
  in
  let* turn_ref = string_field "turn_ref" fields in
  let* turn_ref =
    match Ids.Turn_ref.of_string turn_ref with
    | Some turn_ref -> Ok turn_ref
    | None -> Error (Invalid_turn_ref turn_ref)
  in
  let* () =
    if
      String.equal
        (Ids.Turn_ref.trace_id turn_ref)
        (Keeper_id.Trace_id.to_string expected_trace_id)
    then Ok ()
    else Error Turn_ref_session_mismatch
  in
  let* runtime_id = string_field "runtime_id" fields in
  let* skill_tool_use_id = string_field "skill_tool_use_id" fields in
  let* agent_core_turn = int_field "agent_core_turn" fields in
  let* invocation_json =
    match List.assoc_opt "invocation" fields with
    | Some value -> Ok value
    | None -> Error (Expected_object { field = "invocation" })
  in
  let* invocation = decode_invocation invocation_json in
  let* delivery_json =
    match List.assoc_opt "delivery" fields with
    | Some value -> Ok value
    | None -> Error (Expected_object { field = "delivery" })
  in
  let* delivery = decode_delivery delivery_json in
  let* actions =
    match List.assoc_opt "actions" fields with
    | Some (`List values) ->
      List.fold_left
        (fun result value ->
           let* reversed = result in
           let* action = decode_action value in
           Ok (action :: reversed))
        (Ok [])
        values
      |> Result.map List.rev
    | Some _ | None -> Error (Expected_object { field = "actions" })
  in
  let rec ensure_unique_actions (actions : action list) =
    match actions with
    | [] -> Ok ()
    | action :: rest ->
      if List.exists (fun (other : action) -> action.identity = other.identity) rest
      then Error Duplicate_action_identity
      else ensure_unique_actions rest
  in
  let* () = ensure_unique_actions actions in
  let* activated_at = string_field "activated_at" fields in
  let* () =
    Time_codec.parse_rfc3339 activated_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_activated_at activated_at)
  in
  let* activation =
    make_activation_evidence
    ~identity
    ~content_revision
    ~snapshot_revision
    ~turn_ref
    ~runtime_id
    ~skill_tool_use_id
    ~agent_core_turn
    ~invocation
    ~activated_at
  in
  (match delivery with
   | Some observed
     when (match observed.boundary with
           | Model_response { agent_core_turn } ->
             agent_core_turn <= activation.agent_core_turn
           | Official_client_result_handoff { agent_core_turn } ->
             agent_core_turn < activation.agent_core_turn) ->
     Error
       (Invalid_delivery_agent_core_turn
          (delivery_boundary_turn observed.boundary))
   | Some observed ->
     let delivery_turn = delivery_boundary_turn observed.boundary in
     (match
        List.find_opt
          (fun (action : action) ->
             action.agent_core_turn < delivery_turn)
          actions
      with
      | Some (action : action) ->
        Error (Invalid_action_agent_core_turn action.agent_core_turn)
      | None -> Ok { activation with delivery; actions })
   | None when actions <> [] -> Error (Invalid_delivery_agent_core_turn (-1))
   | None -> Ok { activation with delivery; actions })
;;

let activation_of_yojson ~expected_trace_id json =
  decode_activation ~expected_trace_id json
;;
