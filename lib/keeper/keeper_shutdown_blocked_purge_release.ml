let command_schema = "masc.keeper_shutdown.blocked_purge_reissue.command.v1"
let result_schema = "masc.keeper_shutdown.blocked_purge_reissue.result.v1"

type command =
  { keeper_id : string
  ; operation_id : Keeper_shutdown_types.Operation_id.t
  ; expected_revision : int
  ; reason : string
  }

type input_error =
  | Object_required of string
  | Duplicate_fields of string list
  | Unsupported_fields of string list
  | Missing_fields of string list
  | Invalid_field of
      { field : string
      ; expectation : string
      }
  | Unsupported_schema of string

type error =
  | Operation_load_failed of Keeper_shutdown_store.error
  | Profile_materialization_failed of string
  | Metadata_materialization_failed of string
  | Store_reissue_failed of Keeper_shutdown_store.error
  | Finalization_failed of Keeper_shutdown_finalize.error
  | Injected_after_reissue of string

type released =
  { operation : Keeper_shutdown_types.t
  ; already_reissued : bool
  }

let input_error_to_string = function
  | Object_required observed_kind ->
    Printf.sprintf "blocked purge reissue command must be an object (received %s)" observed_kind
  | Duplicate_fields fields ->
    Printf.sprintf "blocked purge reissue command contains duplicate field(s): %s" (String.concat ", " fields)
  | Unsupported_fields fields ->
    Printf.sprintf "blocked purge reissue command contains unsupported field(s): %s" (String.concat ", " fields)
  | Missing_fields fields ->
    Printf.sprintf "blocked purge reissue command is missing required field(s): %s" (String.concat ", " fields)
  | Invalid_field { field; expectation } -> Printf.sprintf "%s %s" field expectation
  | Unsupported_schema schema -> Printf.sprintf "unsupported blocked purge reissue schema %S" schema
;;

let input_error_to_json error =
  let kind, details =
    match error with
    | Object_required observed_kind ->
      "object_required", [ "observed_kind", `String observed_kind ]
    | Duplicate_fields fields ->
      "duplicate_fields", [ "fields", `List (List.map (fun field -> `String field) fields) ]
    | Unsupported_fields fields ->
      "unsupported_fields", [ "fields", `List (List.map (fun field -> `String field) fields) ]
    | Missing_fields fields ->
      "missing_fields", [ "fields", `List (List.map (fun field -> `String field) fields) ]
    | Invalid_field { field; expectation } ->
      "invalid_field", [ "field", `String field; "expectation", `String expectation ]
    | Unsupported_schema schema ->
      "unsupported_schema", [ "schema", `String schema ]
  in
  `Assoc
    ([ "error", `String "blocked_purge_reissue_invalid_input"
     ; "kind", `String kind
     ; "message", `String (input_error_to_string error)
     ]
     @ details)
;;

let expected_fields =
  [ "schema"; "keeper_id"; "operation_id"; "expected_revision"; "reason" ]
;;

let duplicate_fields fields =
  let rec loop seen duplicates = function
    | [] -> List.rev duplicates |> List.sort_uniq String.compare
    | (field, _) :: rest ->
      if List.mem field seen
      then loop seen (field :: duplicates) rest
      else loop (field :: seen) duplicates rest
  in
  loop [] [] fields
;;

let validate_exact_fields fields =
  match duplicate_fields fields with
  | _ :: _ as duplicates -> Error (Duplicate_fields duplicates)
  | [] ->
    let unsupported =
      List.filter_map
        (fun (field, _) -> if List.mem field expected_fields then None else Some field)
        fields
    in
    let missing =
      List.filter (fun field -> not (List.mem_assoc field fields)) expected_fields
    in
    if unsupported <> []
    then Error (Unsupported_fields unsupported)
    else if missing <> []
    then Error (Missing_fields missing)
    else Ok ()
;;

let required field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_fields [ field ])
;;

let exact_nonblank_string ?(max_length = max_int) ~field = function
  | `String value
    when not (String.equal value "")
         && String.equal value (String.trim value)
         && String.length value <= max_length ->
    Ok value
  | `String _ ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf
               "must be non-empty without surrounding whitespace and at most %d bytes"
               max_length
         })
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf "must be a string (received %s)" (Json_util.kind_name value)
         })
;;

let positive_int ~field = function
  | `Int value when value > 0 -> Ok value
  | `Int _ -> Error (Invalid_field { field; expectation = "must be a positive integer" })
  | value ->
    Error
      (Invalid_field
         { field
         ; expectation =
             Printf.sprintf "must be an integer (received %s)" (Json_util.kind_name value)
         })
;;

let parse_command = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* () = validate_exact_fields fields in
    let* schema_json = required "schema" fields in
    let* schema = exact_nonblank_string ~field:"schema" schema_json in
    let* () =
      if String.equal schema command_schema
      then Ok ()
      else Error (Unsupported_schema schema)
    in
    let* keeper_id_json = required "keeper_id" fields in
    let* keeper_id = exact_nonblank_string ~field:"keeper_id" keeper_id_json in
    let* () =
      if Keeper_config.validate_name keeper_id
      then Ok ()
      else
        Error
          (Invalid_field
             { field = "keeper_id"; expectation = "must be a valid Keeper id" })
    in
    let* operation_id_json = required "operation_id" fields in
    let* operation_id_string =
      exact_nonblank_string ~field:"operation_id" operation_id_json
    in
    let* operation_id =
      Keeper_shutdown_types.Operation_id.of_string operation_id_string
      |> Result.map_error (fun _ ->
        Invalid_field
          { field = "operation_id"
          ; expectation = "must be a valid Keeper shutdown operation id"
          })
    in
    let* expected_revision_json = required "expected_revision" fields in
    let* expected_revision =
      positive_int ~field:"expected_revision" expected_revision_json
    in
    let* reason_json = required "reason" fields in
    let* reason = exact_nonblank_string ~max_length:1024 ~field:"reason" reason_json in
    Ok { keeper_id; operation_id; expected_revision; reason }
  | value -> Error (Object_required (Json_util.kind_name value))
;;

let error_to_string = function
  | Operation_load_failed error -> Keeper_shutdown_store.error_to_string error
  | Profile_materialization_failed detail ->
    "blocked purge profile materialization failed: " ^ detail
  | Metadata_materialization_failed detail ->
    "blocked purge paused metadata materialization failed: " ^ detail
  | Store_reissue_failed error -> Keeper_shutdown_store.error_to_string error
  | Finalization_failed error -> Keeper_shutdown_finalize.error_to_string error
  | Injected_after_reissue detail -> detail
;;

let operator_reissue_matches ~actor command operation =
  match operation.Keeper_shutdown_types.join_evidence with
  | Some
      { lane_outcome =
          Lane_operator_purge_reissue
            { actor = persisted_actor; reason; expected_revision }
      ; _
      } ->
    String.equal actor persisted_actor
    && String.equal command.reason reason
    && Int.equal command.expected_revision expected_revision
  | Some
      { lane_outcome =
          ( Lane_completed
          | Lane_shutdown_requested
          | Lane_cancelled_by_parent _
          | Lane_failed _ )
      ; _
      }
  | None -> false
;;

let paused_meta_from_profile ~config command operation =
  let open Result.Syntax in
  let* context =
    match operation.Keeper_shutdown_types.cleanup_intent.reason with
    | Dashboard_keeper_purge context -> Ok context
    | Operator_stop_retain_meta
    | Operator_stop_remove_meta
    | Supervisor_cleanup ->
      Error (Profile_materialization_failed "operation is not a dashboard purge")
  in
  let* () =
    match
      Keeper_types_profile.keeper_toml_path_opt_for_base_path
        ~base_path:config.Workspace.base_path
        command.keeper_id
    with
    | Some _ -> Ok ()
    | None ->
      Error
        (Profile_materialization_failed
           "surviving Keeper TOML is required for exact purge reissue")
  in
  let* defaults =
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path:config.Workspace.base_path
      command.keeper_id
    |> Result.map_error (fun error ->
      Profile_materialization_failed
        (Keeper_types_profile.keeper_toml_load_error_to_string error))
  in
  let sandbox_profile =
    Keeper_turn_up_args.resolve_sandbox_profile
      ?requested:None
      ~fallback:defaults.sandbox_profile
      ()
  in
  let network_mode =
    Keeper_turn_up_args.resolve_network_mode
      ~sandbox_profile
      ~fallback:defaults.network_mode
  in
  let now = Masc_domain.now_iso () in
  let now_ts = Time_compat.now () in
  let open Keeper_meta_contract in
  Ok
    { id = defaults.id
    ; name = command.keeper_id
    ; agent_name = context.agent_name
    ; instructions = Option.value ~default:"" defaults.instructions
    ; autonomous_instructions = defaults.autonomous_instructions
    ; sandbox_profile
    ; sandbox_image = defaults.sandbox_image
    ; network_mode
    ; allowed_paths = Option.value ~default:[] defaults.allowed_paths
    ; mention_targets =
        Keeper_turn_up_args.resolve_mention_targets
          ~mention_targets_opt:(Some defaults.mention_targets)
          ~fallback_targets:defaults.mention_targets
          ~name:command.keeper_id
    ; proactive = { enabled = false }
    ; multimodal_policy =
        Option.value
          ~default:Keeper_types_profile.default_multimodal_policy
          defaults.multimodal_policy
    ; created_at = operation.created_at
    ; updated_at = now
    ; max_context_override = defaults.max_context_override
    ; paused = true
    ; latched_reason =
        Some
          (Keeper_latched_reason.Operator_paused
             { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
    ; autoboot_enabled = false
    ; current_task_id = None
    ; telemetry_feedback_enabled = defaults.telemetry_feedback_enabled
    ; telemetry_feedback_window_hours = defaults.telemetry_feedback_window_hours
    ; always_allow = defaults.always_allow
    ; runtime =
        { usage =
            { total_turns = 0
            ; total_input_tokens = 0
            ; total_output_tokens = 0
            ; total_tokens = 0
            ; total_cost_usd = 0.0
            ; last_turn_ts = 0.0
            ; last_input_tokens = 0
            ; last_output_tokens = 0
            ; last_total_tokens = 0
            ; last_usage_reported_at = None
            ; last_latency_ms = 0
            }
        ; compaction_rt =
            { count = 0
            ; last_ts = 0.0
            ; last_before_tokens = 0
            ; last_after_tokens = 0
            ; last_check_ts = now_ts
            ; last_decision = compaction_runtime_decision_of_string "initialized"
            }
        ; proactive_rt =
            { count_total = 0
            ; last_ts = 0.0
            ; visible_count_total = 0
            ; last_visible_ts = 0.0
            ; last_outcome = Proactive_never_started
            ; last_reason = ""
            ; last_preview = ""
            ; consecutive_noop_count = 0
            }
        ; nonce = operation.generation
        ; trace_id = operation.trace_id
        ; trace_history = []
        ; last_handoff_ts = 0.0
        ; last_autonomous_action_at = ""
        ; autonomous_action_count = 0
        ; autonomous_turn_count = 0
        ; autonomous_text_turn_count = 0
        ; autonomous_tool_turn_count = 0
        ; board_reactive_turn_count = 0
        ; mention_reactive_turn_count = 0
        ; noop_turn_count = 0
        ; message_scope_ack_id = None
        ; last_blocker = None
        ; last_runtime_attempt = None
        }
    ; keeper_id = Some (Keeper_id.Uid.generate ())
    ; agent_core_env = defaults.agent_core_env
    }
;;

let exact_paused_meta operation meta =
  String.equal meta.Keeper_meta_contract.name operation.Keeper_shutdown_types.keeper_name
  && Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id
  && Int.equal meta.runtime.nonce operation.generation
  && meta.paused
;;

let ensure_paused_meta ~config command operation =
  let open Result.Syntax in
  match Keeper_meta_store.read_meta config command.keeper_id with
  | Error detail -> Error (Metadata_materialization_failed detail)
  | Ok (Some meta) when exact_paused_meta operation meta -> Ok meta
  | Ok (Some _) ->
    Error
      (Metadata_materialization_failed
         "existing metadata does not match the blocked purge identity and paused policy")
  | Ok None ->
    let* meta = paused_meta_from_profile ~config command operation in
    let* committed =
      Keeper_owner_registry.create_meta_for_shutdown
        ~base_path:config.Workspace.base_path
        ~operation_id:operation.operation_id
        meta
      |> Result.map_error (fun error ->
        Metadata_materialization_failed
          (Keeper_owner_registry.command_error_to_string error))
    in
    (match committed with
     | Some committed when exact_paused_meta operation committed -> Ok committed
     | Some _ ->
       Error
         (Metadata_materialization_failed
            "committed metadata did not preserve the blocked purge identity")
     | None -> Error (Metadata_materialization_failed "metadata disappeared during commit"))
;;

let finalize_reissued ~config operation =
  match operation.Keeper_shutdown_types.phase with
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Finalized _ ->
    Keeper_shutdown_finalize.run ~config ~entry:None operation
    |> Result.map_error (fun error -> Finalization_failed error)
  | Prepared
  | Joining_lanes
  | Reconciliation_required _
  | Blocked _
  | Superseded _ ->
    Error (Store_reissue_failed (Keeper_shutdown_store.Supersession_phase_mismatch operation))
;;

let fail_after_reissue_once : string option Atomic.t = Atomic.make None

let execute ~config ~actor command =
  let open Result.Syntax in
  let* observed =
    Keeper_shutdown_store.load
      ~config
      ~keeper_name:command.keeper_id
      command.operation_id
    |> Result.map_error (fun error -> Operation_load_failed error)
  in
  let already_reissued = operator_reissue_matches ~actor command observed in
  let* (_meta : Keeper_meta_contract.keeper_meta option) =
    if already_reissued
    then Ok None
    else ensure_paused_meta ~config command observed |> Result.map Option.some
  in
  let* reissue =
    Keeper_shutdown_store.reissue_blocked_dashboard_purge
      ~config
      ~keeper_name:command.keeper_id
      ~operation_id:command.operation_id
      ~expected_revision:command.expected_revision
      ~actor
      ~reason:command.reason
      ~now:Masc_domain.now_iso
    |> Result.map_error (fun error -> Store_reissue_failed error)
  in
  let reissued, already_reissued =
    match reissue with
    | Keeper_shutdown_store.Purge_reissue_persisted operation -> operation, false
    | Keeper_shutdown_store.Purge_reissue_already_persisted operation ->
      operation, true
  in
  let* () =
    match Atomic.exchange fail_after_reissue_once None with
    | None -> Ok ()
    | Some detail -> Error (Injected_after_reissue detail)
  in
  let* operation = finalize_reissued ~config reissued in
  Ok { operation; already_reissued }
;;

let audit_writer
    : (Workspace.config -> actor:string -> command -> outcome:Audit_log.outcome -> unit)
        Atomic.t
  =
  Atomic.make (fun config ~actor command ~outcome ->
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom "keeper_blocked_purge_reissue")
      ~details:
        (`Assoc
          [ "keeper_id", `String command.keeper_id
          ; ( "operation_id"
            , `String
                (Keeper_shutdown_types.Operation_id.to_string command.operation_id) )
          ; "expected_revision", `Int command.expected_revision
          ; "reason", `String command.reason
          ])
      ~outcome
      ())

let audit config ~actor command ~outcome =
  try
    Atomic.get audit_writer config ~actor command ~outcome;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let success_json ~audit command released =
  `Assoc
    [ "schema", `String result_schema
    ; "ok", `Bool true
    ; "keeper_id", `String command.keeper_id
    ; ( "operation_id"
      , `String (Keeper_shutdown_types.Operation_id.to_string command.operation_id) )
    ; "expected_revision", `Int command.expected_revision
    ; "revision", `Int released.operation.Keeper_shutdown_types.revision
    ; "already_reissued", `Bool released.already_reissued
    ; "phase", `String (Keeper_shutdown_types.phase_to_string released.operation.phase)
    ; "audit_durable", `Bool true
    ; "purge_reissue_completed", `Bool true
    ; "audit", audit
    ]
;;

module For_testing = struct
  let reset_audit_writer () =
    Atomic.set audit_writer (fun config ~actor command ~outcome ->
      Audit_log.log_action
        config
        ~agent_id:actor
        ~action:(Audit_log.Custom "keeper_blocked_purge_reissue")
        ~details:
          (`Assoc
            [ "keeper_id", `String command.keeper_id
            ; ( "operation_id"
              , `String
                  (Keeper_shutdown_types.Operation_id.to_string command.operation_id) )
            ; "expected_revision", `Int command.expected_revision
            ; "reason", `String command.reason
            ])
        ~outcome
        ())
  ;;

  let fail_next_audit_write detail =
    let failed = Atomic.make false in
    let fallback = Atomic.get audit_writer in
    Atomic.set audit_writer (fun config ~actor command ~outcome ->
      if Atomic.compare_and_set failed false true
      then raise (Sys_error detail)
      else fallback config ~actor command ~outcome)
  ;;

  let fail_next_after_reissue detail =
    Atomic.set fail_after_reissue_once (Some detail)
  ;;
end

let error_json ~audit error =
  `Assoc
    [ "error", `String "blocked_purge_reissue_failed"
    ; "message", `String (error_to_string error)
    ; "audit", audit
    ]
;;
