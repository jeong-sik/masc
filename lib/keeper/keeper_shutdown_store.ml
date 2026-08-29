open Keeper_shutdown_types

module String_map = Map.Make (String)

type error =
  | Already_exists of string
  | Not_found of string
  | Io_error of string
  | Decode_error of string
  | Invalid_operation of Keeper_shutdown_types.invariant_error
  | Identity_mismatch of string
  | Revision_conflict of
      { expected : int
      ; actual : int
      }
  | Supersession_phase_mismatch of Keeper_shutdown_types.t
  | Supersession_intent_mismatch of Keeper_shutdown_types.t
  | Invalid_supersession_actor of string

type persist_blocked_result =
  | State_preserved of Keeper_shutdown_types.t
  | Blocked_persisted of Keeper_shutdown_types.t

type supersede_blocked_result =
  | Superseded_persisted of Keeper_shutdown_types.t
  | Superseded_already_persisted of Keeper_shutdown_types.t

(* What the operator is releasing. [Blocked_operator_stop] carries no
   effect-duplication risk: the shutdown worker failed, so the turn it was
   finalizing did not proceed. [Unreconciled_turn] does: the process ended
   without a lane receipt while that turn was in flight, so its external
   effects may or may not have landed. The two are kept apart here so the
   durable [Superseded] record states which one an operator signed off on —
   the prior phase is overwritten by the supersession, so the turn cannot be
   recovered from the record afterwards. *)
type superseded_admission =
  | Blocked_operator_stop
  | Blocked_dashboard_purge
  | Unreconciled_turn of Keeper_shutdown_types.active_turn

type operator_metadata_supersession_token =
  { base_path : string
  ; keeper_name : string
  ; operation_id : Operation_id.t
  ; expected_revision : int
  ; actor : string
  ; superseded_admission : superseded_admission
  }

type corrupt_record =
  { keeper_name : string
  ; operation_id : Operation_id.t
  ; path : string
  ; error : error
  }

type inventory_entry =
  | Operation of Keeper_shutdown_types.t
  | Corrupt_record of corrupt_record

let canonical_corrupt_operation_ids inventory =
  inventory
  |> List.fold_left
       (fun selected -> function
          | Operation _ -> selected
          | Corrupt_record corrupt ->
            let operation_id =
              match String_map.find_opt corrupt.keeper_name selected with
              | None -> corrupt.operation_id
              | Some existing ->
                if
                  String.compare
                    (Operation_id.to_string corrupt.operation_id)
                    (Operation_id.to_string existing)
                  < 0
                then corrupt.operation_id
                else existing
            in
            String_map.add corrupt.keeper_name operation_id selected)
       String_map.empty
  |> String_map.bindings
;;

let error_to_string = function
  | Already_exists path -> Printf.sprintf "shutdown operation already exists: %s" path
  | Not_found path -> Printf.sprintf "shutdown operation not found: %s" path
  | Io_error detail -> Printf.sprintf "shutdown operation I/O failed: %s" detail
  | Decode_error detail -> Printf.sprintf "shutdown operation decode failed: %s" detail
  | Invalid_operation error ->
    Printf.sprintf
      "shutdown operation invariant failed: %s"
      (Keeper_shutdown_types.invariant_error_to_string error)
  | Identity_mismatch detail ->
    Printf.sprintf "shutdown operation identity mismatch: %s" detail
  | Revision_conflict { expected; actual } ->
    Printf.sprintf
      "shutdown operation revision conflict: expected %d, actual %d"
      expected
      actual
  | Supersession_phase_mismatch operation ->
    Printf.sprintf
      "shutdown operation is not an operator-supersedable blocked operation: keeper=%s operation=%s"
      operation.keeper_name
      (Operation_id.to_string operation.operation_id)
  | Supersession_intent_mismatch operation ->
    Printf.sprintf
      "shutdown operation cleanup intent cannot be superseded by metadata update: keeper=%s operation=%s reason=%s"
      operation.keeper_name
      (Operation_id.to_string operation.operation_id)
      (cleanup_reason_label operation.cleanup_intent.reason)
  | Invalid_supersession_actor detail ->
    Printf.sprintf "shutdown supersession actor is invalid: %s" detail
;;

type lock_access =
  | Read
  | Write

let with_operation_lock ~access key f =
  let lock = Keeper_fs.acquire_path_lock key in
  Fun.protect
    ~finally:(fun () -> Keeper_fs.release_path_lock key lock)
    (fun () ->
       match access with
       | Write ->
         Eio.Mutex.use_rw ~protect:true (Keeper_fs.path_lock_mutex lock) f
       | Read -> Eio.Mutex.use_ro (Keeper_fs.path_lock_mutex lock) f)
;;

let records_dir (config : Workspace.config) =
  Filename.concat (Workspace.keepers_runtime_dir config) ".shutdown-operations"
;;

(* Prefixing the portable Keeper name makes the path component reversible and
   keeps the valid names [.] and [..] from becoming directory traversal. The
   one-byte codec also stays below the existing [<keeper>.json] meta-path
   overhead for every name that current persistence can represent. *)
let owner_dir_prefix = "_"

let owner_dir_name_of_keeper_name keeper_name =
  if Safe_identifier.is_portable_name keeper_name
  then Ok (owner_dir_prefix ^ keeper_name)
  else
    Error
      (Identity_mismatch
         (Safe_identifier.portable_name_error ~field:"shutdown Keeper owner"))
;;

let keeper_name_of_owner_dir_name owner_dir_name =
  let prefix_length = String.length owner_dir_prefix in
  if
    String.length owner_dir_name > prefix_length
    && String.equal
         (String.sub owner_dir_name 0 prefix_length)
         owner_dir_prefix
  then
    let keeper_name =
      String.sub
        owner_dir_name
        prefix_length
        (String.length owner_dir_name - prefix_length)
    in
    if Safe_identifier.is_portable_name keeper_name
    then Ok keeper_name
    else
      Error
        (Safe_identifier.portable_name_error ~field:"shutdown Keeper owner")
  else
    Error
      (Printf.sprintf
         "shutdown Keeper owner directory must use the %S codec"
         owner_dir_prefix)
;;

let keeper_records_dir config keeper_name =
  owner_dir_name_of_keeper_name keeper_name
  |> Result.map (fun owner_dir_name ->
    Filename.concat
      (records_dir config)
      owner_dir_name)
;;

let path ~config ~keeper_name operation_id =
  keeper_records_dir config keeper_name
  |> Result.map (fun keeper_dir ->
    Filename.concat
      keeper_dir
      (Keeper_shutdown_types.Operation_id.to_string operation_id ^ ".json"))
;;

let path_for_operation ~config (operation : Keeper_shutdown_types.t) =
  path
    ~config
    ~keeper_name:operation.keeper_name
    operation.operation_id
;;

let with_keeper_inventory_lock ~access ~config ~keeper_name f =
  match keeper_records_dir config keeper_name with
  | Error _ as error -> error
  | Ok keeper_dir -> with_operation_lock ~access keeper_dir f
;;

let int_option_to_json = function
  | None -> `Null
  | Some value -> `Int value
;;


let active_turn_to_json turn =
  `Assoc
    [ ( "lane"
      , match turn.lane with
        | None -> `Null
        | Some lane -> `String (admission_lane_to_string lane) )
    ; "admitted_at", Json_util.float_opt_to_json turn.admitted_at
    ; "observed_turn_id", int_option_to_json turn.observed_turn_id
    ; "observation_started_at", Json_util.float_opt_to_json turn.observation_started_at
    ]
;;

let turn_disposition_to_json = function
  | No_inflight_turn -> `Assoc [ "kind", `String "no_inflight_turn" ]
  | Inflight_effect_unknown turn ->
    `Assoc
      [ "kind", `String "inflight_effect_unknown"
      ; "active_turn", active_turn_to_json turn
      ]
;;

let failure_to_json failure =
  `Assoc
    [ "stage", `String (failure_stage_to_string failure.stage)
    ; "detail", `String failure.detail
    ]
;;

let task_ids_to_json task_ids =
  `List
    (List.map
       (fun task_id -> `String (Keeper_id.Task_id.to_string task_id))
       task_ids)
;;

let cleanup_evidence_to_json evidence =
  `Assoc
    [ "settled_task_ids", task_ids_to_json evidence.settled_task_ids
    ; "pending_confirms_removed", `Int evidence.pending_confirms_removed
    ; ( "meta_snapshot_digest"
      , `String
          (Keeper_meta_json.Snapshot_digest.to_string
             evidence.meta_snapshot_digest) )
    ]
;;

let completion_receipt_to_json = function
  | Completion_not_requested -> `Assoc [ "kind", `String "not_requested" ]
  | Completion_pending action ->
    `Assoc
      [ "kind", `String "pending"
      ; "action", `String (completion_action_to_string action)
      ]
  | Completion_delivered action ->
    `Assoc
      [ "kind", `String "delivered"
      ; "action", `String (completion_action_to_string action)
      ]
;;

let finalization_evidence_to_json evidence =
  `Assoc
    [ "cleanup", cleanup_evidence_to_json evidence.cleanup
    ; "meta_removed", `Bool evidence.meta_removed
    ; "session_removed", `Bool evidence.session_removed
    ; "registry_unregistered", `Bool evidence.registry_unregistered
    ; "accumulator_dropped", `Bool evidence.accumulator_dropped
    ; "completion", completion_receipt_to_json evidence.completion
    ]
;;

let supersession_to_json = function
  | Operator_blocked_purge_released { actor } ->
    `Assoc
      [ "kind", `String "operator_blocked_purge_released"
      ; "actor", `String actor
      ]
  | Operator_metadata_update { actor } ->
    `Assoc
      [ "kind", `String "operator_metadata_update"
      ; "actor", `String actor
      ]
  | Operator_reconciliation_accepted { actor; unreconciled_turn } ->
    `Assoc
      [ "kind", `String "operator_reconciliation_accepted"
      ; "actor", `String actor
      ; "unreconciled_turn", active_turn_to_json unreconciled_turn
      ]
;;

let lane_ownership_to_json = function
  | Registered_lane lane_id ->
    `Assoc
      [ "kind", `String "registered_lane"
      ; "lane_id", `String (Keeper_lane.Id.to_string lane_id)
      ]
  | Dormant_meta -> `Assoc [ "kind", `String "dormant_meta" ]
;;

let cleanup_reason_to_json = function
  | Operator_stop_retain_meta ->
    `Assoc [ "kind", `String "operator_stop_retain_meta" ]
  | Operator_stop_remove_meta ->
    `Assoc [ "kind", `String "operator_stop_remove_meta" ]
  | Supervisor_cleanup ->
    `Assoc [ "kind", `String "supervisor_cleanup" ]
  | Dashboard_keeper_purge context ->
    `Assoc
      [ "kind", `String "dashboard_keeper_purge"
      ; "requested_name", `String context.requested_name
      ]
;;

let phase_to_json = function
  | Prepared -> `Assoc [ "kind", `String "prepared" ]
  | Joining_lanes -> `Assoc [ "kind", `String "joining_lanes" ]
  | Joined_idle -> `Assoc [ "kind", `String "joined_idle" ]
  | Finalizing_tasks settled_task_ids ->
    `Assoc
      [ "kind", `String "finalizing_tasks"
      ; "settled_task_ids", task_ids_to_json settled_task_ids
      ]
  | Cleanup_ready evidence ->
    `Assoc
      [ "kind", `String "cleanup_ready"
      ; "evidence", cleanup_evidence_to_json evidence
      ]
  | Reconciliation_required turn ->
    `Assoc
      [ "kind", `String "reconciliation_required"
      ; "active_turn", active_turn_to_json turn
      ]
  | Finalized evidence ->
    `Assoc
      [ "kind", `String "finalized"
      ; "evidence", finalization_evidence_to_json evidence
      ]
  | Blocked failure ->
    `Assoc
      [ "kind", `String "blocked"
      ; "failure", failure_to_json failure
      ]
  | Superseded supersession ->
    `Assoc
      [ "kind", `String "superseded"
      ; "supersession", supersession_to_json supersession
      ]
;;

let lane_outcome_to_json = function
  | Lane_completed -> `Assoc [ "kind", `String "completed" ]
  | Lane_shutdown_requested -> `Assoc [ "kind", `String "shutdown_requested" ]
  | Lane_cancelled_by_parent detail ->
    `Assoc
      [ "kind", `String "cancelled_by_parent"
      ; "detail", `String detail
      ]
  | Lane_failed detail ->
    `Assoc
      [ "kind", `String "failed"
      ; "detail", `String detail
      ]
;;

let terminal_to_json = function
  | Terminal_stopped -> `Assoc [ "kind", `String "stopped" ]
  | Terminal_crashed detail ->
    `Assoc
      [ "kind", `String "crashed"
      ; "detail", `String detail
      ]
;;

let join_evidence_to_json evidence =
  `Assoc
    [ "lane_outcome", lane_outcome_to_json evidence.lane_outcome
    ; "terminal", terminal_to_json evidence.terminal
    ; ( "cleanup_error"
      , match evidence.cleanup_error with
        | None -> `Null
        | Some detail -> `String detail )
    ]
;;

let to_json operation =
  `Assoc
    [ "schema_version", `Int operation.schema_version
    ; "revision", `Int operation.revision
    ; "operation_id", `String (Operation_id.to_string operation.operation_id)
    ; "keeper_name", `String operation.keeper_name
    ; "lane_ownership", lane_ownership_to_json operation.lane_ownership
    ; "trace_id", `String (Keeper_id.Trace_id.to_string operation.trace_id)
    ; "actor", `String operation.actor
    ; ( "cleanup_intent"
      , `Assoc
          [ "reason", cleanup_reason_to_json operation.cleanup_intent.reason
          ; "remove_session", `Bool operation.cleanup_intent.remove_session
          ] )
    ; "turn_disposition", turn_disposition_to_json operation.turn_disposition
    ; "expected_backlog_version", `Int operation.expected_backlog_version
    ; "owned_task_ids", task_ids_to_json operation.owned_task_ids
    ; ( "join_evidence"
      , match operation.join_evidence with
        | None -> `Null
        | Some evidence -> join_evidence_to_json evidence )
    ; "phase", phase_to_json operation.phase
    ; "created_at", `String operation.created_at
    ; "updated_at", `String operation.updated_at
    ]
;;

let decode_error field expected =
  Decode_error (Printf.sprintf "%s must be %s" field expected)
;;

let assoc field = function
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some value -> Ok value
     | None -> Error (Decode_error (Printf.sprintf "missing field %s" field)))
  | _ -> Error (decode_error field "inside an object")
;;

let string field json =
  match assoc field json with
  | Ok (`String value) -> Ok value
  | Ok _ -> Error (decode_error field "a string")
  | Error _ as error -> error
;;

let int field json =
  match assoc field json with
  | Ok (`Int value) -> Ok value
  | Ok _ -> Error (decode_error field "an integer")
  | Error _ as error -> error
;;

let bool field json =
  match assoc field json with
  | Ok (`Bool value) -> Ok value
  | Ok _ -> Error (decode_error field "a boolean")
  | Error _ as error -> error
;;

let optional_int field json =
  match assoc field json with
  | Ok `Null -> Ok None
  | Ok (`Int value) -> Ok (Some value)
  | Ok _ -> Error (decode_error field "an integer or null")
  | Error _ as error -> error
;;

let optional_float field json =
  match assoc field json with
  | Ok `Null -> Ok None
  | Ok (`Float value) -> Ok (Some value)
  | Ok (`Int value) -> Ok (Some (float_of_int value))
  | Ok _ -> Error (decode_error field "a number or null")
  | Error _ as error -> error
;;

let optional_string field json =
  match assoc field json with
  | Ok `Null -> Ok None
  | Ok (`String value) -> Ok (Some value)
  | Ok _ -> Error (decode_error field "a string or null")
  | Error _ as error -> error
;;

let ( let* ) result f = Result.bind result f

let validate_operation operation =
  Keeper_shutdown_types.validate operation
  |> Result.map_error (fun error -> Invalid_operation error)
;;

let active_turn_of_json json =
  let* lane =
    match assoc "lane" json with
    | Ok `Null -> Ok None
    | Ok (`String lane_wire) ->
      admission_lane_of_string lane_wire
      |> Result.map Option.some
      |> Result.map_error (fun e -> Decode_error e)
    | Ok _ -> Error (decode_error "lane" "a string or null")
    | Error _ as error -> error
  in
  let* admitted_at = optional_float "admitted_at" json in
  let* observed_turn_id = optional_int "observed_turn_id" json in
  let* observation_started_at = optional_float "observation_started_at" json in
  Ok { lane; admitted_at; observed_turn_id; observation_started_at }
;;

let turn_disposition_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "no_inflight_turn" -> Ok No_inflight_turn
  | "inflight_effect_unknown" ->
    let* active_json = assoc "active_turn" json in
    let* turn = active_turn_of_json active_json in
    Ok (Inflight_effect_unknown turn)
  | value -> Error (Decode_error (Printf.sprintf "unknown turn disposition: %S" value))
;;

let failure_of_json json =
  let* stage_wire = string "stage" json in
  let* stage = failure_stage_of_string stage_wire |> Result.map_error (fun e -> Decode_error e) in
  let* detail = string "detail" json in
  Ok { stage; detail }
;;

let task_ids_field_of_json field json =
  match assoc field json with
  | Error _ as error -> error
  | Ok (`List values) ->
    List.fold_left
      (fun result value ->
         let* task_ids = result in
         match value with
         | `String raw ->
           let* task_id =
             Keeper_id.Task_id.of_string raw
             |> Result.map_error (fun e -> Decode_error e)
           in
           Ok (task_id :: task_ids)
         | _ -> Error (decode_error (field ^ "[]") "a string"))
      (Ok [])
      values
    |> Result.map List.rev
  | Ok _ -> Error (decode_error field "an array")
;;

let cleanup_evidence_of_json json =
  let* settled_task_ids = task_ids_field_of_json "settled_task_ids" json in
  let* pending_confirms_removed = int "pending_confirms_removed" json in
  let* meta_snapshot_digest_wire = string "meta_snapshot_digest" json in
  let* meta_snapshot_digest =
    Keeper_meta_json.Snapshot_digest.of_string meta_snapshot_digest_wire
    |> Result.map_error (fun detail -> Decode_error detail)
  in
  Ok { settled_task_ids; pending_confirms_removed; meta_snapshot_digest }
;;

let completion_receipt_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "not_requested" -> Ok Completion_not_requested
  | "pending" ->
    let* action_wire = string "action" json in
    let* action =
      completion_action_of_string action_wire
      |> Result.map_error (fun detail -> Decode_error detail)
    in
    Ok (Completion_pending action)
  | "delivered" ->
    let* action_wire = string "action" json in
    let* action =
      completion_action_of_string action_wire
      |> Result.map_error (fun detail -> Decode_error detail)
    in
    Ok (Completion_delivered action)
  | value ->
    Error
      (Decode_error
         (Printf.sprintf "unknown shutdown completion receipt: %S" value))
;;

let finalization_evidence_of_json json =
  let* cleanup_json = assoc "cleanup" json in
  let* cleanup = cleanup_evidence_of_json cleanup_json in
  let* meta_removed = bool "meta_removed" json in
  let* session_removed = bool "session_removed" json in
  let* registry_unregistered = bool "registry_unregistered" json in
  let* accumulator_dropped = bool "accumulator_dropped" json in
  let* completion_json = assoc "completion" json in
  let* completion = completion_receipt_of_json completion_json in
  Ok
    { cleanup
    ; meta_removed
    ; session_removed
    ; registry_unregistered
    ; accumulator_dropped
    ; completion
    }
;;

let supersession_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "operator_blocked_purge_released" ->
    let* actor = string "actor" json in
    Ok (Operator_blocked_purge_released { actor })
  | "operator_metadata_update" ->
    let* actor = string "actor" json in
    Ok (Operator_metadata_update { actor })
  | "operator_reconciliation_accepted" ->
    let* actor = string "actor" json in
    let* turn_json = assoc "unreconciled_turn" json in
    let* unreconciled_turn = active_turn_of_json turn_json in
    Ok (Operator_reconciliation_accepted { actor; unreconciled_turn })
  | value ->
    Error
      (Decode_error
         (Printf.sprintf "unknown shutdown supersession: %S" value))
;;

let phase_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "prepared" -> Ok Prepared
  | "joining_lanes" -> Ok Joining_lanes
  | "joined_idle" -> Ok Joined_idle
  | "finalizing_tasks" ->
    let* settled_task_ids = task_ids_field_of_json "settled_task_ids" json in
    Ok (Finalizing_tasks settled_task_ids)
  | "cleanup_ready" ->
    let* evidence_json = assoc "evidence" json in
    let* evidence = cleanup_evidence_of_json evidence_json in
    Ok (Cleanup_ready evidence)
  | "reconciliation_required" ->
    let* active_json = assoc "active_turn" json in
    let* turn = active_turn_of_json active_json in
    Ok (Reconciliation_required turn)
  | "finalized" ->
    let* evidence_json = assoc "evidence" json in
    let* evidence = finalization_evidence_of_json evidence_json in
    Ok (Finalized evidence)
  | "blocked" ->
    let* failure_json = assoc "failure" json in
    let* failure = failure_of_json failure_json in
    Ok (Blocked failure)
  | "superseded" ->
    let* supersession_json = assoc "supersession" json in
    let* supersession = supersession_of_json supersession_json in
    Ok (Superseded supersession)
  | value -> Error (Decode_error (Printf.sprintf "unknown shutdown phase: %S" value))
;;

let lane_outcome_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "completed" -> Ok Lane_completed
  | "shutdown_requested" -> Ok Lane_shutdown_requested
  | "cancelled_by_parent" ->
    let* detail = string "detail" json in
    Ok (Lane_cancelled_by_parent detail)
  | "failed" ->
    let* detail = string "detail" json in
    Ok (Lane_failed detail)
  | value -> Error (Decode_error (Printf.sprintf "unknown lane outcome: %S" value))
;;

let terminal_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "stopped" -> Ok Terminal_stopped
  | "crashed" ->
    let* detail = string "detail" json in
    Ok (Terminal_crashed detail)
  | value -> Error (Decode_error (Printf.sprintf "unknown terminal outcome: %S" value))
;;

let join_evidence_of_json json =
  let* lane_json = assoc "lane_outcome" json in
  let* lane_outcome = lane_outcome_of_json lane_json in
  let* terminal_json = assoc "terminal" json in
  let* terminal = terminal_of_json terminal_json in
  let* cleanup_error = optional_string "cleanup_error" json in
  Ok { lane_outcome; terminal; cleanup_error }
;;

let optional_join_evidence_of_json json =
  match assoc "join_evidence" json with
  | Ok `Null -> Ok None
  | Ok evidence_json -> join_evidence_of_json evidence_json |> Result.map Option.some
  | Error _ as error -> error
;;

let lane_ownership_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "registered_lane" ->
    let* lane_id_wire = string "lane_id" json in
    Keeper_lane.Id.of_string lane_id_wire
    |> Result.map (fun lane_id -> Registered_lane lane_id)
    |> Result.map_error (fun detail -> Decode_error detail)
  | "dormant_meta" -> Ok Dormant_meta
  | value ->
    Error
      (Decode_error
         (Printf.sprintf "unknown shutdown lane ownership: %S" value))
;;

let cleanup_reason_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "operator_stop_retain_meta" -> Ok Operator_stop_retain_meta
  | "operator_stop_remove_meta" -> Ok Operator_stop_remove_meta
  | "supervisor_cleanup" -> Ok Supervisor_cleanup
  | "dashboard_keeper_purge" ->
    let* requested_name = string "requested_name" json in
    Ok (Dashboard_keeper_purge { requested_name })
  | value ->
    Error
      (Decode_error (Printf.sprintf "unknown shutdown cleanup reason: %S" value))
;;

let of_json json =
  let* decoded_schema_version = int "schema_version" json in
  let* () =
    if Int.equal decoded_schema_version schema_version
    then Ok ()
    else
      Error
        (Decode_error
           (Printf.sprintf
              "unsupported shutdown schema version: %d"
              decoded_schema_version))
  in
    let* operation_id_wire = string "operation_id" json in
    let* revision = int "revision" json in
    let* operation_id =
      Operation_id.of_string operation_id_wire
      |> Result.map_error (fun e -> Decode_error e)
    in
    let* keeper_name = string "keeper_name" json in
    let* lane_ownership_json = assoc "lane_ownership" json in
    let* lane_ownership = lane_ownership_of_json lane_ownership_json in
    let* trace_id_wire = string "trace_id" json in
    let* trace_id =
      Keeper_id.Trace_id.of_string trace_id_wire
      |> Result.map_error (fun e -> Decode_error e)
    in
    let* actor = string "actor" json in
    let* cleanup_json = assoc "cleanup_intent" json in
    let* reason_json = assoc "reason" cleanup_json in
    let* reason = cleanup_reason_of_json reason_json in
    let* remove_session = bool "remove_session" cleanup_json in
    let* turn_json = assoc "turn_disposition" json in
    let* turn_disposition = turn_disposition_of_json turn_json in
    let* expected_backlog_version = int "expected_backlog_version" json in
    let* owned_task_ids = task_ids_field_of_json "owned_task_ids" json in
    let* join_evidence = optional_join_evidence_of_json json in
    let* phase_json = assoc "phase" json in
    let* phase = phase_of_json phase_json in
    let* created_at = string "created_at" json in
    let* updated_at = string "updated_at" json in
    let operation =
      { schema_version
      ; revision
      ; operation_id
      ; keeper_name
      ; lane_ownership
      ; trace_id
      ; actor
      ; cleanup_intent = { reason; remove_session }
      ; turn_disposition
      ; expected_backlog_version
      ; owned_task_ids
      ; join_evidence
      ; phase
      ; created_at
      ; updated_at
      }
    in
    let* () = validate_operation operation in
    Ok operation
;;

let contextualize_error operation_path = function
  | Decode_error detail -> Decode_error (Printf.sprintf "%s: %s" operation_path detail)
  | Io_error detail -> Io_error (Printf.sprintf "%s: %s" operation_path detail)
  | Identity_mismatch detail ->
    Identity_mismatch (Printf.sprintf "%s: %s" operation_path detail)
  | ( Already_exists _
    | Not_found _
    | Invalid_operation _
    | Revision_conflict _
    | Supersession_phase_mismatch _
    | Supersession_intent_mismatch _
    | Invalid_supersession_actor _ ) as error ->
    error
;;

let load_path_unlocked ~operation_path ~keeper_name ~operation_id =
  if not (Fs_compat.file_exists operation_path)
  then Error (Not_found operation_path)
  else
    try
      let operation_result =
        Fs_compat.load_file operation_path
        |> Yojson.Safe.from_string
        |> of_json
        |> Result.map_error (contextualize_error operation_path)
      in
      match operation_result with
      | Error _ as error -> error
      | Ok operation
        when String.equal keeper_name operation.keeper_name
             && Operation_id.equal operation_id operation.operation_id -> Ok operation
      | Ok operation ->
        Error
          (Identity_mismatch
             (Printf.sprintf
                "%s: path owner=%s operation=%s, payload owner=%s operation=%s"
                operation_path
                keeper_name
                (Operation_id.to_string operation_id)
                operation.keeper_name
                (Operation_id.to_string operation.operation_id)))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Yojson.Json_error detail ->
      Error (Decode_error (Printf.sprintf "%s: %s" operation_path detail))
    | exn ->
      Error
        (Io_error
           (Printf.sprintf "%s: %s" operation_path (Printexc.to_string exn)))
;;

let persist_new ~config operation =
  let* () = validate_operation operation in
  let* operation_path = path_for_operation ~config operation in
  with_keeper_inventory_lock
    ~access:Write
    ~config
    ~keeper_name:operation.keeper_name
    (fun () ->
       with_operation_lock ~access:Write operation_path (fun () ->
         if Fs_compat.file_exists operation_path
         then Error (Already_exists operation_path)
         else
           Keeper_fs.save_json_atomic operation_path (to_json operation)
           |> Result.map_error (fun detail -> Io_error detail)))
;;

type terminal_delete_outcome =
  | Terminal_deleted
  | Terminal_retained

(* Durable intake is authorized by current metadata alone
   ([authorize_durable_intake_owner]), so a settled operation record has no
   reader left and keeping it only makes boot recovery walk the same
   settled operation forever. A [Completion_pending] receipt is still owed
   to its consumer; [requires_admission_fence] already keeps such an
   operation out of the reclaim call sites, and this predicate refuses it
   independently. *)
let reclaimable_terminal_phase (operation : Keeper_shutdown_types.t) =
  match operation.phase with
  | Keeper_shutdown_types.Superseded _ -> true
  | Keeper_shutdown_types.Finalized
      { completion = Keeper_shutdown_types.Completion_pending _; _ } -> false
  | Keeper_shutdown_types.Finalized
      { completion =
          ( Keeper_shutdown_types.Completion_not_requested
          | Keeper_shutdown_types.Completion_delivered _ )
      ; _
      } -> true
  | Keeper_shutdown_types.Prepared
  | Keeper_shutdown_types.Joining_lanes
  | Keeper_shutdown_types.Joined_idle
  | Keeper_shutdown_types.Finalizing_tasks _
  | Keeper_shutdown_types.Cleanup_ready _
  | Keeper_shutdown_types.Reconciliation_required _
  | Keeper_shutdown_types.Blocked _ -> false
;;

let delete_terminal ~config ~keeper_name ~operation_id =
  let* operation_path = path ~config ~keeper_name operation_id in
  with_keeper_inventory_lock
    ~access:Write
    ~config
    ~keeper_name
    (fun () ->
       with_operation_lock ~access:Write operation_path (fun () ->
         if not (Fs_compat.file_exists operation_path)
         then Ok Terminal_deleted
         else
           match
             load_path_unlocked ~operation_path ~keeper_name ~operation_id
           with
           | Error error -> Error error
           | Ok operation ->
             if reclaimable_terminal_phase operation
             then (
               match
                 Keeper_fs.remove_file_durable
                   ~ownership_root:config.Workspace.base_path
                   operation_path
               with
               | Ok () -> Ok Terminal_deleted
               | Error error ->
                 Error
                   (Io_error
                      (Keeper_fs.durable_remove_error_to_string error)))
             else Ok Terminal_retained))
;;

let replace ~config ~expected_revision operation =
  let* () = validate_operation operation in
  let* operation_path = path_for_operation ~config operation in
  with_keeper_inventory_lock
    ~access:Write
    ~config
    ~keeper_name:operation.keeper_name
    (fun () ->
       with_operation_lock ~access:Write operation_path (fun () ->
         match
           load_path_unlocked
             ~operation_path
             ~keeper_name:operation.keeper_name
             ~operation_id:operation.operation_id
         with
         | Error _ as error -> error
         | Ok existing when not (Int.equal existing.revision expected_revision) ->
           Error
             (Revision_conflict
                { expected = expected_revision; actual = existing.revision })
         | Ok _ when not (Int.equal operation.revision (expected_revision + 1)) ->
           Error
             (Revision_conflict
                { expected = expected_revision + 1
                ; actual = operation.revision
                })
         | Ok existing when Keeper_shutdown_types.immutable_fields_equal existing operation ->
           Keeper_fs.save_json_atomic operation_path (to_json operation)
           |> Result.map_error (fun detail -> Io_error detail)
         | Ok _ ->
           Error
             (Identity_mismatch
                (Operation_id.to_string operation.operation_id))))
;;

let prepare_operator_metadata_supersession
      ~config
      ~keeper_name
      ~operation_id
      ~actor
  =
  let base_path =
    Keeper_registry_types.canonical_base_path_exn config.Workspace.base_path
  in
  let* actor =
    Workspace.validate_agent_name actor
    |> Result.map_error (fun detail -> Invalid_supersession_actor detail)
  in
  let* operation_path = path ~config ~keeper_name operation_id in
  match
    with_operation_lock ~access:Read operation_path (fun () ->
      load_path_unlocked ~operation_path ~keeper_name ~operation_id)
  with
  | Error _ as error -> error
  | Ok
      ({ phase = Blocked _
       ; cleanup_intent = { reason = Operator_stop_retain_meta; _ }
       ; revision
       ; _ } as _operation) ->
    Ok
      { base_path
      ; keeper_name
      ; operation_id
      ; expected_revision = revision
      ; actor
      ; superseded_admission = Blocked_operator_stop
      }
    (* #25491: a [Reconciliation_required] fence had no release path at all —
       the worker and boot recovery deliberately refuse to assume the turn's
       effects landed, and the operator was refused too, which left the keeper
       with no reachable state at all (RFC-0000 §1.2 LAW 1 "No dead-end").
       #25522 later taught boot recovery to settle the phase automatically
       ([settled_reconciliation_state]); this operator route remains as the
       manual release for records whose boot-settle persist failed. *)
  | Ok
      ({ phase = Reconciliation_required turn
       ; cleanup_intent = { reason = Operator_stop_retain_meta; _ }
       ; revision
       ; _ } as _operation) ->
    Ok
      { base_path
      ; keeper_name
      ; operation_id
      ; expected_revision = revision
      ; actor
      ; superseded_admission = Unreconciled_turn turn
      }
  | Ok
      ({ phase = Superseded (Operator_blocked_purge_released _)
       ; revision
       ; _ } as _operation) ->
    (* Idempotent: a second release of the same purge re-mints the same token
       rather than reporting a phase mismatch. *)
    Ok
      { base_path
      ; keeper_name
      ; operation_id
      ; expected_revision = revision
      ; actor
      ; superseded_admission = Blocked_dashboard_purge
      }
  | Ok
      ({ phase = Superseded (Operator_metadata_update _ | Operator_reconciliation_accepted _)
       ; revision
       ; _ } as _operation) ->
    Ok
      { base_path
      ; keeper_name
      ; operation_id
      ; expected_revision = revision
      ; actor
      ; superseded_admission = Blocked_operator_stop
      }
  (* A purge whose worker died in [Joining_lanes] holds the admission fence,
     and that fence is what stops its own reissue: meta cannot be materialized
     while it is held, and [Keeper_dashboard_purge.resolve] needs that meta to
     build a target. Releasing it is the only exit, and it is as safe here as
     for an operator stop -- the phase, not the intent, is what says the work
     failed. *)
  | Ok
      ({ phase = Blocked _
       ; cleanup_intent = { reason = Dashboard_keeper_purge _; _ }
       ; revision
       ; _ } as _operation) ->
    Ok
      { base_path
      ; keeper_name
      ; operation_id
      ; expected_revision = revision
      ; actor
      ; superseded_admission = Blocked_dashboard_purge
      }
  | Ok ({ phase = Blocked _; _ } as operation) ->
    Error (Supersession_intent_mismatch operation)
  | Ok operation -> Error (Supersession_phase_mismatch operation)
;;

let supersession_token_operation_id (token : operator_metadata_supersession_token) =
  token.operation_id

let supersede_blocked_operator_stop ~config ~token ~now =
  let config_base_path =
    Keeper_registry_types.canonical_base_path_exn config.Workspace.base_path
  in
  if not (String.equal config_base_path token.base_path)
  then
    Error
      (Identity_mismatch
         (Printf.sprintf
            "supersession token BasePath mismatch: expected=%s actual=%s"
            token.base_path
            config_base_path))
  else
  let operation_path =
    path
      ~config
      ~keeper_name:token.keeper_name
      token.operation_id
  in
  let* operation_path = operation_path in
  with_keeper_inventory_lock
    ~access:Write
    ~config
    ~keeper_name:token.keeper_name
    (fun () ->
       with_operation_lock ~access:Write operation_path (fun () ->
         match
           load_path_unlocked
             ~operation_path
             ~keeper_name:token.keeper_name
             ~operation_id:token.operation_id
         with
         | Error _ as error -> error
         | Ok
             ({ phase =
                  Superseded
                    ( Operator_metadata_update _
                    | Operator_reconciliation_accepted _
                    | Operator_blocked_purge_released _ )
              ; _ } as existing) ->
           Ok (Superseded_already_persisted existing)
         | Ok
             ({ phase = Blocked _ | Reconciliation_required _
              ; cleanup_intent = { reason = Operator_stop_retain_meta; _ }
              ; _ } as existing)
         | Ok
             ({ phase = Blocked _
              ; cleanup_intent = { reason = Dashboard_keeper_purge _; _ }
              ; _ } as existing) ->
           if not (Int.equal existing.revision token.expected_revision)
           then
             Error
               (Revision_conflict
                  { expected = token.expected_revision; actual = existing.revision })
           else
             (* The recorded supersession follows the token minted at preflight,
                not the phase re-read here: preflight is what the operator acted
                on, and the revision check above proves nothing changed since. *)
             let supersession =
               match token.superseded_admission with
               | Blocked_operator_stop ->
                 Operator_metadata_update { actor = token.actor }
               | Blocked_dashboard_purge ->
                 Operator_blocked_purge_released { actor = token.actor }
               | Unreconciled_turn unreconciled_turn ->
                 Operator_reconciliation_accepted
                   { actor = token.actor; unreconciled_turn }
             in
             let superseded =
               { existing with
                 revision = existing.revision + 1
               ; phase = Superseded supersession
               ; updated_at = now ()
               }
             in
             Keeper_fs.save_json_atomic operation_path (to_json superseded)
             |> Result.map_error (fun detail -> Io_error detail)
             |> Result.map (fun () -> Superseded_persisted superseded)
         | Ok ({ phase = Blocked _; _ } as existing) ->
           Error (Supersession_intent_mismatch existing)
         | Ok existing -> Error (Supersession_phase_mismatch existing)))
;;

let persist_blocked_latest ~config ~identity ~failure ~now =
  let* () = validate_operation identity in
  let* operation_path = path_for_operation ~config identity in
  with_keeper_inventory_lock
    ~access:Write
    ~config
    ~keeper_name:identity.keeper_name
    (fun () ->
       with_operation_lock ~access:Write operation_path (fun () ->
         match
           load_path_unlocked
             ~operation_path
             ~keeper_name:identity.keeper_name
             ~operation_id:identity.operation_id
         with
         | Error _ as error -> error
         | Ok existing
           when not
                  (Keeper_shutdown_types.immutable_fields_equal existing identity) ->
           Error (Identity_mismatch (Operation_id.to_string identity.operation_id))
         | Ok existing ->
           (match existing.phase with
            | Finalized _ | Blocked _ | Reconciliation_required _ | Superseded _ ->
              Ok (State_preserved existing)
            | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _
            | Cleanup_ready _ ->
              let blocked =
                { existing with
                  revision = existing.revision + 1
                ; phase = Blocked failure
                ; updated_at = now ()
                }
              in
              Keeper_fs.save_json_atomic operation_path (to_json blocked)
              |> Result.map_error (fun detail -> Io_error detail)
              |> Result.map (fun () -> Blocked_persisted blocked))))
;;

let load ~config ~keeper_name operation_id =
  let* operation_path = path ~config ~keeper_name operation_id in
  with_operation_lock ~access:Read operation_path (fun () ->
    load_path_unlocked ~operation_path ~keeper_name ~operation_id)
;;

let scan_keeper_dir ~config ~keeper_name =
  let* dir = keeper_records_dir config keeper_name in
  match Fs_compat.path_kind ~follow:false dir with
  | Fs_compat.Missing -> Ok []
  | Fs_compat.Other ->
    Error
      (Decode_error
         (Printf.sprintf
            "shutdown store owner entry is not a directory: %s"
            dir))
  | Fs_compat.Directory ->
    with_operation_lock ~access:Read dir (fun () ->
    (try
      Fs_compat.read_dir dir
      |> List.fold_left
           (fun result filename ->
              let* entries = result in
              if not (Filename.check_suffix filename ".json")
              then
                Error
                  (Decode_error
                     (Printf.sprintf
                        "unexpected shutdown store entry for Keeper %s: %s"
                        keeper_name
                        filename))
              else
                let raw_id = Filename.chop_suffix filename ".json" in
                let* operation_id =
                  Operation_id.of_string raw_id
                  |> Result.map_error (fun e -> Decode_error e)
                in
                let operation_path = Filename.concat dir filename in
                let entry =
                  with_operation_lock ~access:Read operation_path (fun () ->
                    match
                      load_path_unlocked
                        ~operation_path
                        ~keeper_name
                        ~operation_id
                    with
                    | Ok operation -> Operation operation
                    | Error error ->
                      Corrupt_record
                        { keeper_name; operation_id; path = operation_path; error })
                in
                Ok (entry :: entries))
           (Ok [])
      |> Result.map List.rev
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Io_error (Printexc.to_string exn))))
;;

let corrupt_operation_id_for_keeper ~config ~keeper_name =
  let* inventory = scan_keeper_dir ~config ~keeper_name in
  Ok
    (canonical_corrupt_operation_ids inventory
     |> List.assoc_opt keeper_name)
;;

let scan_inventory ~config =
  let dir = records_dir config in
  try
    match Fs_compat.path_kind ~follow:false dir with
    | Fs_compat.Missing -> Ok []
    | Fs_compat.Other ->
      Error
        (Decode_error
           (Printf.sprintf
              "shutdown store inventory is not a directory: %s"
              dir))
    | Fs_compat.Directory ->
      Fs_compat.read_dir dir
      |> List.fold_left
           (fun result owner_dir_name ->
              let* entries = result in
              let owner_path = Filename.concat dir owner_dir_name in
              let* validated_name =
                keeper_name_of_owner_dir_name owner_dir_name
                |> Result.map_error (fun detail ->
                  Decode_error
                    (Printf.sprintf
                       "shutdown store entry has no isolatable Keeper owner: %s (%s)"
                       owner_path
                       detail))
              in
              let* keeper_entries =
                scan_keeper_dir ~config ~keeper_name:validated_name
              in
              Ok (List.rev_append keeper_entries entries))
           (Ok [])
      |> Result.map List.rev
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Io_error (Printexc.to_string exn))
;;

let list_for_keeper ~config ~keeper_name =
  let* inventory = scan_keeper_dir ~config ~keeper_name in
  inventory
  |> List.fold_left
       (fun result entry ->
          let* operations = result in
          match entry with
          | Operation operation -> Ok (operation :: operations)
          | Corrupt_record corrupt -> Error corrupt.error)
       (Ok [])
  |> Result.map List.rev
;;

module For_testing = struct
  let with_operation_write_lock ~config ~keeper_name operation_id f =
    let* operation_path = path ~config ~keeper_name operation_id in
    Ok (with_operation_lock ~access:Write operation_path f)
  ;;
end
