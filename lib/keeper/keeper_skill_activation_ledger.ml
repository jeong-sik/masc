open Result.Syntax

include Keeper_skill_activation_types
include Keeper_skill_activation_ledger_errors
include Keeper_skill_activation_ledger_model
include Keeper_skill_activation_ledger_encode

let action_identity_valid = function
  | Call_id call_id -> String.trim call_id <> ""
  | Provider_step { conversation_id; step_index } ->
    String.trim conversation_id <> "" && step_index >= 0
;;

let object_field field = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Expected_object { field })
;;

let string_field field fields =
  match List.assoc_opt field fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Missing_string { field })
;;

let int_field field fields =
  match List.assoc_opt field fields with
  | Some (`Int value) -> Ok value
  | Some _ | None -> Error (Expected_object { field })
;;

let exact_fields ~object_name ~allowed fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (field, _) :: rest ->
      if List.mem field seen
      then Error (Duplicate_field { object_name; field })
      else if not (List.mem field allowed)
      then Error (Unexpected_field { object_name; field })
      else loop (field :: seen) rest
  in
  loop [] fields
;;

let decode_identity json =
  let* fields = object_field "identity" json in
  let* () =
    exact_fields
      ~object_name:"identity"
      ~allowed:[ "source_id"; "package_id"; "name" ]
      fields
  in
  let* source = string_field "source_id" fields in
  let* package = string_field "package_id" fields in
  let* name = string_field "name" fields in
  let* canonical_name =
    Agent_core.Skill_document.canonical_name name
    |> Result.map_error (fun _ -> Invalid_skill_name name)
  in
  let* () =
    if String.equal canonical_name name
    then Ok ()
    else Error (Invalid_skill_name name)
  in
  let* source_id =
    Skill_source_config.source_id_of_string source
    |> Result.map_error (fun _ -> Invalid_source_id source)
  in
  let* package_id =
    Skill_reference.package_id_of_directory package
    |> Result.map_error (fun error -> Invalid_package_id error)
  in
  Ok (Skill_reference.make_identity ~source_id ~package_id ~name)
;;

let decode_task_id_set fields =
  let* task_ids =
    match List.assoc_opt "task_ids" fields with
    | Some (`List values) ->
      List.fold_left
        (fun result value ->
           let* reversed = result in
           match value with
           | `String text ->
             let* task_id =
               Keeper_id.Task_id.of_string text
               |> Result.map_error (fun _ -> Invalid_task_id text)
             in
             Ok (task_id :: reversed)
           | _ -> Error (Expected_object { field = "task_ids" }))
        (Ok [])
        values
      |> Result.map List.rev
    | Some _ | None -> Error (Expected_object { field = "task_ids" })
  in
  task_id_set_of_list task_ids
;;

let decode_instruction_origin json =
  let* fields = object_field "origin" json in
  let* kind = string_field "kind" fields in
  let* () =
    match kind with
    | "task_instruction" ->
      exact_fields
        ~object_name:"origin"
        ~allowed:[ "kind"; "task_ids" ]
        fields
    | "session_instruction" ->
      exact_fields ~object_name:"origin" ~allowed:[ "kind" ] fields
    | kind -> Error (Invalid_origin_kind kind)
  in
  match kind with
  | "task_instruction" ->
    let* task_ids = decode_task_id_set fields in
    Ok (Task_instruction { task_ids })
  | "session_instruction" -> Ok Session_instruction
  | kind -> Error (Invalid_origin_kind kind)
;;

let decode_composition_origin json =
  let* fields = object_field "origin" json in
  let* kind = string_field "kind" fields in
  let* () =
    match kind with
    | "task_composition" ->
      exact_fields ~object_name:"origin" ~allowed:[ "kind"; "task_ids" ] fields
    | "session_composition" ->
      exact_fields ~object_name:"origin" ~allowed:[ "kind" ] fields
    | kind -> Error (Invalid_origin_kind kind)
  in
  match kind with
  | "task_composition" ->
    let* task_ids = decode_task_id_set fields in
    Ok (Task_composition { task_ids })
  | "session_composition" -> Ok Session_composition
  | kind -> Error (Invalid_origin_kind kind)
;;

let delivery_boundary_turn = function
  | Model_response { agent_core_turn }
  | Official_client_result_handoff { agent_core_turn } -> agent_core_turn
;;

let decode_delivery_boundary json =
  let* fields = object_field "delivery_boundary" json in
  let* () =
    exact_fields
      ~object_name:"delivery_boundary"
      ~allowed:[ "kind"; "agent_core_turn" ]
      fields
  in
  let* kind = string_field "kind" fields in
  let* agent_core_turn = int_field "agent_core_turn" fields in
  if agent_core_turn < 0
  then Error (Invalid_delivery_agent_core_turn agent_core_turn)
  else
    match kind with
    | "model_response" -> Ok (Model_response { agent_core_turn })
    | "official_client_result_handoff" ->
      Ok (Official_client_result_handoff { agent_core_turn })
    | observed -> Error (Invalid_delivery_boundary_kind observed)
;;

let decode_delivery = function
  | `Null -> Ok None
  | json ->
    let* fields = object_field "delivery" json in
    let* () =
      exact_fields
        ~object_name:"delivery"
        ~allowed:
          [ "boundary"
          ; "runtime_id"
          ; "delivered_at"
          ; "content_bytes"
          ; "content_sha256"
          ]
        fields
    in
    let* boundary_json =
      match List.assoc_opt "boundary" fields with
      | Some value -> Ok value
      | None -> Error (Expected_object { field = "boundary" })
    in
    let* boundary = decode_delivery_boundary boundary_json in
    let* runtime_id = string_field "runtime_id" fields in
    let* delivered_at = string_field "delivered_at" fields in
    let* content_bytes = int_field "content_bytes" fields in
    let* content_sha256 = string_field "content_sha256" fields in
    let* () =
      if String.equal (String.trim runtime_id) ""
      then Error Invalid_runtime_id
      else Ok ()
    in
    let* () =
      if content_bytes < 0
      then Error (Invalid_served_content_bytes content_bytes)
      else Ok ()
    in
    let* () =
      Time_codec.parse_rfc3339 delivered_at
      |> Result.map ignore
      |> Result.map_error (fun _ -> Invalid_delivery_time delivered_at)
    in
    let* () =
      Skill_reference.validate_revision_string content_sha256
      |> Result.map_error (fun error -> Invalid_served_content_sha256 error)
    in
    Ok (Some { boundary; runtime_id; delivered_at; content_bytes; content_sha256 })
;;

let decode_action_identity json =
  let* fields = object_field "action identity" json in
  let* kind = string_field "kind" fields in
  match kind with
  | "call_id" ->
    let* () =
      exact_fields
        ~object_name:"action identity"
        ~allowed:[ "kind"; "call_id" ]
        fields
    in
    let* call_id = string_field "call_id" fields in
    let identity = Call_id call_id in
    if action_identity_valid identity
    then Ok identity
    else Error Invalid_action_identity_field
  | "provider_step" ->
    let* () =
      exact_fields
        ~object_name:"action identity"
        ~allowed:[ "kind"; "conversation_id"; "step_index" ]
        fields
    in
    let* conversation_id = string_field "conversation_id" fields in
    let* step_index = int_field "step_index" fields in
    let identity = Provider_step { conversation_id; step_index } in
    if action_identity_valid identity
    then Ok identity
    else Error Invalid_action_identity_field
  | _ -> Error Invalid_action_identity_field
;;

let decode_action json =
  let* fields = object_field "action" json in
  let* () =
    exact_fields
      ~object_name:"action"
      ~allowed:
        [ "identity"
        ; "tool_name"
        ; "runtime_id"
        ; "agent_core_turn"
        ; "observed_at"
        ]
      fields
  in
  let* identity_json =
    match List.assoc_opt "identity" fields with
    | Some value -> Ok value
    | None -> Error Invalid_action_identity_field
  in
  let* identity = decode_action_identity identity_json in
  let* tool_name = string_field "tool_name" fields in
  let* runtime_id = string_field "runtime_id" fields in
  let* agent_core_turn = int_field "agent_core_turn" fields in
  let* observed_at = string_field "observed_at" fields in
  let* () =
    if String.equal (String.trim runtime_id) ""
    then Error Invalid_runtime_id
    else Ok ()
  in
  let* () =
    if Safe_identifier.is_portable_name tool_name
    then Ok ()
    else Error (Invalid_action_tool_name_field tool_name)
  in
  let* () =
    if agent_core_turn < 0
    then Error (Invalid_action_agent_core_turn agent_core_turn)
    else Ok ()
  in
  let* () =
    Time_codec.parse_rfc3339 observed_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_action_time observed_at)
  in
  Ok { identity; tool_name; runtime_id; agent_core_turn; observed_at }
;;

let decode_served_content json =
  let* fields = object_field "served_content" json in
  let* kind = string_field "kind" fields in
  let* () =
    let allowed =
      match kind with
      | "skill_body" -> [ "kind"; "bytes"; "sha256" ]
      | "skill_resource" ->
        [ "kind"; "relative_path"; "bytes"; "sha256" ]
      | observed -> []
    in
    match allowed with
    | [] -> Error (Invalid_served_content_kind kind)
    | allowed -> exact_fields ~object_name:"served_content" ~allowed fields
  in
  let* bytes = int_field "bytes" fields in
  let* sha256 = string_field "sha256" fields in
  let* served_content =
    match kind with
    | "skill_body" -> Ok (Skill_body { bytes; sha256 })
    | "skill_resource" ->
      let* relative_path = string_field "relative_path" fields in
      Ok (Skill_resource { relative_path; bytes; sha256 })
    | observed -> Error (Invalid_served_content_kind observed)
  in
  let* () = validate_served_content served_content in
  Ok served_content
;;

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

(* ── Durable event log ──────────────────────────────────────────────

   A session's ledger is an append-only JSONL file. Its first row names the
   workspace and the session; every later row is one change -- an activation
   recorded, deliveries observed, an action observed, or a transition
   rejected. The ledger a reader sees is those rows applied in order, and a
   mutation is the event it appends applied to the ledger it read, so what a
   process holds and what a replay of the file rebuilds are one function of
   the same rows.

   A mutation appends one row. This process keeps each session's applied
   ledger with the file cursor it was read to, and the next read under the
   session lock takes only the rows written after that cursor.
   [events_schema] names the row shape of the whole log. A change that makes
   an existing row undecodable bumps it, so a log of another generation is
   refused at its header as [Unsupported_schema] instead of at the first row
   the new decoder cannot read. v2 begins where a composition invocation
   carries its physical [execution_id]; v1 composition rows have none. A log
   of another generation is retired by the operator while the server is
   stopped, and no reader converts it. Rollback to a binary of an earlier
   generation is unsupported for the same reason. *)

let events_schema = "masc.skill-activation-events/v2"
let events_filename = "skill-activation-events.jsonl"
let events_path session_dir = Filename.concat session_dir events_filename

type event =
  | Activation_recorded of activation
  | Deliveries_observed of (string * delivery) list
  | Action_observed of
      { skill_tool_use_ids : string list
      ; action : action
      }
  | Transition_rejected of transition_rejection
  | Async_result_delivered of Keeper_skill_async_delivery.t
  | Async_action_observed of Keeper_skill_async_action.t

let header_to_yojson ~workspace_key ~session_id =
  `Assoc
    [ "schema", `String events_schema
    ; "kind", `String "opened"
    ; "workspace_key", `String workspace_key
    ; "session_id", `String (Keeper_id.Trace_id.to_string session_id)
    ]
;;

let event_to_yojson = function
  | Activation_recorded activation ->
    `Assoc
      [ "kind", `String "activation_recorded"
      ; "activation", activation_to_yojson activation
      ]
  | Deliveries_observed deliveries ->
    `Assoc
      [ "kind", `String "deliveries_observed"
      ; ( "deliveries"
        , `List
            (List.map
               (fun (skill_tool_use_id, delivery) ->
                  `Assoc
                    [ "skill_tool_use_id", `String skill_tool_use_id
                    ; "delivery", delivery_to_yojson delivery
                    ])
               deliveries) )
      ]
  | Action_observed { skill_tool_use_ids; action } ->
    `Assoc
      [ "kind", `String "action_observed"
      ; ( "skill_tool_use_ids"
        , `List (List.map (fun id -> `String id) skill_tool_use_ids) )
      ; "action", action_to_yojson action
      ]
  | Async_action_observed action ->
    `Assoc ["kind",`String "async_action_observed";"action",Keeper_skill_async_action.to_json action]
  | Async_result_delivered delivery ->
    `Assoc ["kind",`String "async_result_delivered";"delivery",Keeper_skill_async_delivery.to_json delivery]
  | Transition_rejected rejection ->
    `Assoc
      [ "kind", `String "transition_rejected"
      ; "rejection", transition_rejection_to_yojson rejection
      ]
;;

let event_row json = Yojson.Safe.to_string json ^ "\n"

let required_field ~field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Expected_object { field })
;;

let decode_header ~expected_workspace_key ~expected_trace_id json =
  let* fields = object_field "events_header" json in
  let* () =
    exact_fields
      ~object_name:"events_header"
      ~allowed:[ "schema"; "kind"; "workspace_key"; "session_id" ]
      fields
  in
  let* observed_schema = string_field "schema" fields in
  let* () =
    if String.equal observed_schema events_schema
    then Ok ()
    else Error (Unsupported_schema observed_schema)
  in
  let* kind = string_field "kind" fields in
  let* () =
    if String.equal kind "opened" then Ok () else Error (Invalid_event_kind kind)
  in
  let* session_id = string_field "session_id" fields in
  let* session_id =
    Keeper_id.Trace_id.of_string session_id
    |> Result.map_error (fun _ -> Invalid_session_id session_id)
  in
  let* () =
    if Keeper_id.Trace_id.equal session_id expected_trace_id
    then Ok ()
    else Error Session_id_mismatch
  in
  let* workspace_key = string_field "workspace_key" fields in
  if String.equal workspace_key expected_workspace_key
  then Ok ()
  else Error Workspace_key_mismatch
;;

let decode_event ~expected_trace_id json =
  let* fields = object_field "event" json in
  let* kind = string_field "kind" fields in
  match kind with
  | "activation_recorded" ->
    let* () =
      exact_fields ~object_name:"event" ~allowed:[ "kind"; "activation" ] fields
    in
    let* activation = required_field ~field:"activation" fields in
    let* activation = decode_activation ~expected_trace_id activation in
    Ok (Activation_recorded activation)
  | "deliveries_observed" ->
    let* () =
      exact_fields ~object_name:"event" ~allowed:[ "kind"; "deliveries" ] fields
    in
    (match List.assoc_opt "deliveries" fields with
     | Some (`List values) ->
       let* reversed =
         List.fold_left
           (fun result value ->
              let* reversed = result in
              let* entry = object_field "delivery_observation" value in
              let* () =
                exact_fields
                  ~object_name:"delivery_observation"
                  ~allowed:[ "skill_tool_use_id"; "delivery" ]
                  entry
              in
              let* skill_tool_use_id = string_field "skill_tool_use_id" entry in
              let* delivery = required_field ~field:"delivery" entry in
              let* delivery = decode_delivery delivery in
              match delivery with
              | Some delivery -> Ok ((skill_tool_use_id, delivery) :: reversed)
              | None -> Error (Expected_object { field = "delivery" }))
           (Ok [])
           values
       in
       Ok (Deliveries_observed (List.rev reversed))
     | Some _ | None -> Error (Expected_object { field = "deliveries" }))
  | "action_observed" ->
    let* () =
      exact_fields
        ~object_name:"event"
        ~allowed:[ "kind"; "skill_tool_use_ids"; "action" ]
        fields
    in
    let* skill_tool_use_ids =
      match List.assoc_opt "skill_tool_use_ids" fields with
      | Some (`List values) ->
        List.fold_left
          (fun result value ->
             let* reversed = result in
             match value with
             | `String id -> Ok (id :: reversed)
             | _ -> Error (Missing_string { field = "skill_tool_use_ids" }))
          (Ok [])
          values
        |> Result.map List.rev
      | Some _ | None -> Error (Expected_object { field = "skill_tool_use_ids" })
    in
    let* action = required_field ~field:"action" fields in
    let* action = decode_action action in
    Ok (Action_observed { skill_tool_use_ids; action })
  | "async_action_observed" ->
    let* () = exact_fields ~object_name:"event" ~allowed:["kind";"action"] fields in
    let* json = required_field ~field:"action" fields in
    let* action = Keeper_skill_async_action.of_json json
      |> Result.map_error (fun detail -> Invalid_async_action_evidence detail) in
    Ok (Async_action_observed action)
  | "async_result_delivered" ->
    let* () = exact_fields ~object_name:"event" ~allowed:["kind";"delivery"] fields in
    let* json = required_field ~field:"delivery" fields in
    let* delivery = Keeper_skill_async_delivery.of_json json
      |> Result.map_error (fun detail -> Invalid_async_result_evidence detail) in
    Ok (Async_result_delivered delivery)
  | "transition_rejected" ->
    let* () =
      exact_fields ~object_name:"event" ~allowed:[ "kind"; "rejection" ] fields
    in
    let* rejection = required_field ~field:"rejection" fields in
    let* rejection = decode_transition_rejection ~expected_trace_id rejection in
    Ok (Transition_rejected rejection)
  | kind -> Error (Invalid_event_kind kind)
;;

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

(* ── This process's view of each session store ──────────────────── *)

type session_log =
  { ledger : t
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  ; header_written : bool
  }

module Session_logs = Map.Make (String)

(* Keyed by the canonical store path. A store is read and written only under
   its session lock, so one entry never has two writers; the compare-and-set
   loop keeps two sessions' updates from dropping each other. *)
let session_logs : session_log Session_logs.t Atomic.t = Atomic.make Session_logs.empty

let rec update_session_logs change =
  let current = Atomic.get session_logs in
  if not (Atomic.compare_and_set session_logs current (change current))
  then update_session_logs change
;;

let remember_session_log path log = update_session_logs (Session_logs.add path log)
let forget_session_log path = update_session_logs (Session_logs.remove path)
let remembered_session_log path = Session_logs.find_opt path (Atomic.get session_logs)

let observe_settlement_warning ~path error =
  Log.Keeper.error
    "skill_activation_ledger: descriptor settlement incomplete store=%s detail=%s"
    path
    (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let snapshot_result ~path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error error
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

let cursor_result ~path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error error
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

(* Replay a store from its first byte: on the first read of it in this
   process, and whenever this process no longer knows where the store ends.
   A row a crash left half-appended is cut back to the last complete row
   before anything is replayed. The session lock is held, and every writer
   appends under it, so such a tail was left by a writer that died, never by
   one still writing. A store whose very first row is unterminated is refused
   and left as it is. *)
let replay_session_log ~ownership_root ~expected_trace_id path =
  let* snapshot =
    match
      snapshot_result
        ~path
        (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None)
    with
    | Ok snapshot -> Ok snapshot
    | Error (Fs_compat.Incomplete_transaction_tail _) ->
      (match Fs_compat.load_owned_regular_file ~ownership_root path with
       | Error error -> Error (Read_failed error)
       | Ok (Some contents) when not (starts_with_complete_row contents) ->
         Error (Decode_failed Unterminated_header_row)
       | Ok (Some _ | None) ->
         snapshot_result ~path (Fs_compat.recover_private_jsonl_durable_locked_result path)
         |> Result.map_error (fun error -> Event_log_failed error))
    | Error
        (( Fs_compat.Stable_lock_contended _
         | Fs_compat.Unexpected_stable_lock_permissions _
         | Fs_compat.Invalid_stable_lock_state _
         | Fs_compat.Cursor_mismatch _
         | Fs_compat.Unexpected_transaction_file_kind _
         | Fs_compat.Ambiguous_transaction_file_identity _
         | Fs_compat.Transaction_path_binding_changed _
         | Fs_compat.Transaction_content_changed _
         | Fs_compat.Invalid_transaction_suffix
         | Fs_compat.Private_jsonl_operation_failed _
         | Fs_compat.Rewrite_stage_failed _
         | Fs_compat.Rewrite_published_durability_unknown _
         | Fs_compat.Transaction_settlement_failed _
         | Fs_compat.Transaction_append_failed _ ) as error) ->
      Error (Event_log_failed error)
  in
  let* ledger, header_written =
    replay_store
      ~workspace_root:ownership_root
      ~expected_trace_id
      snapshot.Fs_compat.bytes
    |> Result.map_error (fun error -> Decode_failed error)
  in
  let log = { ledger; cursor = snapshot.Fs_compat.cursor; header_written } in
  remember_session_log path log;
  Ok log
;;

(* Under the session lock. A remembered store is read only after its cursor.
   A failure there drops what this process remembers of the store, and one
   replaced, truncated or left with a torn tail behind that cursor is
   replayed from its first byte at once. *)
let read_locked ~ownership_root ~expected_trace_id session_dir =
  let path = events_path session_dir in
  match remembered_session_log path with
  | None -> replay_session_log ~ownership_root ~expected_trace_id path
  | Some log ->
    (match
       snapshot_result
         ~path
         (Fs_compat.read_private_jsonl_durable_locked_result
            path
            ~after:(Some log.cursor))
     with
     | Error (Fs_compat.Cursor_mismatch _ | Fs_compat.Incomplete_transaction_tail _) ->
       forget_session_log path;
       replay_session_log ~ownership_root ~expected_trace_id path
     | Error
         (( Fs_compat.Stable_lock_contended _
          | Fs_compat.Unexpected_stable_lock_permissions _
          | Fs_compat.Invalid_stable_lock_state _
          | Fs_compat.Unexpected_transaction_file_kind _
          | Fs_compat.Ambiguous_transaction_file_identity _
          | Fs_compat.Transaction_path_binding_changed _
          | Fs_compat.Transaction_content_changed _
          | Fs_compat.Invalid_transaction_suffix
          | Fs_compat.Private_jsonl_operation_failed _
          | Fs_compat.Rewrite_stage_failed _
          | Fs_compat.Rewrite_published_durability_unknown _
          | Fs_compat.Transaction_settlement_failed _
          | Fs_compat.Transaction_append_failed _ ) as error) ->
       forget_session_log path;
       Error (Event_log_failed error)
     | Ok (snapshot : Fs_compat.private_jsonl_snapshot) ->
       if String.equal snapshot.bytes ""
       then Ok log
       else (
         match
           let* rows = complete_rows snapshot.bytes in
           apply_event_rows ~expected_trace_id log.ledger rows
         with
         | Error error ->
           forget_session_log path;
           Error (Decode_failed error)
         | Ok ledger ->
           let log = { log with ledger; cursor = snapshot.cursor } in
           remember_session_log path log;
           Ok log))
;;

let with_lock ~config ~trace_id operation =
  let session_dir =
    Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id)
  in
  match
    Keeper_checkpoint_store.with_session_lock ~session_dir (fun canonical_session_dir ->
      let ownership_root = Filename.dirname canonical_session_dir in
      operation ~ownership_root canonical_session_dir)
  with
  | Error detail -> Error (Lock_failed detail)
  | Ok result -> result
;;

let load ~config ~trace_id =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
    read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
    |> Result.map (fun log -> log.ledger))
;;

(* Without a lock: the store is only ever appended to, so what is on disk is
   a run of committed rows, possibly followed by the row a writer is
   appending right now, which [complete_rows] leaves out. *)
let replay_unlocked ~ownership_root ~trace_id path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Ok None
  | Ok (Some contents) ->
    (match
       replay_store ~workspace_root:ownership_root ~expected_trace_id:trace_id contents
     with
     | Error error -> Error (Decode_failed error)
     | Ok (_, false) -> Ok None
     | Ok (ledger, true) -> Ok (Some ledger))
;;

let load_existing_read_only_from_root ~ownership_root ~trace_id =
  let session_dir =
    Filename.concat ownership_root (Keeper_id.Trace_id.to_string trace_id)
  in
  replay_unlocked ~ownership_root ~trace_id (events_path session_dir)
;;

(* The header binds the workspace key of the canonical root the writer
   resolves under its lock, so an unlocked reader resolves the same root. *)
let load_existing ~config ~trace_id =
  let session_root =
    Filename.dirname
      (Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id))
  in
  match Unix.realpath session_root with
  | exception Unix.Unix_error (cause, _, _) ->
    Error (Canonical_root_failed { path = session_root; cause })
  | ownership_root -> load_existing_read_only_from_root ~ownership_root ~trace_id
;;

(* A write transaction. Every append goes through [commit_event_locked], which
   takes the writer of its transaction and marks it, so a write that may have
   changed the store is announced once its session lock is released
   (RFC-0483 §4.2). A write that only re-observes what is stored appends
   nothing and announces nothing. *)
type writer = { mutable appended : bool }

let no_commit_observer ~config:_ ~trace_id:_ = ()

let commit_observer : (config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> unit) Atomic.t =
  Atomic.make no_commit_observer

let install_commit_observer observer = Atomic.set commit_observer observer

let withdraw_commit_observer observer =
  ignore (Atomic.compare_and_set commit_observer observer no_commit_observer : bool)

let with_write_lock ~config ~trace_id operation =
  let writer = { appended = false } in
  (* The observer only records the trace, so it runs on a raise too: a row
     appended before the raise is on disk all the same. *)
  let announce () = if writer.appended then (Atomic.get commit_observer) ~config ~trace_id in
  match with_lock ~config ~trace_id (operation writer) with
  | result ->
    announce ();
    result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    announce ();
    Printexc.raise_with_backtrace exn backtrace
;;

(* Append [event] after the rows [log] was read to and keep the ledger it
   makes. The row is decoded before it is written, and the decoded event is
   the one applied: a replay reads every row this appends, so a row it could
   not read is never written, and what this process holds is what a replay
   builds. The header goes first when the store has none. A failed append
   leaves the store's end unknown to this process, so the next read replays
   it from the first byte. *)
let commit_event_locked (writer : writer) session_dir (log : session_log) event =
  let row = event_to_yojson event in
  let* ledger =
    (let* decoded = decode_event ~expected_trace_id:log.ledger.session_id row in
     let builder = builder_of_ledger log.ledger in
     let* () = apply_event builder decoded in
     Ok (ledger_of_builder builder))
    |> Result.map_error (fun error -> Decode_failed error)
  in
  let path = events_path session_dir in
  let header =
    if log.header_written
    then ""
    else
      event_row
        (header_to_yojson ~workspace_key:ledger.workspace_key ~session_id:ledger.session_id)
  in
  match
    cursor_result
      ~path
      (Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
         path
         ~expected:log.cursor
         (header ^ event_row row))
  with
  | Error error ->
    (* The row may be on disk; a reader told to read again loses one read. *)
    forget_session_log path;
    writer.appended <- true;
    Error (Event_log_failed error)
  | Ok cursor ->
    remember_session_log path { ledger; cursor; header_written = true };
    writer.appended <- true;
    Ok ledger
;;

type activation_clock = Exact_activation_clock | Original_activation_clock

let record_with_clock ~activation_clock ~config ~trace_id (activation : activation) =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* () =
      if
        String.equal
          (Ids.Turn_ref.trace_id activation.turn_ref)
          (Keeper_id.Trace_id.to_string trace_id)
      then Ok ()
      else Error (Decode_failed Turn_ref_session_mismatch)
    in
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    match List.find_opt (exact_key_equal activation) current.activations with
    | Some existing ->
      let expected = match activation_clock,activation.invocation with
        | Original_activation_clock,Nested_composition_invocation _ ->
          {activation with activated_at=existing.activated_at}
        | Exact_activation_clock,_
        | Original_activation_clock,(Instruction_invocation _ | Composition_invocation _) -> activation in
      if Yojson.Safe.equal (activation_to_yojson (recorded_part existing))
          (activation_to_yojson (recorded_part expected))
      then Ok (current, Already_recorded existing)
      else Error (Invocation_id_collision activation.skill_tool_use_id)
    | None ->
      let* stored =
        commit_event_locked writer session_dir log (Activation_recorded activation)
      in
      Ok (stored, Recorded activation))
;;

let record ~config ~trace_id activation =
  record_with_clock ~activation_clock:Exact_activation_clock ~config ~trace_id activation
;;

let record_original_invocation ~config ~trace_id activation =
  record_with_clock ~activation_clock:Original_activation_clock ~config ~trace_id activation
;;

(* The rejection is evidence in its own right: it is recorded, and the
   observation that produced it still fails. *)
let reject_transition_locked writer session_dir log rejection error =
  let* _stored = commit_event_locked writer session_dir log (Transition_rejected rejection) in
  Error error
;;

let observe_delivery
      ~config
      ~trace_id
      ~turn_ref
      ~tool_results
      ~boundary
      ~runtime_id
      ~delivered_at
  =
  let agent_core_turn = delivery_boundary_turn boundary in
  let receipt_valid (receipt : tool_result_receipt) =
    if String.equal (String.trim receipt.tool_use_id) ""
    then Error (Decode_failed Invalid_skill_tool_use_id)
    else if receipt.content_bytes < 0
    then Error (Decode_failed (Invalid_served_content_bytes receipt.content_bytes))
    else
      Skill_reference.validate_revision_string receipt.content_sha256
      |> Result.map_error (fun error ->
           Decode_failed (Invalid_served_content_sha256 error))
  in
  let* () =
    if String.equal (String.trim runtime_id) ""
    then Error (Decode_failed Invalid_runtime_id)
    else Ok ()
  in
  let* () =
    List.fold_left
      (fun result receipt ->
         let* () = result in
         receipt_valid receipt)
      (Ok ())
      tool_results
  in
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* () =
      Time_codec.parse_rfc3339 delivered_at
      |> Result.map ignore
      |> Result.map_error (fun _ -> Invalid_delivery_time delivered_at)
      |> Result.map_error (fun error -> Decode_failed error)
    in
    let* log =
      read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
    in
    let current = log.ledger in
    let matching_receipt (activation : activation) =
      if not (Ids.Turn_ref.equal activation.turn_ref turn_ref)
      then None
      else
        let result_tool_use_id = match activation.invocation with
          | Instruction_invocation _ | Composition_invocation _ -> activation.skill_tool_use_id
          | Nested_composition_invocation { scope; _ } -> scope.parent_tool_use_id in
        match
          List.find_opt
            (fun (receipt : tool_result_receipt) ->
               String.equal receipt.tool_use_id result_tool_use_id)
            tool_results
        with
        | None -> None
        | Some receipt ->
          (match activation.invocation with
           | Composition_invocation _ | Nested_composition_invocation _ -> Some receipt
           | Instruction_invocation { served_content; _ } ->
             let expected_bytes, expected_sha256 =
               match served_content with
               | Skill_body { bytes; sha256 }
               | Skill_resource { bytes; sha256; _ } -> bytes, sha256
             in
             if
               expected_bytes = receipt.content_bytes
               && String.equal expected_sha256 receipt.content_sha256
             then Some receipt
             else None)
    in
    let rejected =
      List.find_map
        (fun activation ->
           match matching_receipt activation with
           | None -> None
           | Some receipt ->
             if
             (match boundary with
              | Model_response _ -> agent_core_turn <= activation.agent_core_turn
              | Official_client_result_handoff _ ->
                agent_core_turn < activation.agent_core_turn)
             then
               Some
                 ( Delivery_order_rejected
                     { skill_tool_use_id = activation.skill_tool_use_id
                     ; activation_turn_ref = activation.turn_ref
                     ; observed_turn_ref = turn_ref
                     ; activation_agent_core_turn = activation.agent_core_turn
                     ; observed_agent_core_turn = agent_core_turn
                     ; observed_at = delivered_at
                     }
                 , Invalid_delivery_order
                     { skill_tool_use_id = activation.skill_tool_use_id
                     ; activation_turn = activation.agent_core_turn
                     ; delivery_turn = agent_core_turn
                     } )
             else
               match activation.delivery with
               | Some delivery
                 when not (delivery.boundary = boundary)
                      || not (String.equal delivery.runtime_id runtime_id)
                      || delivery.content_bytes <> receipt.content_bytes
                      || not
                           (String.equal
                              delivery.content_sha256
                              receipt.content_sha256) ->
                 Some
                   ( Delivery_conflict_rejected
                       { skill_tool_use_id = activation.skill_tool_use_id
                       ; activation_turn_ref = activation.turn_ref
                       ; observed_turn_ref = turn_ref
                       ; observed_agent_core_turn = agent_core_turn
                       ; observed_at = delivered_at
                       }
                   , Conflicting_delivery activation.skill_tool_use_id )
               | None | Some _ -> None)
        current.activations
    in
    match rejected with
    | Some (rejection, error) ->
      reject_transition_locked writer session_dir log rejection error
    | None ->
      (* The activations this request's results belong to, including ones
         already marked; the event carries only the deliveries not yet on
         the ledger. *)
      let matched, deliveries =
        List.fold_left
          (fun (matched, deliveries) activation ->
             match matching_receipt activation with
             | None -> matched, deliveries
             | Some receipt ->
               let matched = activation.skill_tool_use_id :: matched in
               (match activation.delivery with
                | Some _ -> matched, deliveries
                | None ->
                  ( matched
                  , ( activation.skill_tool_use_id
                    , { boundary
                      ; runtime_id
                      ; delivered_at
                      ; content_bytes = receipt.content_bytes
                      ; content_sha256 = receipt.content_sha256
                      } )
                    :: deliveries )))
          ([], [])
          current.activations
      in
      let matched = List.rev matched in
      (match List.rev deliveries with
       | [] -> Ok (current, matched)
       | deliveries ->
         let* stored =
           commit_event_locked writer session_dir log (Deliveries_observed deliveries)
         in
         Ok (stored, matched)))
;;

let observe_async_result_delivery ~config ~trace_id ~expected_activations (delivery : Keeper_skill_async_delivery.t) =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    let* () = validate_async_result ~expected_trace_id:trace_id ~activations:current.activations delivery
      |> Result.map_error (fun error -> Decode_failed error) in
    let ids = List.sort String.compare (List.map (fun (activation : activation) -> activation.skill_tool_use_id) expected_activations) in
    let* () = if ids = List.map (fun (child : Keeper_skill_async_delivery.child_activation) -> child.skill_tool_use_id) delivery.child_activations then Ok ()
      else Error (Decode_failed (Invalid_async_result_evidence "sealed child selection differs")) in
    let* () = List.fold_left (fun result (expected : activation) ->
      let* () = result in
      match List.find_opt (fun (known : activation) -> String.equal expected.skill_tool_use_id known.skill_tool_use_id) current.activations with
      | Some known when recorded_part known = recorded_part expected -> Ok ()
      | Some _ | None -> Error (Invocation_id_collision expected.skill_tool_use_id)) (Ok ()) expected_activations in
    match List.find_opt (fun known -> String.equal (Keeper_skill_async_delivery.identity known)
        (Keeper_skill_async_delivery.identity delivery)) current.async_result_deliveries with
    | Some known -> Ok (current,known)
    | None -> commit_event_locked writer session_dir log (Async_result_delivered delivery)
      |> Result.map (fun ledger -> ledger,delivery))
;;

let observe_async_action ~config ~trace_id action =
  with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
    let* log = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    let current = log.ledger in
    let* () = validate_async_action ~expected_trace_id:trace_id ~activations:current.activations
      ~async_result_deliveries:current.async_result_deliveries ~async_actions:current.async_actions action
      |> Result.map_error (fun error -> Decode_failed error) in
    match List.find_opt (fun known -> String.equal (Keeper_skill_async_action.identity known)
        (Keeper_skill_async_action.identity action)) current.async_actions with
    | Some known when Keeper_skill_async_action.same_fact known action -> Ok (current,known)
    | Some _ -> Error (Decode_failed (Invalid_async_action_evidence "causal occurrence result differs"))
    | None -> commit_event_locked writer session_dir log (Async_action_observed action)
      |> Result.map (fun ledger -> ledger,action))
;;

let observe_action
      ~config
      ~trace_id
      ~turn_ref
      ~active_skill_tool_use_ids
      ~action_identity
      ~tool_name
      ~runtime_id
      ~agent_core_turn
      ~observed_at
  =
  if not (action_identity_valid action_identity)
  then Error Invalid_action_identity
  else if not (Safe_identifier.is_portable_name tool_name)
  then Error (Invalid_action_tool_name tool_name)
  else if String.equal (String.trim runtime_id) ""
  then Error (Decode_failed Invalid_runtime_id)
  else if agent_core_turn < 0
  then Error (Invalid_action_turn agent_core_turn)
  else
    match Time_codec.parse_rfc3339 observed_at with
    | Error _ -> Error (Invalid_action_observed_at observed_at)
    | Ok _ ->
      with_write_lock ~config ~trace_id (fun writer ~ownership_root session_dir ->
        let* log =
          read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
        in
        let current = log.ledger in
        let active = List.sort_uniq String.compare active_skill_tool_use_ids in
        let action =
          { identity = action_identity
          ; tool_name
          ; runtime_id
          ; agent_core_turn
          ; observed_at
          }
        in
        let rejected =
          List.find_map
            (fun activation ->
               if not (List.mem activation.skill_tool_use_id active)
               then None
               else
                 let before_delivery =
                   not (Ids.Turn_ref.equal activation.turn_ref turn_ref)
                   || Option.is_none activation.delivery
                   || Option.exists
                        (fun (delivery : delivery) ->
                           agent_core_turn
                           < delivery_boundary_turn delivery.boundary)
                        activation.delivery
                 in
                 if before_delivery
                 then
                   Some
                     ( Action_before_delivery_rejected
                         { skill_tool_use_id = activation.skill_tool_use_id
                         ; activation_turn_ref = activation.turn_ref
                         ; observed_turn_ref = turn_ref
                         ; action_identity
                         ; tool_name
                         ; observed_agent_core_turn = agent_core_turn
                         ; observed_at
                         }
                     , Action_before_delivery activation.skill_tool_use_id )
                 else None)
            current.activations
        in
        match rejected with
        | Some (rejection, error) ->
          reject_transition_locked writer session_dir log rejection error
        | None ->
          (* Every active Skill that has been delivered and has not seen
             this action yet; the same identity already recorded with other
             fields is a collision. *)
          let* targets =
            List.fold_left
              (fun result (activation : activation) ->
                 let* targets = result in
                 if not (List.mem activation.skill_tool_use_id active)
                 then Ok targets
                 else
                   match activation.delivery with
                   | None -> Ok targets
                   | Some _ ->
                     (match
                        List.find_opt
                          (fun (known : action) -> known.identity = action_identity)
                          activation.actions
                      with
                      | Some known
                        when String.equal known.tool_name action.tool_name
                             && String.equal known.runtime_id action.runtime_id
                             && known.agent_core_turn = action.agent_core_turn ->
                        Ok targets
                      | Some _ -> Error (Action_identity_collision action_identity)
                      | None -> Ok (activation.skill_tool_use_id :: targets)))
              (Ok [])
              current.activations
          in
          (match List.rev targets with
           | [] -> Ok (current, 0)
           | skill_tool_use_ids ->
             let* stored =
               commit_event_locked
                 writer
                 session_dir
                 log
                 (Action_observed { skill_tool_use_ids; action })
             in
             Ok (stored, List.length skill_tool_use_ids)))
;;
