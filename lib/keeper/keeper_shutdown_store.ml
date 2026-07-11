open Keeper_shutdown_types

type error =
  | Already_exists of string
  | Not_found of string
  | Io_error of string
  | Decode_error of string
  | Identity_mismatch of string

let error_to_string = function
  | Already_exists path -> Printf.sprintf "shutdown operation already exists: %s" path
  | Not_found path -> Printf.sprintf "shutdown operation not found: %s" path
  | Io_error detail -> Printf.sprintf "shutdown operation I/O failed: %s" detail
  | Decode_error detail -> Printf.sprintf "shutdown operation decode failed: %s" detail
  | Identity_mismatch detail ->
    Printf.sprintf "shutdown operation identity mismatch: %s" detail
;;

type operation_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

let operation_locks : (string, operation_lock) Hashtbl.t = Hashtbl.create 16
let operation_locks_mutex = Stdlib.Mutex.create ()

type lock_access =
  | Read
  | Write

let acquire_operation_lock key =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    match Hashtbl.find_opt operation_locks key with
    | Some lock ->
      lock.users <- lock.users + 1;
      lock
    | None ->
      let lock = { mutex = Eio.Mutex.create (); users = 1 } in
      Hashtbl.add operation_locks key lock;
      lock)
;;

let release_operation_lock key lock =
  Stdlib.Mutex.protect operation_locks_mutex (fun () ->
    lock.users <- lock.users - 1;
    if lock.users = 0
    then
      match Hashtbl.find_opt operation_locks key with
      | Some current when current == lock -> Hashtbl.remove operation_locks key
      | Some _ | None -> ())
;;

let with_operation_lock ~access key f =
  let lock = acquire_operation_lock key in
  Fun.protect
    ~finally:(fun () -> release_operation_lock key lock)
    (fun () ->
       match access with
       | Write -> Eio.Mutex.use_rw ~protect:true lock.mutex f
       | Read -> Eio.Mutex.use_ro lock.mutex f)
;;

let records_dir (config : Workspace.config) =
  Filename.concat (Workspace.keepers_runtime_dir config) ".shutdown-operations"
;;

let path ~config operation_id =
  Filename.concat
    (records_dir config)
    (Keeper_shutdown_types.Operation_id.to_string operation_id ^ ".json")
;;

let int_option_to_json = function
  | None -> `Null
  | Some value -> `Int value
;;

let float_option_to_json = function
  | None -> `Null
  | Some value -> `Float value
;;

let active_turn_to_json turn =
  `Assoc
    [ ( "lane"
      , match turn.lane with
        | None -> `Null
        | Some lane -> `String (admission_lane_to_string lane) )
    ; "admitted_at", float_option_to_json turn.admitted_at
    ; "observed_turn_id", int_option_to_json turn.observed_turn_id
    ; "observation_started_at", float_option_to_json turn.observation_started_at
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

let phase_to_json = function
  | Prepared -> `Assoc [ "kind", `String "prepared" ]
  | Joined_idle -> `Assoc [ "kind", `String "joined_idle" ]
  | Reconciliation_required turn ->
    `Assoc
      [ "kind", `String "reconciliation_required"
      ; "active_turn", active_turn_to_json turn
      ]
  | Blocked failure ->
    `Assoc
      [ "kind", `String "blocked"
      ; "failure", failure_to_json failure
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
    ; "operation_id", `String (Operation_id.to_string operation.operation_id)
    ; "keeper_name", `String operation.keeper_name
    ; "lane_id", `String (Keeper_lane.Id.to_string operation.lane_id)
    ; "trace_id", `String (Keeper_id.Trace_id.to_string operation.trace_id)
    ; "generation", `Int operation.generation
    ; "actor", `String operation.actor
    ; ( "cleanup_intent"
      , `Assoc
          [ "remove_meta", `Bool operation.cleanup_intent.remove_meta
          ; "remove_session", `Bool operation.cleanup_intent.remove_session
          ] )
    ; "turn_disposition", turn_disposition_to_json operation.turn_disposition
    ; ( "owned_task_ids"
      , `List
          (List.map
             (fun task_id -> `String (Keeper_id.Task_id.to_string task_id))
             operation.owned_task_ids) )
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

let phase_of_json json =
  let* kind = string "kind" json in
  match kind with
  | "prepared" -> Ok Prepared
  | "joined_idle" -> Ok Joined_idle
  | "reconciliation_required" ->
    let* active_json = assoc "active_turn" json in
    let* turn = active_turn_of_json active_json in
    Ok (Reconciliation_required turn)
  | "blocked" ->
    let* failure_json = assoc "failure" json in
    let* failure = failure_of_json failure_json in
    Ok (Blocked failure)
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

let task_ids_of_json json =
  match assoc "owned_task_ids" json with
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
         | _ -> Error (decode_error "owned_task_ids[]" "a string"))
      (Ok [])
      values
    |> Result.map List.rev
  | Ok _ -> Error (decode_error "owned_task_ids" "an array")
;;

let of_json json =
  let* decoded_schema_version = int "schema_version" json in
  if decoded_schema_version <> schema_version
  then
    Error
      (Decode_error
         (Printf.sprintf
            "unsupported shutdown schema version: %d"
            decoded_schema_version))
  else
    let* operation_id_wire = string "operation_id" json in
    let* operation_id =
      Operation_id.of_string operation_id_wire
      |> Result.map_error (fun e -> Decode_error e)
    in
    let* keeper_name = string "keeper_name" json in
    let* lane_id_wire = string "lane_id" json in
    let* lane_id =
      Keeper_lane.Id.of_string lane_id_wire
      |> Result.map_error (fun e -> Decode_error e)
    in
    let* trace_id_wire = string "trace_id" json in
    let* trace_id =
      Keeper_id.Trace_id.of_string trace_id_wire
      |> Result.map_error (fun e -> Decode_error e)
    in
    let* generation = int "generation" json in
    let* actor = string "actor" json in
    let* cleanup_json = assoc "cleanup_intent" json in
    let* remove_meta = bool "remove_meta" cleanup_json in
    let* remove_session = bool "remove_session" cleanup_json in
    let* turn_json = assoc "turn_disposition" json in
    let* turn_disposition = turn_disposition_of_json turn_json in
    let* owned_task_ids = task_ids_of_json json in
    let* join_evidence = optional_join_evidence_of_json json in
    let* phase_json = assoc "phase" json in
    let* phase = phase_of_json phase_json in
    let* created_at = string "created_at" json in
    let* updated_at = string "updated_at" json in
    Ok
      { schema_version = decoded_schema_version
      ; operation_id
      ; keeper_name
      ; lane_id
      ; trace_id
      ; generation
      ; actor
      ; cleanup_intent = { remove_meta; remove_session }
      ; turn_disposition
      ; owned_task_ids
      ; join_evidence
      ; phase
      ; created_at
      ; updated_at
      }
;;

let load_unlocked ~config operation_id =
  let operation_path = path ~config operation_id in
  if not (Fs_compat.file_exists operation_path)
  then Error (Not_found operation_path)
  else
    try
      Fs_compat.load_file operation_path
      |> Yojson.Safe.from_string
      |> of_json
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Yojson.Json_error detail -> Error (Decode_error detail)
    | exn -> Error (Io_error (Printexc.to_string exn))
;;

let persist_new ~config operation =
  let operation_path = path ~config operation.operation_id in
  with_operation_lock ~access:Write operation_path (fun () ->
    if Fs_compat.file_exists operation_path
    then Error (Already_exists operation_path)
    else
      Keeper_fs.save_json_atomic operation_path (to_json operation)
      |> Result.map_error (fun detail -> Io_error detail))
;;

let same_identity left right =
  Operation_id.equal left.operation_id right.operation_id
  && String.equal left.keeper_name right.keeper_name
  && Keeper_lane.Id.equal left.lane_id right.lane_id
  && Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Int.equal left.generation right.generation
;;

let replace ~config operation =
  let operation_path = path ~config operation.operation_id in
  with_operation_lock ~access:Write operation_path (fun () ->
    match load_unlocked ~config operation.operation_id with
    | Error _ as error -> error
    | Ok existing when same_identity existing operation ->
      Keeper_fs.save_json_atomic operation_path (to_json operation)
      |> Result.map_error (fun detail -> Io_error detail)
    | Ok _ ->
      Error
        (Identity_mismatch
           (Operation_id.to_string operation.operation_id)))
;;

let load ~config operation_id =
  let operation_path = path ~config operation_id in
  with_operation_lock ~access:Read operation_path (fun () ->
    load_unlocked ~config operation_id)
;;

let list_for_keeper ~config ~keeper_name =
  let dir = records_dir config in
  if not (Fs_compat.file_exists dir)
  then Ok []
  else
    try
      Sys.readdir dir
      |> Array.to_list
      |> List.sort String.compare
      |> List.fold_left
           (fun result filename ->
              let* operations = result in
              if not (Filename.check_suffix filename ".json")
              then
                Error
                  (Decode_error
                     (Printf.sprintf
                        "unexpected shutdown store entry: %s"
                        filename))
              else
                let raw_id = Filename.chop_suffix filename ".json" in
                let* operation_id =
                  Operation_id.of_string raw_id
                  |> Result.map_error (fun e -> Decode_error e)
                in
                let* operation = load ~config operation_id in
                if String.equal operation.keeper_name keeper_name
                then Ok (operation :: operations)
                else Ok operations)
           (Ok [])
      |> Result.map List.rev
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Io_error (Printexc.to_string exn))
;;
