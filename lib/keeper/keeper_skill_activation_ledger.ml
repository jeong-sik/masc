open Result.Syntax

type ledger_revision = string
type workspace_key = string

type task_id_set =
  | Task_ids of
      { first : Keeper_id.Task_id.t
      ; rest : Keeper_id.Task_id.t list
      }

type instruction_origin =
  | Task_instruction of { task_ids : task_id_set }
  | Session_instruction

type composition_origin =
  | Task_composition of
      { task_ids : task_id_set }
  | Session_composition

type delivery_boundary =
  | Model_response of { agent_core_turn : int }
  | Official_client_result_handoff of { agent_core_turn : int }

type delivery =
  { boundary : delivery_boundary
  ; runtime_id : string
  ; delivered_at : string
  ; content_bytes : int
  ; content_sha256 : string
  }

type tool_result_receipt =
  { tool_use_id : string
  ; content_bytes : int
  ; content_sha256 : string
  }

type action_identity = Runtime_native_tools.action_identity =
  | Call_id of string
  | Provider_step of
      { conversation_id : string
      ; step_index : int
      }

type action =
  { identity : action_identity
  ; tool_name : string
  ; runtime_id : string
  ; agent_core_turn : int
  ; observed_at : string
  }

type served_content =
  | Skill_body of
      { bytes : int
      ; sha256 : string
      }
  | Skill_resource of
      { relative_path : string
      ; bytes : int
      ; sha256 : string
      }

type invocation =
  | Instruction_invocation of
      { origin : instruction_origin
      ; served_content : served_content
      }
  | Composition_invocation of
      { origin : composition_origin
      ; tool_name : string
      }

type transition_rejection =
  | Delivery_order_rejected of
      { skill_tool_use_id : string
      ; activation_turn_ref : Ids.Turn_ref.t
      ; observed_turn_ref : Ids.Turn_ref.t
      ; activation_agent_core_turn : int
      ; observed_agent_core_turn : int
      ; observed_at : string
      }
  | Delivery_conflict_rejected of
      { skill_tool_use_id : string
      ; activation_turn_ref : Ids.Turn_ref.t
      ; observed_turn_ref : Ids.Turn_ref.t
      ; observed_agent_core_turn : int
      ; observed_at : string
      }
  | Action_before_delivery_rejected of
      { skill_tool_use_id : string
      ; activation_turn_ref : Ids.Turn_ref.t
      ; observed_turn_ref : Ids.Turn_ref.t
      ; action_identity : action_identity
      ; tool_name : string
      ; observed_agent_core_turn : int
      ; observed_at : string
      }

type activation =
  { identity : Skill_reference.identity
  ; content_revision : Skill_reference.content_revision
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; skill_tool_use_id : string
  ; agent_core_turn : int
  ; invocation : invocation
  ; delivery : delivery option
  ; actions : action list
  ; activated_at : string
  }

type t =
  { workspace_key : workspace_key
  ; session_id : Keeper_id.Trace_id.t
  ; activations : activation list
  ; transition_rejections : transition_rejection list
  ; revision : ledger_revision
  }

type summary =
  { instruction_invocations : int
  ; skill_bodies_served : int
  ; skill_resources_served : int
  ; instruction_provider_deliveries : int
  ; instruction_official_client_handoffs : int
  ; instruction_actions_observed : int
  ; composition_invocations : int
  ; composition_provider_deliveries : int
  ; composition_official_client_handoffs : int
  ; composition_actions_observed : int
  ; invalid_transitions : int
  }

type summary_scope =
  { snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; turn_ref : Ids.Turn_ref.t
  ; invocation_runtime_id : string
  ; reference : Skill_reference.t
  }

type runtime_count =
  { runtime_id : string
  ; count : int
  }

type scoped_summary =
  { scope : summary_scope
  ; summary : summary
  ; provider_delivery_runtime_counts : runtime_count list
  ; official_client_handoff_runtime_counts : runtime_count list
  ; action_runtime_counts : runtime_count list
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

type store_error =
  | Lock_failed of string
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
  | Write_failed of Keeper_fs.durable_write_error
  | Readback_mismatch

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
;;

let store_error_code = function
  | Lock_failed _ -> "lock_failed"
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
  | Write_failed _ -> "write_failed"
  | Readback_mismatch -> "readback_mismatch"
;;

let store_error_to_string = function
  | Lock_failed detail -> "lock failed: " ^ detail
  | Read_failed error ->
    "read failed: " ^ Fs_compat.owned_regular_file_read_error_to_string error
  | Decode_failed _ -> "decode failed"
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
  | Write_failed error ->
    "write failed: " ^ Keeper_fs.durable_write_error_to_string error
  | Readback_mismatch -> "readback mismatch"
;;

let schema = "masc.skill-activations/v5"
let filename = "skill-activations.json"
let activations ledger = ledger.activations
let transition_rejections ledger = ledger.transition_rejections
let revision ledger = ledger.revision
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

let empty_summary invalid_transitions =
  { instruction_invocations = 0
  ; skill_bodies_served = 0
  ; skill_resources_served = 0
  ; instruction_provider_deliveries = 0
  ; instruction_official_client_handoffs = 0
  ; instruction_actions_observed = 0
  ; composition_invocations = 0
  ; composition_provider_deliveries = 0
  ; composition_official_client_handoffs = 0
  ; composition_actions_observed = 0
  ; invalid_transitions
  }
;;

let summarize ledger =
  List.fold_left
    (fun summary activation ->
       let provider_delivered, official_client_handoff =
         match activation.delivery with
         | Some { boundary = Model_response _; _ } -> 1, 0
         | Some { boundary = Official_client_result_handoff _; _ } -> 0, 1
         | None -> 0, 0
       in
       let actions = List.length activation.actions in
       match activation.invocation with
       | Instruction_invocation { served_content; _ } ->
         let skill_bodies_served, skill_resources_served =
           match served_content with
           | Skill_body _ -> summary.skill_bodies_served + 1, summary.skill_resources_served
           | Skill_resource _ ->
             summary.skill_bodies_served, summary.skill_resources_served + 1
         in
         { summary with
           instruction_invocations = summary.instruction_invocations + 1
         ; skill_bodies_served
         ; skill_resources_served
         ; instruction_provider_deliveries =
             summary.instruction_provider_deliveries + provider_delivered
         ; instruction_official_client_handoffs =
             summary.instruction_official_client_handoffs
             + official_client_handoff
         ; instruction_actions_observed =
             summary.instruction_actions_observed + actions
         }
       | Composition_invocation _ ->
         { summary with
           composition_invocations = summary.composition_invocations + 1
         ; composition_provider_deliveries =
             summary.composition_provider_deliveries + provider_delivered
         ; composition_official_client_handoffs =
             summary.composition_official_client_handoffs
             + official_client_handoff
         ; composition_actions_observed =
             summary.composition_actions_observed + actions
         })
    (empty_summary (List.length ledger.transition_rejections))
    ledger.activations
;;

let summary_to_yojson summary =
  `Assoc
    [ "instruction_invocations", `Int summary.instruction_invocations
    ; "skill_bodies_served", `Int summary.skill_bodies_served
    ; "skill_resources_served", `Int summary.skill_resources_served
    ; ( "instruction_provider_deliveries"
      , `Int summary.instruction_provider_deliveries )
    ; ( "instruction_official_client_handoffs"
      , `Int summary.instruction_official_client_handoffs )
    ; "instruction_actions_observed", `Int summary.instruction_actions_observed
    ; "composition_invocations", `Int summary.composition_invocations
    ; ( "composition_provider_deliveries"
      , `Int summary.composition_provider_deliveries )
    ; ( "composition_official_client_handoffs"
      , `Int summary.composition_official_client_handoffs )
    ; "composition_actions_observed", `Int summary.composition_actions_observed
    ; "invalid_transitions", `Int summary.invalid_transitions
    ]
;;

let rejection_skill_tool_use_id = function
  | Delivery_order_rejected { skill_tool_use_id; _ }
  | Delivery_conflict_rejected { skill_tool_use_id; _ }
  | Action_before_delivery_rejected { skill_tool_use_id; _ } ->
    skill_tool_use_id
;;

let rejection_activation_turn_ref = function
  | Delivery_order_rejected { activation_turn_ref; _ }
  | Delivery_conflict_rejected { activation_turn_ref; _ }
  | Action_before_delivery_rejected { activation_turn_ref; _ } ->
    activation_turn_ref
;;

let scope_of_activation (activation : activation) =
  { snapshot_revision = activation.snapshot_revision
  ; turn_ref = activation.turn_ref
  ; invocation_runtime_id = activation.runtime_id
  ; reference =
      Skill_reference.make
        ~identity:activation.identity
        ~content_revision:activation.content_revision
  }
;;

let equal_summary_scope left right =
  Skill_catalog_snapshot.equal_snapshot_revision
    left.snapshot_revision
    right.snapshot_revision
  && Ids.Turn_ref.equal left.turn_ref right.turn_ref
  && String.equal left.invocation_runtime_id right.invocation_runtime_id
  && Skill_reference.equal left.reference right.reference
;;

let runtime_counts runtime_ids =
  List.fold_left
    (fun counts runtime_id ->
       let rec increment reversed = function
         | [] -> List.rev_append reversed [ { runtime_id; count = 1 } ]
         | ({ runtime_id = known; count } as current) :: rest ->
           if String.equal runtime_id known
           then List.rev_append reversed ({ current with count = count + 1 } :: rest)
           else increment (current :: reversed) rest
       in
       increment [] counts)
    []
    runtime_ids
;;

let summarize_by_scope ledger =
  let scopes =
    List.fold_left
      (fun scopes activation ->
         let scope = scope_of_activation activation in
         if List.exists (equal_summary_scope scope) scopes
         then scopes
         else scopes @ [ scope ])
      []
      ledger.activations
  in
  List.map
    (fun scope ->
       let activations =
         List.filter
           (fun activation ->
              equal_summary_scope scope (scope_of_activation activation))
           ledger.activations
       in
       let invocation_ids =
         List.map (fun activation -> activation.skill_tool_use_id) activations
       in
       let transition_rejections =
         List.filter
           (fun rejection ->
              List.mem (rejection_skill_tool_use_id rejection) invocation_ids)
           ledger.transition_rejections
       in
       let scoped_ledger = { ledger with activations; transition_rejections } in
       let provider_delivery_runtime_counts =
         activations
         |> List.filter_map (fun activation ->
              match activation.delivery with
              | Some { boundary = Model_response _; runtime_id; _ } ->
                Some runtime_id
              | Some { boundary = Official_client_result_handoff _; _ }
              | None -> None)
         |> runtime_counts
       in
       let official_client_handoff_runtime_counts =
         activations
         |> List.filter_map (fun activation ->
              match activation.delivery with
              | Some
                  { boundary = Official_client_result_handoff _; runtime_id; _ } ->
                Some runtime_id
              | Some { boundary = Model_response _; _ }
              | None -> None)
         |> runtime_counts
       in
       let action_runtime_counts =
         activations
         |> List.concat_map (fun activation ->
              List.map (fun (action : action) -> action.runtime_id) activation.actions)
         |> runtime_counts
       in
       { scope
       ; summary = summarize scoped_ledger
       ; provider_delivery_runtime_counts
       ; official_client_handoff_runtime_counts
       ; action_runtime_counts
       })
    scopes
;;

let scoped_summary_to_yojson scoped =
  `Assoc
    [ ( "scope"
      , `Assoc
          [ ( "snapshot_revision"
            , `String
                (Skill_catalog_snapshot.snapshot_revision_to_string
                   scoped.scope.snapshot_revision) )
          ; "turn_ref", Ids.Turn_ref.to_yojson scoped.scope.turn_ref
          ; "invocation_runtime_id", `String scoped.scope.invocation_runtime_id
          ; "reference", Skill_reference.to_yojson scoped.scope.reference
          ] )
    ; "summary", summary_to_yojson scoped.summary
    ; ( "provider_delivery_runtime_counts"
      , `List
          (List.map
             (fun runtime ->
                `Assoc
                  [ "runtime_id", `String runtime.runtime_id
                  ; "count", `Int runtime.count
                  ])
             scoped.provider_delivery_runtime_counts) )
    ; ( "official_client_handoff_runtime_counts"
      , `List
          (List.map
             (fun runtime ->
                `Assoc
                  [ "runtime_id", `String runtime.runtime_id
                  ; "count", `Int runtime.count
                  ])
             scoped.official_client_handoff_runtime_counts) )
    ; ( "action_runtime_counts"
      , `List
          (List.map
             (fun runtime ->
                `Assoc
                  [ "runtime_id", `String runtime.runtime_id
                  ; "count", `Int runtime.count
                  ])
             scoped.action_runtime_counts) )
    ]
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
  { workspace_key
  ; session_id
  ; activations
  ; transition_rejections
  ; revision =
      revision_of_ledger
        ~workspace_key
        ~session_id
        ~activations
        ~transition_rejections
  }
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
    ; "revision", `String ledger.revision
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
  if String.equal ledger.revision declared_revision
  then Ok ledger
  else Error Ledger_revision_mismatch
;;

let of_yojson ~expected_workspace_root ~expected_trace_id json =
  let* ledger = of_projection_yojson json in
  let* () =
    if Keeper_id.Trace_id.equal ledger.session_id expected_trace_id
    then Ok ()
    else Error Session_id_mismatch
  in
  let expected_workspace_key = workspace_key_of_root expected_workspace_root in
  if String.equal ledger.workspace_key expected_workspace_key
  then Ok ledger
  else Error Workspace_key_mismatch
;;

let ledger_path session_dir = Filename.concat session_dir filename

let read_existing_locked ~ownership_root ~expected_trace_id session_dir =
  let path = ledger_path session_dir in
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Ok None
  | Ok (Some contents) ->
    (match Yojson.Safe.from_string contents with
     | json ->
       of_yojson
         ~expected_workspace_root:ownership_root
         ~expected_trace_id
         json
       |> Result.map Option.some
       |> Result.map_error (fun error -> Decode_failed error)
     | exception Yojson.Json_error _ ->
       Error (Decode_failed (Expected_object { field = "ledger" })))
;;

let read_locked ~ownership_root ~expected_trace_id session_dir =
  let* existing =
    read_existing_locked ~ownership_root ~expected_trace_id session_dir
  in
  Ok
    (Option.value existing
       ~default:(empty ~workspace_root:ownership_root ~trace_id:expected_trace_id))
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
    read_locked ~ownership_root ~expected_trace_id:trace_id session_dir)
;;

let load_existing ~config ~trace_id =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
    read_existing_locked ~ownership_root ~expected_trace_id:trace_id session_dir)
;;

let persist_locked
      ~ownership_root
      ~trace_id
      session_dir
      ~activations
      ~transition_rejections
  =
  let next =
    make
      ~workspace_key:(workspace_key_of_root ownership_root)
      ~session_id:trace_id
      ~activations
      ~transition_rejections
  in
  let path = ledger_path session_dir in
  let* () =
    Keeper_fs.save_json_durable_atomic
      ~ownership_root
      ~pretty:false
      path
      (to_yojson next)
    |> Result.map_error (fun error -> Write_failed error)
  in
  let* readback =
    read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
  in
  if String.equal readback.revision next.revision
  then Ok readback
  else Error Readback_mismatch
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
    let* current = read_locked ~ownership_root ~expected_trace_id:trace_id session_dir in
    match List.find_opt (exact_key_equal activation) current.activations with
    | Some existing
      when Yojson.Safe.equal
             (activation_to_yojson existing)
             (activation_to_yojson activation) ->
      Ok (current, Already_recorded existing)
    | Some _ -> Error (Invocation_id_collision activation.skill_tool_use_id)
    | None ->
      let* readback =
        persist_locked
          ~ownership_root
          ~trace_id
          session_dir
          ~activations:(current.activations @ [ activation ])
          ~transition_rejections:current.transition_rejections
      in
      Ok (readback, Recorded activation))
;;

let persist_transition_rejection
      ~ownership_root
      ~trace_id
      session_dir
      current
      rejection
      error
  =
  let* _stored =
    persist_locked
      ~ownership_root
      ~trace_id
      session_dir
      ~activations:current.activations
      ~transition_rejections:(current.transition_rejections @ [ rejection ])
  in
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
    let* current =
      read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
    in
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
      persist_transition_rejection
        ~ownership_root
        ~trace_id
        session_dir
        current
        rejection
        error
    | None ->
    let reversed, matched, changed =
      List.fold_left
        (fun (reversed, matched, changed) activation ->
           match matching_receipt activation with
           | None -> activation :: reversed, matched, changed
           | Some receipt ->
             let matched = activation.skill_tool_use_id :: matched in
             match activation.delivery with
             | None ->
               let delivery =
                 Some
                   { boundary
                   ; runtime_id
                   ; delivered_at
                   ; content_bytes = receipt.content_bytes
                   ; content_sha256 = receipt.content_sha256
                   }
               in
               { activation with delivery } :: reversed, matched, true
             | Some _ -> activation :: reversed, matched, changed)
        ([], [], false)
        current.activations
    in
    let activations = List.rev reversed in
    let matched = List.rev matched in
    if not changed
    then Ok (current, matched)
    else
      let* stored =
        persist_locked
          ~ownership_root
          ~trace_id
          session_dir
          ~activations
          ~transition_rejections:current.transition_rejections
      in
      Ok (stored, matched))
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
        let* current =
          read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
        in
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
          persist_transition_rejection
            ~ownership_root
            ~trace_id
            session_dir
            current
            rejection
            error
        | None ->
        let* reversed, added =
          List.fold_left
            (fun result activation ->
               let* reversed, added = result in
               if not (List.mem activation.skill_tool_use_id active)
               then Ok (activation :: reversed, added)
               else
                 match activation.delivery with
                 | None -> Ok (activation :: reversed, added)
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
                      Ok (activation :: reversed, added)
                    | Some _ -> Error (Action_identity_collision action_identity)
                    | None ->
                      let activation =
                        { activation with actions = activation.actions @ [ action ] }
                      in
                      Ok (activation :: reversed, added + 1)))
            (Ok ([], 0))
            current.activations
        in
        if added = 0
        then Ok (current, 0)
        else
          let* stored =
            persist_locked
              ~ownership_root
              ~trace_id
              session_dir
              ~activations:(List.rev reversed)
              ~transition_rejections:current.transition_rejections
          in
          Ok (stored, added))
;;
