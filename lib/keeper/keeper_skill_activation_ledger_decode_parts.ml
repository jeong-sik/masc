open Result.Syntax
open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model

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
