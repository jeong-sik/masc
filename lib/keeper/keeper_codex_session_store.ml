type settlement =
  { thread_id : string
  ; turn_id : string
  }

type recovery_failure =
  | Transport_interrupted
  | Protocol_failed
  | Provider_rejected
  | Host_hook_failed
  | State_persistence_failed

type recovery_required =
  { recovery_id : string
  ; previous_settlement : settlement option
  ; observed_thread_id : string option
  ; observed_turn_id : string option
  ; failure : recovery_failure
  ; detail : string
  ; required_at : float
  }

type phase =
  | Ready
  | Start of { previous_settlement : settlement option }
  | Active of
      { thread_id : string
      ; previous_settlement : settlement option
      }
  | Turn_inflight of
      { thread_id : string
      ; turn_id : string option
      ; previous_settlement : settlement option
      }
  | Recovery_required of recovery_required
  | Settled of settlement

type recovery_resolution =
  | Retry_previous
  | Restart_fresh
  | Adopt_verified of settlement

type recovery_resolution_record =
  { recovery_id : string
  ; failure : recovery_failure
  ; resolution : recovery_resolution
  ; resolved_by : string
  ; resolved_at : float
  }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; last_recovery_resolution : recovery_resolution_record option
  ; updated_at : float
  }

let ( let* ) = Result.bind
let schema = "masc.keeper.codex-session.v3"
let filename = "codex-session.json"
let state_dirname = "official-client-runtime"
let lock_filename = "codex-session.lock"
let recovery_rng = Random.State.make_self_init ()
let recovery_rng_mutex = Stdlib.Mutex.create ()

let fresh_recovery_id () =
  Stdlib.Mutex.protect recovery_rng_mutex (fun () ->
    Uuidm.v4_gen recovery_rng () |> Uuidm.to_string)
;;

let state_dir ~base_path ~keeper_name =
  if not (Safe_identifier.is_portable_name keeper_name)
  then Error (Printf.sprintf "invalid Codex session Keeper name %S" keeper_name)
  else
    Ok
      (Filename.concat
         (Filename.concat
            (Common.keepers_runtime_dir_of_base ~base_path)
            keeper_name)
         state_dirname)
;;

let path ~base_path ~keeper_name =
  Result.map
    (fun directory -> Filename.concat directory filename)
    (state_dir ~base_path ~keeper_name)
;;

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (name, value) -> name, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
    value
;;

let tool_surface_sha256 tools =
  let tool_json (tool : Agent_sdk.Tool.t) =
    let parameters =
      List.sort
        (fun (left : Agent_sdk.Types.tool_param) right ->
           String.compare left.name right.name)
        tool.schema.parameters
    in
    `Assoc
      [ "description", `String tool.schema.description
      ; "input_schema", Agent_sdk.Types.params_to_input_schema parameters
      ; "name", `String tool.schema.name
      ]
    |> canonical_json
  in
  tools
  |> List.sort (fun (left : Agent_sdk.Tool.t) right ->
    String.compare left.schema.name right.schema.name)
  |> List.map tool_json
  |> fun tools -> Yojson.Safe.to_string (`List tools)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let valid_sha256 value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let non_empty field value =
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "Codex session %s must not be empty" field)
  else Ok ()
;;

let validate_settlement { thread_id; turn_id } =
  let* () = non_empty "thread_id" thread_id in
  non_empty "turn_id" turn_id
;;

let validate_settlement_opt = function
  | None -> Ok ()
  | Some settlement -> validate_settlement settlement
;;

let validate_recovery (recovery : recovery_required) =
  let* () =
    if Option.is_some (Uuidm.of_string recovery.recovery_id)
    then Ok ()
    else Error "Codex recovery_id must be a UUID"
  in
  let* () = validate_settlement_opt recovery.previous_settlement in
  let* () =
    match recovery.observed_thread_id with
    | None -> Ok ()
    | Some thread_id -> non_empty "observed_thread_id" thread_id
  in
  let* () =
    match recovery.observed_turn_id, recovery.observed_thread_id with
    | None, _ -> Ok ()
    | Some turn_id, Some _ -> non_empty "observed_turn_id" turn_id
    | Some _, None ->
      Error "Codex recovery observed_turn_id requires observed_thread_id"
  in
  let* () = non_empty "recovery detail" recovery.detail in
  if Float.is_finite recovery.required_at
  then Ok ()
  else Error "Codex recovery required_at must be finite"
;;

let validate_recovery_resolution = function
  | Retry_previous | Restart_fresh -> Ok ()
  | Adopt_verified settlement -> validate_settlement settlement
;;

let validate_recovery_resolution_record (record : recovery_resolution_record) =
  let* () =
    if Option.is_some (Uuidm.of_string record.recovery_id)
    then Ok ()
    else Error "Codex resolved recovery_id must be a UUID"
  in
  let* () = validate_recovery_resolution record.resolution in
  let* () = non_empty "resolved_by" record.resolved_by in
  if Float.is_finite record.resolved_at
  then Ok ()
  else Error "Codex recovery resolved_at must be finite"
;;

let validate_phase = function
  | Ready -> Ok ()
  | Start { previous_settlement } ->
    validate_settlement_opt previous_settlement
  | Active { thread_id; previous_settlement }
  | Turn_inflight { thread_id; turn_id = None; previous_settlement } ->
    let* () = non_empty "thread_id" thread_id in
    validate_settlement_opt previous_settlement
  | Turn_inflight
      { thread_id; turn_id = Some turn_id; previous_settlement } ->
    let* () = non_empty "thread_id" thread_id in
    let* () = non_empty "turn_id" turn_id in
    validate_settlement_opt previous_settlement
  | Recovery_required recovery -> validate_recovery recovery
  | Settled settlement -> validate_settlement settlement
;;

let validate binding =
  let* () = non_empty "runtime_id" binding.runtime_id in
  let* () = validate_phase binding.phase in
  let* () =
    match binding.last_recovery_resolution with
    | None -> Ok ()
    | Some record -> validate_recovery_resolution_record record
  in
  if binding.turn_count < 0
  then Error "Codex session turn_count must be non-negative"
  else if binding.turn_count = 0 && binding.phase <> Ready
  then Error "only a ready Codex session may have zero completed turns"
  else if not (valid_sha256 binding.tool_surface_sha256)
  then Error "Codex session tool_surface_sha256 must be lowercase SHA-256"
  else if not (Float.is_finite binding.updated_at)
  then Error "Codex session updated_at must be finite"
  else Ok ()
;;

let settlement_to_yojson settlement =
  `Assoc
    [ "thread_id", `String settlement.thread_id
    ; "turn_id", `String settlement.turn_id
    ]
;;

let settlement_opt_to_yojson = function
  | None -> `Null
  | Some settlement -> settlement_to_yojson settlement
;;

let settlement_of_yojson = function
  | `Assoc [ "thread_id", `String thread_id; "turn_id", `String turn_id ]
  | `Assoc [ "turn_id", `String turn_id; "thread_id", `String thread_id ] ->
    let settlement = { thread_id; turn_id } in
    let* () = validate_settlement settlement in
    Ok settlement
  | _ -> Error "Codex settlement fields are not exact"
;;

let settlement_opt_of_yojson = function
  | `Null -> Ok None
  | json -> Result.map Option.some (settlement_of_yojson json)
;;

let recovery_failure_to_string = function
  | Transport_interrupted -> "transport_interrupted"
  | Protocol_failed -> "protocol_failed"
  | Provider_rejected -> "provider_rejected"
  | Host_hook_failed -> "host_hook_failed"
  | State_persistence_failed -> "state_persistence_failed"
;;

let recovery_failure_of_string = function
  | "transport_interrupted" -> Ok Transport_interrupted
  | "protocol_failed" -> Ok Protocol_failed
  | "provider_rejected" -> Ok Provider_rejected
  | "host_hook_failed" -> Ok Host_hook_failed
  | "state_persistence_failed" -> Ok State_persistence_failed
  | _ -> Error "unknown Codex recovery failure"
;;

let recovery_resolution_to_yojson = function
  | Retry_previous -> `Assoc [ "kind", `String "retry_previous" ]
  | Restart_fresh -> `Assoc [ "kind", `String "restart_fresh" ]
  | Adopt_verified settlement ->
    `Assoc
      [ "kind", `String "adopt_verified"
      ; "settlement", settlement_to_yojson settlement
      ]
;;

let recovery_resolution_of_yojson = function
  | `Assoc [ "kind", `String "retry_previous" ] -> Ok Retry_previous
  | `Assoc [ "kind", `String "restart_fresh" ] -> Ok Restart_fresh
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "adopt_verified"; "settlement", settlement_json ] ->
       Result.map (fun settlement -> Adopt_verified settlement)
         (settlement_of_yojson settlement_json)
     | _ -> Error "Codex recovery resolution fields are not exact")
  | _ -> Error "Codex recovery resolution must be a JSON object"
;;

let recovery_resolution_record_to_yojson
    (record : recovery_resolution_record) =
  `Assoc
    [ "failure", `String (recovery_failure_to_string record.failure)
    ; "recovery_id", `String record.recovery_id
    ; "resolution", recovery_resolution_to_yojson record.resolution
    ; "resolved_at", `Float record.resolved_at
    ; "resolved_by", `String record.resolved_by
    ]
;;

let recovery_resolution_record_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "failure", `String failure; "recovery_id", `String recovery_id
       ; "resolution", resolution_json; "resolved_at", `Float resolved_at
       ; "resolved_by", `String resolved_by ] ->
       let* failure = recovery_failure_of_string failure in
       let* resolution = recovery_resolution_of_yojson resolution_json in
       let record =
         { recovery_id; failure; resolution; resolved_by; resolved_at }
       in
       let* () = validate_recovery_resolution_record record in
       Ok record
     | _ -> Error "Codex recovery resolution record fields are not exact")
  | _ -> Error "Codex recovery resolution record must be a JSON object"
;;

let recovery_resolution_record_opt_to_yojson = function
  | None -> `Null
  | Some record -> recovery_resolution_record_to_yojson record
;;

let recovery_resolution_record_opt_of_yojson = function
  | `Null -> Ok None
  | json ->
    Result.map Option.some (recovery_resolution_record_of_yojson json)
;;

let string_opt_to_yojson = function
  | None -> `Null
  | Some value -> `String value
;;

let string_opt_of_yojson field = function
  | `Null -> Ok None
  | `String value ->
    let* () = non_empty field value in
    Ok (Some value)
  | _ -> Error (Printf.sprintf "Codex recovery %s must be string or null" field)
;;

let phase_to_yojson = function
  | Ready -> `Assoc [ "kind", `String "ready" ]
  | Start { previous_settlement } ->
    `Assoc
      [ "kind", `String "start"
      ; "previous_settlement", settlement_opt_to_yojson previous_settlement
      ]
  | Active { thread_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "active"
      ; "previous_settlement", settlement_opt_to_yojson previous_settlement
      ; "thread_id", `String thread_id
      ]
  | Turn_inflight { thread_id; turn_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "turn_inflight"
      ; "previous_settlement", settlement_opt_to_yojson previous_settlement
      ; "thread_id", `String thread_id
      ; ( "turn_id"
        , Option.fold ~none:`Null ~some:(fun turn_id -> `String turn_id) turn_id )
      ]
  | Recovery_required recovery ->
    `Assoc
      [ "detail", `String recovery.detail
      ; "failure", `String (recovery_failure_to_string recovery.failure)
      ; "kind", `String "recovery_required"
      ; "observed_thread_id", string_opt_to_yojson recovery.observed_thread_id
      ; "observed_turn_id", string_opt_to_yojson recovery.observed_turn_id
      ; ( "previous_settlement"
        , settlement_opt_to_yojson recovery.previous_settlement )
      ; "recovery_id", `String recovery.recovery_id
      ; "required_at", `Float recovery.required_at
      ]
  | Settled { thread_id; turn_id } ->
    `Assoc
      [ "kind", `String "settled"
      ; "thread_id", `String thread_id
      ; "turn_id", `String turn_id
      ]
;;

let phase_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "ready" ] -> Ok Ready
     | [ "kind", `String "start"; "previous_settlement", previous ] ->
       let* previous_settlement = settlement_opt_of_yojson previous in
       Ok (Start { previous_settlement })
     | [ "kind", `String "active"; "previous_settlement", previous
       ; "thread_id", `String thread_id ] ->
       let* previous_settlement = settlement_opt_of_yojson previous in
       Ok (Active { thread_id; previous_settlement })
     | [ "kind", `String "turn_inflight"; "previous_settlement", previous
       ; "thread_id", `String thread_id; "turn_id", turn_id_json ] ->
       let* previous_settlement = settlement_opt_of_yojson previous in
       let* turn_id = string_opt_of_yojson "observed_turn_id" turn_id_json in
       Ok (Turn_inflight { thread_id; turn_id; previous_settlement })
     | [ "detail", `String detail; "failure", `String failure
       ; "kind", `String "recovery_required"
       ; "observed_thread_id", observed_thread_json
       ; "observed_turn_id", observed_turn_json
       ; "previous_settlement", previous_json
       ; "recovery_id", `String recovery_id; "required_at", `Float required_at
       ] ->
       let* failure = recovery_failure_of_string failure in
       let* observed_thread_id =
         string_opt_of_yojson "observed_thread_id" observed_thread_json
       in
       let* observed_turn_id =
         string_opt_of_yojson "observed_turn_id" observed_turn_json
       in
       let* previous_settlement = settlement_opt_of_yojson previous_json in
       let recovery =
         { recovery_id
         ; previous_settlement
         ; observed_thread_id
         ; observed_turn_id
         ; failure
         ; detail
         ; required_at
         }
       in
       let* () = validate_recovery recovery in
       Ok (Recovery_required recovery)
     | [ "kind", `String "settled"; "thread_id", `String thread_id
       ; "turn_id", `String turn_id ] ->
       Ok (Settled { thread_id; turn_id })
     | _ -> Error "Codex session phase fields are not exact")
  | _ -> Error "Codex session phase must be a JSON object"
;;

let to_yojson binding =
  `Assoc
    [ ( "last_recovery_resolution"
      , recovery_resolution_record_opt_to_yojson
          binding.last_recovery_resolution )
    ; "runtime_id", `String binding.runtime_id
    ; "phase", phase_to_yojson binding.phase
    ; "schema", `String schema
    ; "tool_surface_sha256", `String binding.tool_surface_sha256
    ; "turn_count", `Int binding.turn_count
    ; "updated_at", `Float binding.updated_at
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "last_recovery_resolution", last_resolution_json
       ; "phase", phase_json
       ; "runtime_id", `String runtime_id
       ; "schema", `String encoded_schema
       ; "tool_surface_sha256", `String tool_surface_sha256
       ; "turn_count", `Int turn_count
       ; "updated_at", `Float updated_at
       ] ->
       if not (String.equal encoded_schema schema)
       then Error "unsupported Codex session schema"
       else
         let* phase = phase_of_yojson phase_json in
         let* last_recovery_resolution =
           recovery_resolution_record_opt_of_yojson last_resolution_json
         in
         let binding =
           { runtime_id
           ; phase
           ; turn_count
           ; tool_surface_sha256
           ; last_recovery_resolution
           ; updated_at
           }
         in
         let* () = validate binding in
         Ok binding
     | _ -> Error "Codex session fields are not exact")
  | _ -> Error "Codex session must be a JSON object"
;;

let equal left right =
  String.equal left.runtime_id right.runtime_id
  && left.phase = right.phase
  && Int.equal left.turn_count right.turn_count
  && String.equal left.tool_surface_sha256 right.tool_surface_sha256
  && left.last_recovery_resolution = right.last_recovery_resolution
  && Float.equal left.updated_at right.updated_at
;;

let load_path state_path =
  if not (Fs_compat.file_exists state_path)
  then Ok None
  else
    let* json = Safe_ops.read_json_file_safe state_path in
    let* binding = of_yojson json in
    Ok (Some binding)
;;

let load ~base_path ~keeper_name =
  let* state_path = path ~base_path ~keeper_name in
  load_path state_path
;;

let save_path ~state_dir binding =
  let* () = validate binding in
  let state_path = Filename.concat state_dir filename in
  let* () =
    match
      Keeper_fs.save_json_durable_atomic
        ~ownership_root:state_dir
        ~pretty:false
        state_path
        (to_yojson binding)
    with
    | Ok () -> Ok ()
    | Error error -> Error (Keeper_fs.durable_write_error_to_string error)
  in
  let* persisted = load_path state_path in
  match persisted with
  | Some persisted when equal persisted binding -> Ok ()
  | Some _ -> Error "Codex session changed after durable write"
  | None -> Error "Codex session missing after durable write"
;;

let prepare_state_dir ~base_path ~keeper_name =
  let* directory = state_dir ~base_path ~keeper_name in
  try
    let (_ : string) = Keeper_fs.ensure_dir directory in
    Ok directory
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let with_store_lock ~base_path ~keeper_name f =
  let* directory = prepare_state_dir ~base_path ~keeper_name in
  match
    File_lock_eio.with_durable_lock
      ~lock_path:(Filename.concat directory lock_filename)
      (fun () -> f directory)
  with
  | Ok result -> result
  | Error error -> Error (File_lock_eio.durable_lock_error_to_string error)
;;

let transition ~base_path ~keeper_name ~expected next =
  let* () = validate next in
  with_store_lock ~base_path ~keeper_name (fun directory ->
    let* current = load_path (Filename.concat directory filename) in
    if Option.equal equal current expected
    then save_path ~state_dir:directory next |> Result.map (fun () -> next)
    else Error "Codex session changed before durable transition")
;;

let claim ~base_path ~keeper_name ~expected ~runtime_id ~tool_surface_sha256
    ~updated_at =
  let* phase, turn_count =
    match expected with
    | None -> Ok (Start { previous_settlement = None }, 1)
    | Some { phase = Ready; turn_count; _ } when turn_count < Int.max_int ->
      Ok (Start { previous_settlement = None }, turn_count + 1)
    | Some { phase = Settled settlement; turn_count; _ }
      when turn_count < Int.max_int ->
      Ok (Start { previous_settlement = Some settlement }, turn_count + 1)
    | Some { phase = Ready | Settled _; _ } ->
      Error "settled Codex session turn count cannot be incremented"
    | Some { phase = Start _; _ } ->
      Error "Codex session has an incomplete thread start; refusing duplicate execution"
    | Some { phase = Active _; _ } ->
      Error "Codex session has an active unsettled attempt; refusing duplicate execution"
    | Some { phase = Turn_inflight _; _ } ->
      Error "Codex session has an in-flight turn; refusing duplicate execution"
    | Some { phase = Recovery_required recovery; _ } ->
      Error
        (Printf.sprintf
           "Codex session recovery %s must be resolved before another execution"
           recovery.recovery_id)
  in
  let last_recovery_resolution =
    Option.bind expected (fun binding -> binding.last_recovery_resolution)
  in
  transition
    ~base_path
    ~keeper_name
    ~expected
    { runtime_id
    ; phase
    ; turn_count
    ; tool_surface_sha256
    ; last_recovery_resolution
    ; updated_at
    }
;;

let mark_active ~base_path ~keeper_name ~expected ~thread_id ~updated_at =
  match expected.phase with
  | Start { previous_settlement } ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = Active { thread_id; previous_settlement }
      ; updated_at
      }
  | Ready | Active _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
    Error "Codex session can become active only from start"
;;

let mark_turn_starting ~base_path ~keeper_name ~expected ~thread_id ~updated_at =
  match expected.phase with
  | Active { thread_id = active_thread_id; previous_settlement }
    when String.equal active_thread_id thread_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = Turn_inflight { thread_id; turn_id = None; previous_settlement }
      ; updated_at
      }
  | Active _ -> Error "Codex active thread identity changed before turn start"
  | Ready | Start _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
    Error "Codex turn can start only from an active session"
;;

let mark_turn_started ~base_path ~keeper_name ~expected ~thread_id ~turn_id
    ~updated_at =
  match expected.phase with
  | Turn_inflight
      { thread_id = inflight_thread_id; turn_id = None; previous_settlement }
    when String.equal inflight_thread_id thread_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase =
          Turn_inflight
            { thread_id; turn_id = Some turn_id; previous_settlement }
      ; updated_at
      }
  | Turn_inflight { turn_id = None; _ } ->
    Error "Codex in-flight thread identity changed after turn start"
  | Turn_inflight { turn_id = Some _; _ } ->
    Error "Codex in-flight turn already has an identity"
  | Ready | Start _ | Active _ | Recovery_required _ | Settled _ ->
    Error "Codex turn identity can be recorded only for an in-flight turn"
;;

let settle ~base_path ~keeper_name ~expected ~thread_id ~turn_id ~updated_at =
  match expected.phase with
  | Turn_inflight
      { thread_id = inflight_thread_id
      ; turn_id = Some inflight_turn_id
      ; previous_settlement = _
      }
    when String.equal inflight_thread_id thread_id
         && String.equal inflight_turn_id turn_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with phase = Settled { thread_id; turn_id }; updated_at }
  | Turn_inflight _ -> Error "Codex terminal turn identity changed before settlement"
  | Ready | Start _ | Active _ | Recovery_required _ | Settled _ ->
    Error "Codex session can settle only from an identified in-flight turn"
;;

let require_recovery ~base_path ~keeper_name ~expected ~failure ~detail
    ~required_at =
  let* () = non_empty "recovery detail" detail in
  let* previous_settlement, observed_thread_id, observed_turn_id =
    match expected.phase with
    | Start { previous_settlement } ->
      Ok (previous_settlement, None, None)
    | Active { thread_id; previous_settlement } ->
      Ok (previous_settlement, Some thread_id, None)
    | Turn_inflight { thread_id; turn_id; previous_settlement } ->
      Ok (previous_settlement, Some thread_id, turn_id)
    | Ready | Settled _ ->
      Error "a settled Codex session cannot require claim recovery"
    | Recovery_required _ ->
      Error "Codex session already requires recovery"
  in
  let recovery =
    { recovery_id = fresh_recovery_id ()
    ; previous_settlement
    ; observed_thread_id
    ; observed_turn_id
    ; failure
    ; detail
    ; required_at
    }
  in
  let* () = validate_recovery recovery in
  transition
    ~base_path
    ~keeper_name
    ~expected:(Some expected)
    { expected with phase = Recovery_required recovery; updated_at = required_at }
;;

let resolve_recovery ~base_path ~keeper_name ~expected ~recovery_id ~resolution
    ~resolved_by ~resolved_at =
  let* () = non_empty "resolved_by" resolved_by in
  let* recovery =
    match expected.phase with
    | Recovery_required recovery
      when String.equal recovery.recovery_id recovery_id ->
      Ok recovery
    | Recovery_required _ ->
      Error "Codex recovery identity changed before resolution"
    | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
      Error "Codex session is not awaiting recovery"
  in
  let completed_turn_count = max 0 (expected.turn_count - 1) in
  let* phase, turn_count =
    match resolution with
    | Retry_previous ->
      Ok
        ( (match recovery.previous_settlement with
           | None -> Ready
           | Some settlement -> Settled settlement)
        , completed_turn_count )
    | Restart_fresh -> Ok (Ready, completed_turn_count)
    | Adopt_verified settlement ->
      let* () = validate_settlement settlement in
      Ok (Settled settlement, expected.turn_count)
  in
  let* resolved =
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase
      ; turn_count
      ; last_recovery_resolution =
          Some
            { recovery_id
            ; failure = recovery.failure
            ; resolution
            ; resolved_by
            ; resolved_at
            }
      ; updated_at = resolved_at
      }
  in
  Log.Keeper.info
    ~keeper_name
    "resolved Codex session recovery=%s actor=%s decision=%s"
    recovery_id
    resolved_by
    (match resolution with
     | Retry_previous -> "retry_previous"
     | Restart_fresh -> "restart_fresh"
     | Adopt_verified _ -> "adopt_verified");
  Ok resolved
;;
