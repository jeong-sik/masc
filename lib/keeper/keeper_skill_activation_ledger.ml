open Result.Syntax

include Keeper_skill_activation_types

type ledger_revision = string
type workspace_key = string

(* The revision is the SHA-256 of the whole canonical ledger, so computing it
   costs a serialisation of every activation. A mutation does not need it --
   only a reader that projects or verifies the ledger does -- so it is computed
   on the first read and kept with the value. The fields it covers are
   immutable, so two readers that race to fill it write the same string. *)
type t =
  { workspace_key : workspace_key
  ; session_id : Keeper_id.Trace_id.t
  ; activations : activation list
  ; transition_rejections : transition_rejection list
  ; mutable revision_memo : ledger_revision option
  }

type record_outcome =
  | Recorded of activation
  | Already_recorded of activation

type decode_error =
  | Expected_object of { field : string }
  | Missing_string of { field : string }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Unsupported_schema of string
  | Invalid_source_id of string
  | Invalid_skill_name of string
  | Invalid_package_id of Skill_reference.package_id_error
  | Invalid_content_revision of Skill_reference.revision_error
  | Invalid_snapshot_revision of Skill_catalog_snapshot.revision_error
  | Invalid_workspace_key of Skill_catalog_snapshot.revision_error
  | Invalid_session_id of string
  | Invalid_origin_kind of string
  | Invalid_task_id of string
  | Empty_task_ids
  | Duplicate_task_id of string
  | Invalid_tool_name of string
  | Invalid_turn_ref of string
  | Turn_ref_session_mismatch
  | Invalid_runtime_id
  | Invalid_skill_tool_use_id
  | Invalid_agent_core_turn of int
  | Invalid_served_content_kind of string
  | Invalid_served_content_path of string
  | Invalid_served_content_bytes of int
  | Invalid_served_content_sha256 of Skill_reference.revision_error
  | Invalid_delivery_agent_core_turn of int
  | Invalid_delivery_boundary_kind of string
  | Invalid_delivery_time of string
  | Invalid_action_identity_field
  | Invalid_action_tool_name_field of string
  | Invalid_action_agent_core_turn of int
  | Invalid_action_time of string
  | Invalid_transition_rejection_kind of string
  | Orphan_transition_rejection of string
  | Transition_rejection_activation_mismatch of string
  | Duplicate_action_identity
  | Invalid_activated_at of string
  | Duplicate_skill_tool_use_id
  | Session_id_mismatch
  | Workspace_key_mismatch
  | Invalid_ledger_revision of Skill_catalog_snapshot.revision_error
  | Ledger_revision_mismatch
  | Invalid_event_kind of string
  | Blank_event_row
  | Activation_recorded_with_evidence of string
  | Unknown_event_activation of string
  | Delivery_already_observed of string
  | Action_target_not_delivered of string
  | Unterminated_header_row

type store_error =
  | Lock_failed of string
  | Canonical_root_failed of
      { path : string
      ; cause : Unix.error
      }
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Decode_failed of decode_error
  | Invocation_id_collision of string
  | Action_identity_collision of action_identity
  | Invalid_delivery_order of
      { skill_tool_use_id : string
      ; activation_turn : int
      ; delivery_turn : int
      }
  | Conflicting_delivery of string
  | Action_before_delivery of string
  | Invalid_action_identity
  | Invalid_action_tool_name of string
  | Invalid_action_turn of int
  | Invalid_action_observed_at of string
  | Event_log_failed of Fs_compat.private_jsonl_transaction_error

let decode_error_code = function
  | Expected_object _ -> "expected_object"
  | Missing_string _ -> "missing_string"
  | Duplicate_field _ -> "duplicate_field"
  | Unexpected_field _ -> "unexpected_field"
  | Unsupported_schema _ -> "unsupported_schema"
  | Invalid_source_id _ -> "invalid_source_id"
  | Invalid_skill_name _ -> "invalid_skill_name"
  | Invalid_package_id _ -> "invalid_package_id"
  | Invalid_content_revision _ -> "invalid_content_revision"
  | Invalid_snapshot_revision _ -> "invalid_snapshot_revision"
  | Invalid_workspace_key _ -> "invalid_workspace_key"
  | Invalid_session_id _ -> "invalid_session_id"
  | Invalid_origin_kind _ -> "invalid_origin_kind"
  | Invalid_task_id _ -> "invalid_task_id"
  | Empty_task_ids -> "empty_task_ids"
  | Duplicate_task_id _ -> "duplicate_task_id"
  | Invalid_tool_name _ -> "invalid_tool_name"
  | Invalid_turn_ref _ -> "invalid_turn_ref"
  | Turn_ref_session_mismatch -> "turn_ref_session_mismatch"
  | Invalid_runtime_id -> "invalid_runtime_id"
  | Invalid_skill_tool_use_id -> "invalid_skill_tool_use_id"
  | Invalid_agent_core_turn _ -> "invalid_agent_core_turn"
  | Invalid_served_content_kind _ -> "invalid_served_content_kind"
  | Invalid_served_content_path _ -> "invalid_served_content_path"
  | Invalid_served_content_bytes _ -> "invalid_served_content_bytes"
  | Invalid_served_content_sha256 _ -> "invalid_served_content_sha256"
  | Invalid_delivery_agent_core_turn _ -> "invalid_delivery_agent_core_turn"
  | Invalid_delivery_boundary_kind _ -> "invalid_delivery_boundary_kind"
  | Invalid_delivery_time _ -> "invalid_delivery_time"
  | Invalid_action_identity_field -> "invalid_action_identity"
  | Invalid_action_tool_name_field _ -> "invalid_action_tool_name"
  | Invalid_action_agent_core_turn _ -> "invalid_action_agent_core_turn"
  | Invalid_action_time _ -> "invalid_action_time"
  | Invalid_transition_rejection_kind _ -> "invalid_transition_rejection_kind"
  | Orphan_transition_rejection _ -> "orphan_transition_rejection"
  | Transition_rejection_activation_mismatch _ ->
    "transition_rejection_activation_mismatch"
  | Duplicate_action_identity -> "duplicate_action_identity"
  | Invalid_activated_at _ -> "invalid_activated_at"
  | Duplicate_skill_tool_use_id -> "duplicate_skill_tool_use_id"
  | Session_id_mismatch -> "session_id_mismatch"
  | Workspace_key_mismatch -> "workspace_key_mismatch"
  | Invalid_ledger_revision _ -> "invalid_ledger_revision"
  | Ledger_revision_mismatch -> "ledger_revision_mismatch"
  | Invalid_event_kind _ -> "invalid_event_kind"
  | Blank_event_row -> "blank_event_row"
  | Activation_recorded_with_evidence _ -> "activation_recorded_with_evidence"
  | Unknown_event_activation _ -> "unknown_event_activation"
  | Delivery_already_observed _ -> "delivery_already_observed"
  | Action_target_not_delivered _ -> "action_target_not_delivered"
  | Unterminated_header_row -> "unterminated_header_row"
;;

let store_error_code = function
  | Lock_failed _ -> "lock_failed"
  | Canonical_root_failed _ -> "canonical_root_failed"
  | Read_failed _ -> "read_failed"
  | Decode_failed error -> "decode_failed." ^ decode_error_code error
  | Invocation_id_collision _ -> "invocation_id_collision"
  | Action_identity_collision _ -> "action_identity_collision"
  | Invalid_delivery_order _ -> "invalid_delivery_order"
  | Conflicting_delivery _ -> "conflicting_delivery"
  | Action_before_delivery _ -> "action_before_delivery"
  | Invalid_action_identity -> "invalid_action_identity"
  | Invalid_action_tool_name _ -> "invalid_action_tool_name"
  | Invalid_action_turn _ -> "invalid_action_turn"
  | Invalid_action_observed_at _ -> "invalid_action_observed_at"
  | Event_log_failed _ -> "event_log_failed"
;;

let store_error_to_string = function
  | Lock_failed detail -> "lock failed: " ^ detail
  | Canonical_root_failed { path; cause } ->
    Printf.sprintf
      "canonical trace root failed for %s: %s"
      path
      (Unix.error_message cause)
  | Read_failed error ->
    "read failed: " ^ Fs_compat.owned_regular_file_read_error_to_string error
  (* Keep the category in the human string too: a write reads the session's
     rows before it appends, so one undecodable row fails every later write
     for the session — the code is what identifies the poison row's shape. *)
  | Decode_failed error -> "decode failed: " ^ decode_error_code error
  | Invocation_id_collision tool_use_id ->
    "Skill invocation id collision: " ^ tool_use_id
  | Action_identity_collision _ -> "Skill action identity collision"
  | Invalid_delivery_order { skill_tool_use_id; activation_turn; delivery_turn } ->
    Printf.sprintf
      "Skill delivery precedes its activation: id=%s activation_turn=%d delivery_turn=%d"
      skill_tool_use_id
      activation_turn
      delivery_turn
  | Conflicting_delivery tool_use_id ->
    "Skill delivery observation conflicts with its durable receipt: " ^ tool_use_id
  | Action_before_delivery tool_use_id ->
    "Skill action was observed before body delivery: " ^ tool_use_id
  | Invalid_action_identity -> "Skill action identity is invalid"
  | Invalid_action_tool_name tool_name ->
    "Skill action tool name is invalid: " ^ tool_name
  | Invalid_action_turn turn ->
    Printf.sprintf "Skill action Agent Core turn is invalid: %d" turn
  | Invalid_action_observed_at value ->
    "Skill action observation time is invalid: " ^ value
  | Event_log_failed error ->
    "event log failed: " ^ Fs_compat.private_jsonl_transaction_error_to_string error
;;

let schema = "masc.skill-activations/v5"
let activations ledger = ledger.activations
let transition_rejections ledger = ledger.transition_rejections
let ledger_revision_to_string revision = revision
let workspace_key ledger = ledger.workspace_key
let session_id ledger = ledger.session_id

let task_id_set_to_list (Task_ids { first; rest }) = first :: rest

let task_id_set_of_list task_ids =
  let rec duplicate = function
    | [] -> None
    | task_id :: rest ->
      if List.exists (Keeper_id.Task_id.equal task_id) rest
      then Some task_id
      else duplicate rest
  in
  match task_ids with
  | [] -> Error Empty_task_ids
  | first :: rest ->
    (match duplicate task_ids with
     | None -> Ok (Task_ids { first; rest })
     | Some task_id ->
       Error (Duplicate_task_id (Keeper_id.Task_id.to_string task_id)))
;;

let summarize ledger =
  Keeper_skill_activation_summary.summarize
    ~activations:ledger.activations
    ~transition_rejections:ledger.transition_rejections
;;

let summarize_by_scope ledger =
  Keeper_skill_activation_summary.summarize_by_scope
    ~activations:ledger.activations
    ~transition_rejections:ledger.transition_rejections
;;

let summary_to_yojson = Keeper_skill_activation_summary.summary_to_yojson
let scoped_summary_to_yojson = Keeper_skill_activation_summary.scoped_summary_to_yojson

let rejection_activation_turn_ref = function
  | Delivery_order_rejected { activation_turn_ref; _ }
  | Delivery_conflict_rejected { activation_turn_ref; _ }
  | Action_before_delivery_rejected { activation_turn_ref; _ } ->
    activation_turn_ref
;;

let validate_served_content = function
  | Skill_body { bytes; sha256 } ->
    if bytes < 0
    then Error (Invalid_served_content_bytes bytes)
    else
      Skill_reference.validate_revision_string sha256
      |> Result.map_error (fun error -> Invalid_served_content_sha256 error)
  | Skill_resource { relative_path; bytes; sha256 } ->
    let* () =
      Skill_resource_path.of_string relative_path
      |> Result.map ignore
      |> Result.map_error (fun _ -> Invalid_served_content_path relative_path)
    in
    if bytes < 0
    then Error (Invalid_served_content_bytes bytes)
    else
      Skill_reference.validate_revision_string sha256
      |> Result.map_error (fun error -> Invalid_served_content_sha256 error)
;;

let make_activation_evidence
      ~(identity : Skill_reference.identity)
      ~content_revision
      ~snapshot_revision
      ~turn_ref
      ~runtime_id
      ~skill_tool_use_id
      ~agent_core_turn
      ~invocation
      ~activated_at
  =
  let trace_id = Ids.Turn_ref.trace_id turn_ref in
  let* canonical_name =
    Agent_core.Skill_document.canonical_name identity.name
    |> Result.map_error (fun _ -> Invalid_skill_name identity.name)
  in
  let* () =
    if String.equal canonical_name identity.name
    then Ok ()
    else Error (Invalid_skill_name identity.name)
  in
  let invocation_valid =
    match invocation with
    | Instruction_invocation { served_content; _ } ->
      validate_served_content served_content
    | Composition_invocation { tool_name; _ } ->
      if Safe_identifier.is_portable_name tool_name
      then Ok ()
      else Error (Invalid_tool_name tool_name)
  in
  let* () = invocation_valid in
  let* () =
    if String.equal (String.trim runtime_id) ""
    then Error Invalid_runtime_id
    else Ok ()
  in
  let* () =
    if String.equal (String.trim skill_tool_use_id) ""
    then Error Invalid_skill_tool_use_id
    else Ok ()
  in
  let* () =
    if agent_core_turn < 0
    then Error (Invalid_agent_core_turn agent_core_turn)
    else Ok ()
  in
  let* () =
    if String.equal trace_id "" || Ids.Turn_ref.absolute_turn turn_ref <= 0
    then Error (Invalid_turn_ref (Ids.Turn_ref.to_string turn_ref))
    else Ok ()
  in
  let* () =
    Time_codec.parse_rfc3339 activated_at
    |> Result.map ignore
    |> Result.map_error (fun _ -> Invalid_activated_at activated_at)
  in
  Ok
    { identity
    ; content_revision
    ; snapshot_revision
    ; turn_ref
    ; runtime_id
    ; skill_tool_use_id
    ; agent_core_turn
    ; invocation
    ; delivery = None
    ; actions = []
    ; activated_at
    }
;;

let make_activation
      ~identity
      ~content_revision
      ~snapshot_revision
      ~turn_ref
      ~runtime_id
      ~skill_tool_use_id
      ~agent_core_turn
      ~invocation
      ~activated_at
  =
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
;;

let task_id_set_to_yojson task_ids =
  `List
    (List.map
       (fun task_id -> `String (Keeper_id.Task_id.to_string task_id))
       (task_id_set_to_list task_ids))
;;

let instruction_origin_to_yojson = function
  | Task_instruction { task_ids } ->
    `Assoc
      [ "kind", `String "task_instruction"
      ; "task_ids", task_id_set_to_yojson task_ids
      ]
  | Session_instruction -> `Assoc [ "kind", `String "session_instruction" ]
;;

let composition_origin_to_yojson = function
  | Task_composition { task_ids } ->
    `Assoc
      [ "kind", `String "task_composition"
      ; "task_ids", task_id_set_to_yojson task_ids
      ]
  | Session_composition -> `Assoc [ "kind", `String "session_composition" ]
;;

let delivery_boundary_to_yojson = function
  | Model_response { agent_core_turn } ->
    `Assoc
      [ "kind", `String "model_response"
      ; "agent_core_turn", `Int agent_core_turn
      ]
  | Official_client_result_handoff { agent_core_turn } ->
    `Assoc
      [ "kind", `String "official_client_result_handoff"
      ; "agent_core_turn", `Int agent_core_turn
      ]
;;

let delivery_to_yojson (delivery : delivery) =
  `Assoc
    [ "boundary", delivery_boundary_to_yojson delivery.boundary
    ; "runtime_id", `String delivery.runtime_id
    ; "delivered_at", `String delivery.delivered_at
    ; "content_bytes", `Int delivery.content_bytes
    ; "content_sha256", `String delivery.content_sha256
    ]
;;

let action_identity_valid = function
  | Call_id call_id -> String.trim call_id <> ""
  | Provider_step { conversation_id; step_index } ->
    String.trim conversation_id <> "" && step_index >= 0
;;

let action_identity_to_yojson = function
  | Call_id call_id ->
    `Assoc [ "kind", `String "call_id"; "call_id", `String call_id ]
  | Provider_step { conversation_id; step_index } ->
    `Assoc
      [ "kind", `String "provider_step"
      ; "conversation_id", `String conversation_id
      ; "step_index", `Int step_index
      ]
;;

let action_to_yojson (action : action) =
  `Assoc
    [ "identity", action_identity_to_yojson action.identity
    ; "tool_name", `String action.tool_name
    ; "runtime_id", `String action.runtime_id
    ; "agent_core_turn", `Int action.agent_core_turn
    ; "observed_at", `String action.observed_at
    ]
;;

let served_content_to_yojson = function
  | Skill_body { bytes; sha256 } ->
    `Assoc
      [ "kind", `String "skill_body"
      ; "bytes", `Int bytes
      ; "sha256", `String sha256
      ]
  | Skill_resource { relative_path; bytes; sha256 } ->
    `Assoc
      [ "kind", `String "skill_resource"
      ; "relative_path", `String relative_path
      ; "bytes", `Int bytes
      ; "sha256", `String sha256
      ]
;;

let invocation_to_yojson = function
  | Instruction_invocation { origin; served_content } ->
    `Assoc
      [ "kind", `String "instruction"
      ; "origin", instruction_origin_to_yojson origin
      ; "served_content", served_content_to_yojson served_content
      ]
  | Composition_invocation { origin; tool_name } ->
    `Assoc
      [ "kind", `String "composition"
      ; "origin", composition_origin_to_yojson origin
      ; "tool_name", `String tool_name
      ]
;;

let transition_rejection_to_yojson = function
  | Delivery_order_rejected
      { skill_tool_use_id
      ; activation_turn_ref
      ; observed_turn_ref
      ; activation_agent_core_turn
      ; observed_agent_core_turn
      ; observed_at
      } ->
    `Assoc
      [ "kind", `String "delivery_order"
      ; "skill_tool_use_id", `String skill_tool_use_id
      ; "activation_turn_ref", Ids.Turn_ref.to_yojson activation_turn_ref
      ; "observed_turn_ref", Ids.Turn_ref.to_yojson observed_turn_ref
      ; "activation_agent_core_turn", `Int activation_agent_core_turn
      ; "observed_agent_core_turn", `Int observed_agent_core_turn
      ; "observed_at", `String observed_at
      ]
  | Delivery_conflict_rejected
      { skill_tool_use_id
      ; activation_turn_ref
      ; observed_turn_ref
      ; observed_agent_core_turn
      ; observed_at
      } ->
    `Assoc
      [ "kind", `String "delivery_conflict"
      ; "skill_tool_use_id", `String skill_tool_use_id
      ; "activation_turn_ref", Ids.Turn_ref.to_yojson activation_turn_ref
      ; "observed_turn_ref", Ids.Turn_ref.to_yojson observed_turn_ref
      ; "observed_agent_core_turn", `Int observed_agent_core_turn
      ; "observed_at", `String observed_at
      ]
  | Action_before_delivery_rejected
      { skill_tool_use_id
      ; activation_turn_ref
      ; observed_turn_ref
      ; action_identity
      ; tool_name
      ; observed_agent_core_turn
      ; observed_at
      } ->
    `Assoc
      [ "kind", `String "action_before_delivery"
      ; "skill_tool_use_id", `String skill_tool_use_id
      ; "activation_turn_ref", Ids.Turn_ref.to_yojson activation_turn_ref
      ; "observed_turn_ref", Ids.Turn_ref.to_yojson observed_turn_ref
      ; "action_identity", action_identity_to_yojson action_identity
      ; "tool_name", `String tool_name
      ; "observed_agent_core_turn", `Int observed_agent_core_turn
      ; "observed_at", `String observed_at
      ]
;;

let activation_to_yojson activation =
  `Assoc
    [ "identity", Skill_reference.identity_to_yojson activation.identity
    ; ( "content_revision"
      , `String
          (Skill_reference.content_revision_to_string activation.content_revision) )
    ; ( "snapshot_revision"
      , `String
          (Skill_catalog_snapshot.snapshot_revision_to_string
             activation.snapshot_revision) )
    ; "turn_ref", Ids.Turn_ref.to_yojson activation.turn_ref
    ; "runtime_id", `String activation.runtime_id
    ; "skill_tool_use_id", `String activation.skill_tool_use_id
    ; "agent_core_turn", `Int activation.agent_core_turn
    ; "invocation", invocation_to_yojson activation.invocation
    ; ( "delivery"
      , match activation.delivery with
        | Some delivery -> delivery_to_yojson delivery
        | None -> `Null )
    ; "actions", `List (List.map action_to_yojson activation.actions)
    ; "activated_at", `String activation.activated_at
    ]
;;

let workspace_key_of_root root =
  Digestif.SHA256.(digest_string root |> to_hex)
;;

let revision_of_ledger ~workspace_key ~session_id ~activations ~transition_rejections =
  let canonical =
    `Assoc
      [ "workspace_key", `String workspace_key
      ; "session_id", `String (Keeper_id.Trace_id.to_string session_id)
      ; "activations", `List (List.map activation_to_yojson activations)
      ; ( "transition_rejections"
        , `List (List.map transition_rejection_to_yojson transition_rejections) )
      ]
  in
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string canonical) |> to_hex)
;;

let make ~workspace_key ~session_id ~activations ~transition_rejections =
  { workspace_key; session_id; activations; transition_rejections; revision_memo = None }
;;

let revision ledger =
  match ledger.revision_memo with
  | Some revision -> revision
  | None ->
    let revision =
      revision_of_ledger
        ~workspace_key:ledger.workspace_key
        ~session_id:ledger.session_id
        ~activations:ledger.activations
        ~transition_rejections:ledger.transition_rejections
    in
    ledger.revision_memo <- Some revision;
    revision
;;

let receipt_projection_revision ledger ~skill_tool_use_id =
  let buffer = Buffer.create 160 in
  let add field value =
    Buffer.add_string buffer (string_of_int (String.length field));
    Buffer.add_char buffer ':';
    Buffer.add_string buffer field;
    Buffer.add_string buffer (string_of_int (String.length value));
    Buffer.add_char buffer ':';
    Buffer.add_string buffer value
  in
  add "ledger_revision" (revision ledger);
  add "skill_tool_use_id" skill_tool_use_id;
  Digestif.SHA256.(digest_string (Buffer.contents buffer) |> to_hex)
;;

let empty ~workspace_root ~trace_id =
  make
    ~workspace_key:(workspace_key_of_root workspace_root)
    ~session_id:trace_id
    ~activations:[]
    ~transition_rejections:[]
;;

let to_yojson ledger =
  `Assoc
    [ "schema", `String schema
    ; "workspace_key", `String ledger.workspace_key
    ; "session_id", `String (Keeper_id.Trace_id.to_string ledger.session_id)
    ; "revision", `String (revision ledger)
    ; "activations", `List (List.map activation_to_yojson ledger.activations)
    ; ( "transition_rejections"
      , `List
          (List.map transition_rejection_to_yojson ledger.transition_rejections) )
    ]
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
        ~allowed:[ "kind"; "origin"; "tool_name" ]
        fields
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
    then Ok (Composition_invocation { origin; tool_name })
    else Error (Invalid_tool_name tool_name)
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
  let ledger =
    make
      ~workspace_key
      ~session_id
      ~activations
      ~transition_rejections
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
   session lock takes only the rows written after that cursor. *)

let events_schema = "masc.skill-activation-events/v1"
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
  }
;;

let ledger_of_builder builder =
  make
    ~workspace_key:builder.builder_workspace_key
    ~session_id:builder.builder_session_id
    ~activations:(List.rev_map (fun cell -> !cell) builder.cells_newest_first)
    ~transition_rejections:(List.rev builder.rejections_newest_first)
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
  let* () =
    List.fold_left
      (fun result row ->
         let* () = result in
         let* json = parse_row row in
         let* event = decode_event ~expected_trace_id json in
         apply_event builder event)
      (Ok ())
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
    | Error error -> Error (Event_log_failed error)
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
     | Error error ->
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

(* Append [event] after the rows [log] was read to and keep the ledger it
   makes. The row is decoded before it is written, and the decoded event is
   the one applied: a replay reads every row this appends, so a row it could
   not read is never written, and what this process holds is what a replay
   builds. The header goes first when the store has none. A failed append
   leaves the store's end unknown to this process, so the next read replays
   it from the first byte. *)
let commit_event_locked session_dir (log : session_log) event =
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
    forget_session_log path;
    Error (Event_log_failed error)
  | Ok cursor ->
    remember_session_log path { ledger; cursor; header_written = true };
    Ok ledger
;;

(* What an activation records when it is made. Its delivery and actions
   arrive later, by their own events, so whether a repeated recording is the
   same invocation is judged on this part alone. *)
let recorded_part (activation : activation) =
  { activation with delivery = None; actions = [] }
;;

let record ~config ~trace_id (activation : activation) =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
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
    | Some existing
      when Yojson.Safe.equal
             (activation_to_yojson (recorded_part existing))
             (activation_to_yojson (recorded_part activation)) ->
      Ok (current, Already_recorded existing)
    | Some _ -> Error (Invocation_id_collision activation.skill_tool_use_id)
    | None ->
      let* stored =
        commit_event_locked session_dir log (Activation_recorded activation)
      in
      Ok (stored, Recorded activation))
;;

(* The rejection is evidence in its own right: it is recorded, and the
   observation that produced it still fails. *)
let reject_transition_locked session_dir log rejection error =
  let* _stored = commit_event_locked session_dir log (Transition_rejected rejection) in
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
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
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
        match
          List.find_opt
            (fun (receipt : tool_result_receipt) ->
               String.equal receipt.tool_use_id activation.skill_tool_use_id)
            tool_results
        with
        | None -> None
        | Some receipt ->
          (match activation.invocation with
           | Composition_invocation _ -> Some receipt
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
      reject_transition_locked session_dir log rejection error
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
           commit_event_locked session_dir log (Deliveries_observed deliveries)
         in
         Ok (stored, matched)))
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
      with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
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
          reject_transition_locked session_dir log rejection error
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
                 session_dir
                 log
                 (Action_observed { skill_tool_use_ids; action })
             in
             Ok (stored, List.length skill_tool_use_ids)))
;;
