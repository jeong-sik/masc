type client_kind =
  | Codex
  | Claude_code
  | Antigravity

type settlement =
  { session_id : string
  ; turn_id : string
  }

(* RFC claude-code-context-overflow-bounded-restart §6: the provider rejected the
   bootstrap input itself as over capacity. Unlike [Provider_rejected], a
   later automatic claim must not supersede this recovery — replaying the same
   durable history re-sends a request the provider already proved it will not
   admit. Only an operator resolution reopens the session.

   [Effect_fenced]: the rejection arrived after a response or tool effect was
   observed, so no in-run shrink retry was admitted either (§6.3).
   [Bootstrap_floor_exceeded]: even the smallest provider-bound view was
   rejected; since the floor already removed every shrinkable prior-history
   atom, a changed episode cannot fit either — only system prompt, goal, tool
   surface, or runtime changes can. *)
type input_rejection_reason =
  | Bootstrap_floor_exceeded
  | Effect_fenced

type recovery_failure =
  | Transient_spawn_failed
  | Owner_stopped_turn
  | Transport_interrupted
  | Protocol_failed
  | Provider_rejected
  | Input_rejected of input_rejection_reason
  | Host_hook_failed
  | State_persistence_failed
  | Process_restarted

type failure_disposition =
  | Transient
  | Ambiguous
  | Fatal

(* [Owner_stopped_turn] is transient because it is not an ambiguity: the owner
   raised the stop itself and already classifies the operation as
   Turn_cancelled. Recovery exists to get an operator's judgement on what a
   crash left behind; a stop we made with a known reason has nothing to
   adjudicate, and routing it to Recovery_required blocked every later turn for
   that keeper until someone resolved it by hand (#28012). *)
let failure_disposition = function
  | Transient_spawn_failed | Owner_stopped_turn -> Transient
  | Transport_interrupted
  | Protocol_failed
  | Host_hook_failed
  | State_persistence_failed
  | Process_restarted ->
    Ambiguous
  | Provider_rejected -> Fatal
  | Input_rejected _ -> Fatal
;;

type recovery_required =
  { recovery_id : string
  ; previous_settlement : settlement option
  ; observed_session_id : string option
  ; observed_turn_id : string option
  ; owner_epoch : string
  ; failure : recovery_failure
  ; detail : string
  ; required_at : float
  }

type phase =
  | Ready
  | Start of
      { owner_epoch : string
      ; previous_settlement : settlement option
      }
  | Active of
      { owner_epoch : string
      ; session_id : string
      ; previous_settlement : settlement option
      }
  | Turn_inflight of
      { owner_epoch : string
      ; session_id : string
      ; turn_id : string option
      ; previous_settlement : settlement option
      }
  | Recovery_required of recovery_required
  | Settled of settlement

type recovery_resolution =
  | Retry_previous
  | Restart_fresh

type recovery_resolution_application =
  | Applied
  | Replayed

type recovery_resolution_error =
  | Invalid_resolved_by
  | Invalid_resolved_at
  | Session_missing
  | Session_changed
  | Recovery_id_changed
  | Recovery_not_required
  | Retry_previous_unavailable
  | Resolution_conflict
  | Store_unavailable of string

type recovery_resolution_record =
  { recovery_id : string
  ; failure : recovery_failure
  ; resolution : recovery_resolution
  ; resolved_by : string
  ; resolved_at : float
  }

type transient_release_record =
  { failure : recovery_failure
  ; owner_epoch : string
  ; released_at : float
  }

type t =
  { client_kind : client_kind
  ; runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; tool_surface_sha256 : string
  ; last_recovery_resolution : recovery_resolution_record option
  ; last_transient_release : transient_release_record option
  ; updated_at : float
  }

type claim_plan =
  { previous_settlement : settlement option
  ; turn_count : int
  ; required_tool_surface_sha256 : string option
  }

let ( let* ) = Result.bind
let schema = "masc.keeper.official-client-session.v1"
let filename = "session.json"
let state_dirname = "official-client-runtime"
let lock_filename = "session.lock"
let recovery_rng = Random.State.make_self_init ()
let recovery_rng_mutex = Stdlib.Mutex.create ()

let fresh_recovery_id () =
  Stdlib.Mutex.protect recovery_rng_mutex (fun () ->
    Uuidm.v4_gen recovery_rng () |> Uuidm.to_string)
;;

let process_epoch_value = lazy (fresh_recovery_id ())
let process_epoch () = Lazy.force process_epoch_value

let state_dir ~base_path ~keeper_name =
  if not (Safe_identifier.is_portable_name keeper_name)
  then Error (Printf.sprintf "invalid official-client Keeper name %S" keeper_name)
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

let tool_surface_sha256 ~native_posture tools =
  let tool_json (tool : Agent_core.Tool.t) =
    let parameters =
      List.sort
        (fun (left : Agent_core.Types.tool_param) right ->
           String.compare left.name right.name)
        tool.schema.parameters
    in
    `Assoc
      [ "description", `String tool.schema.description
      ; "input_schema", Agent_core.Types.params_to_input_schema parameters
      ; "name", `String tool.schema.name
      ]
    |> canonical_json
  in
  tools
  |> List.sort (fun (left : Agent_core.Tool.t) right ->
    String.compare left.schema.name right.schema.name)
  |> List.map tool_json
  |> fun tools ->
  `Assoc
    [ ( "context_message_schema"
      , `String Keeper_official_client_context_codec.schema )
    ; ( "native_posture"
      , `String (Runtime_native_tools.to_string native_posture) )
    ; "tools", `List tools
    ]
  |> canonical_json
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

(* Shared with [Types_auth.is_sha256_hex] and the capability heads rather
   than decided again here. *)
let valid_sha256 = String_util.is_lowercase_sha256_hex
;;

let non_empty field value =
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "official-client session %s must not be empty" field)
  else Ok ()
;;

let validate_uuid field value =
  if Option.is_some (Uuidm.of_string value)
  then Ok ()
  else Error (Printf.sprintf "official-client session %s must be a UUID" field)
;;

let validate_settlement { session_id; turn_id } =
  let* () = non_empty "session_id" session_id in
  non_empty "turn_id" turn_id
;;

let validate_settlement_opt = function
  | None -> Ok ()
  | Some settlement -> validate_settlement settlement
;;

let validate_recovery (recovery : recovery_required) =
  let* () = validate_uuid "recovery_id" recovery.recovery_id in
  let* () = validate_uuid "owner_epoch" recovery.owner_epoch in
  let* () = validate_settlement_opt recovery.previous_settlement in
  let* () =
    match recovery.observed_session_id with
    | None -> Ok ()
    | Some session_id -> non_empty "observed_session_id" session_id
  in
  let* () =
    match recovery.observed_turn_id, recovery.observed_session_id with
    | None, _ -> Ok ()
    | Some turn_id, Some _ -> non_empty "observed_turn_id" turn_id
    | Some _, None ->
      Error "official-client recovery observed_turn_id requires observed_session_id"
  in
  let* () = non_empty "recovery detail" recovery.detail in
  if Float.is_finite recovery.required_at
  then Ok ()
  else Error "official-client recovery required_at must be finite"
;;

let validate_recovery_resolution = function
  | Retry_previous | Restart_fresh -> Ok ()
;;

let validate_recovery_resolution_record (record : recovery_resolution_record) =
  let* () = validate_uuid "resolved recovery_id" record.recovery_id in
  let* () = validate_recovery_resolution record.resolution in
  let* () = non_empty "resolved_by" record.resolved_by in
  if Float.is_finite record.resolved_at
  then Ok ()
  else Error "official-client recovery resolved_at must be finite"
;;

let validate_transient_release_record (record : transient_release_record) =
  let* () =
    match failure_disposition record.failure with
    | Transient -> Ok ()
    | Ambiguous | Fatal ->
      Error "official-client transient release must contain a transient failure"
  in
  let* () = validate_uuid "transient owner_epoch" record.owner_epoch in
  if Float.is_finite record.released_at
  then Ok ()
  else Error "official-client transient released_at must be finite"
;;

let validate_phase = function
  | Ready -> Ok ()
  | Start { owner_epoch; previous_settlement } ->
    let* () = validate_uuid "owner_epoch" owner_epoch in
    validate_settlement_opt previous_settlement
  | Active { owner_epoch; session_id; previous_settlement }
  | Turn_inflight
      { owner_epoch; session_id; turn_id = None; previous_settlement } ->
    let* () = validate_uuid "owner_epoch" owner_epoch in
    let* () = non_empty "session_id" session_id in
    validate_settlement_opt previous_settlement
  | Turn_inflight
      { owner_epoch
      ; session_id
      ; turn_id = Some turn_id
      ; previous_settlement
      } ->
    let* () = validate_uuid "owner_epoch" owner_epoch in
    let* () = non_empty "session_id" session_id in
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
  let* () =
    match binding.last_transient_release with
    | None -> Ok ()
    | Some record -> validate_transient_release_record record
  in
  if binding.turn_count < 0
  then Error "official-client session turn_count must be non-negative"
  else if binding.turn_count = 0 && binding.phase <> Ready
  then Error "only a ready official-client session may have zero completed turns"
  else if not (valid_sha256 binding.tool_surface_sha256)
  then Error "official-client session tool_surface_sha256 must be lowercase SHA-256"
  else if not (Float.is_finite binding.updated_at)
  then Error "official-client session updated_at must be finite"
  else Ok ()
;;

let settlement_to_yojson settlement =
  `Assoc
    [ "session_id", `String settlement.session_id
    ; "turn_id", `String settlement.turn_id
    ]
;;

let settlement_opt_to_yojson = function
  | None -> `Null
  | Some settlement -> settlement_to_yojson settlement
;;

let settlement_of_yojson = function
  | `Assoc [ "session_id", `String session_id; "turn_id", `String turn_id ]
  | `Assoc [ "turn_id", `String turn_id; "session_id", `String session_id ] ->
    let settlement = { session_id; turn_id } in
    let* () = validate_settlement settlement in
    Ok settlement
  | _ -> Error "official-client settlement fields are not exact"
;;

let settlement_opt_of_yojson = function
  | `Null -> Ok None
  | json -> Result.map Option.some (settlement_of_yojson json)
;;

let recovery_failure_to_string = function
  | Transient_spawn_failed -> "transient_spawn_failed"
  | Owner_stopped_turn -> "owner_stopped_turn"
  | Transport_interrupted -> "transport_interrupted"
  | Protocol_failed -> "protocol_failed"
  | Provider_rejected -> "provider_rejected"
  | Input_rejected Bootstrap_floor_exceeded ->
    "input_rejected_bootstrap_floor_exceeded"
  | Input_rejected Effect_fenced -> "input_rejected_effect_fenced"
  | Host_hook_failed -> "host_hook_failed"
  | State_persistence_failed -> "state_persistence_failed"
  | Process_restarted -> "process_restarted"
;;

let recovery_failure_of_string = function
  | "transient_spawn_failed" -> Ok Transient_spawn_failed
  | "owner_stopped_turn" -> Ok Owner_stopped_turn
  | "transport_interrupted" -> Ok Transport_interrupted
  | "protocol_failed" -> Ok Protocol_failed
  | "provider_rejected" -> Ok Provider_rejected
  | "input_rejected_bootstrap_floor_exceeded" ->
    Ok (Input_rejected Bootstrap_floor_exceeded)
  | "input_rejected_effect_fenced" -> Ok (Input_rejected Effect_fenced)
  | "host_hook_failed" -> Ok Host_hook_failed
  | "state_persistence_failed" -> Ok State_persistence_failed
  | "process_restarted" -> Ok Process_restarted
  | _ -> Error "unknown official-client recovery failure"
;;

let client_kind_to_string = function
  | Codex -> "codex"
  | Claude_code -> "claude_code"
  | Antigravity -> "antigravity"
;;

let client_kind_of_string = function
  | "codex" -> Ok Codex
  | "claude_code" -> Ok Claude_code
  | "antigravity" -> Ok Antigravity
  | _ -> Error "unknown official-client kind"
;;

let recovery_resolution_to_yojson = function
  | Retry_previous -> `Assoc [ "kind", `String "retry_previous" ]
  | Restart_fresh -> `Assoc [ "kind", `String "restart_fresh" ]
;;

let recovery_resolution_of_yojson = function
  | `Assoc [ "kind", `String "retry_previous" ] -> Ok Retry_previous
  | `Assoc [ "kind", `String "restart_fresh" ] -> Ok Restart_fresh
  | `Assoc _ -> Error "official-client recovery resolution fields are not exact"
  | _ -> Error "official-client recovery resolution must be a JSON object"
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
     | _ -> Error "official-client recovery resolution record fields are not exact")
  | _ -> Error "official-client recovery resolution record must be a JSON object"
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

let transient_release_record_to_yojson (record : transient_release_record) =
  `Assoc
    [ "failure", `String (recovery_failure_to_string record.failure)
    ; "owner_epoch", `String record.owner_epoch
    ; "released_at", `Float record.released_at
    ]
;;

let transient_release_record_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "failure", `String failure; "owner_epoch", `String owner_epoch
       ; "released_at", `Float released_at ] ->
       let* failure = recovery_failure_of_string failure in
       let record = { failure; owner_epoch; released_at } in
       let* () = validate_transient_release_record record in
       Ok record
     | _ -> Error "official-client transient release fields are not exact")
  | _ -> Error "official-client transient release must be a JSON object"
;;

let transient_release_record_opt_to_yojson = function
  | None -> `Null
  | Some record -> transient_release_record_to_yojson record
;;

let transient_release_record_opt_of_yojson = function
  | `Null -> Ok None
  | json -> Result.map Option.some (transient_release_record_of_yojson json)
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
  | _ -> Error (Printf.sprintf "official-client recovery %s must be string or null" field)
;;

let phase_to_yojson = function
  | Ready -> `Assoc [ "kind", `String "ready" ]
  | Start { owner_epoch; previous_settlement } ->
    `Assoc
      [ "kind", `String "start"
      ; "owner_epoch", `String owner_epoch
      ; "previous_settlement", settlement_opt_to_yojson previous_settlement
      ]
  | Active { owner_epoch; session_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "active"
      ; "owner_epoch", `String owner_epoch
      ; "previous_settlement", settlement_opt_to_yojson previous_settlement
      ; "session_id", `String session_id
      ]
  | Turn_inflight { owner_epoch; session_id; turn_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "turn_inflight"
      ; "owner_epoch", `String owner_epoch
      ; "previous_settlement", settlement_opt_to_yojson previous_settlement
      ; "session_id", `String session_id
      ; ( "turn_id"
        , Option.fold ~none:`Null ~some:(fun turn_id -> `String turn_id) turn_id )
      ]
  | Recovery_required recovery ->
    `Assoc
      [ "detail", `String recovery.detail
      ; "failure", `String (recovery_failure_to_string recovery.failure)
      ; "kind", `String "recovery_required"
      ; "observed_session_id", string_opt_to_yojson recovery.observed_session_id
      ; "observed_turn_id", string_opt_to_yojson recovery.observed_turn_id
      ; "owner_epoch", `String recovery.owner_epoch
      ; ( "previous_settlement"
        , settlement_opt_to_yojson recovery.previous_settlement )
      ; "recovery_id", `String recovery.recovery_id
      ; "required_at", `Float recovery.required_at
      ]
  | Settled { session_id; turn_id } ->
    `Assoc
      [ "kind", `String "settled"
      ; "session_id", `String session_id
      ; "turn_id", `String turn_id
      ]
;;

let phase_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "ready" ] -> Ok Ready
     | [ "kind", `String "start"; "owner_epoch", `String owner_epoch
       ; "previous_settlement", previous ] ->
       let* previous_settlement = settlement_opt_of_yojson previous in
       Ok (Start { owner_epoch; previous_settlement })
     | [ "kind", `String "active"; "owner_epoch", `String owner_epoch
       ; "previous_settlement", previous
       ; "session_id", `String session_id ] ->
       let* previous_settlement = settlement_opt_of_yojson previous in
       Ok (Active { owner_epoch; session_id; previous_settlement })
     | [ "kind", `String "turn_inflight"; "owner_epoch", `String owner_epoch
       ; "previous_settlement", previous
       ; "session_id", `String session_id; "turn_id", turn_id_json ] ->
       let* previous_settlement = settlement_opt_of_yojson previous in
       let* turn_id = string_opt_of_yojson "observed_turn_id" turn_id_json in
       Ok (Turn_inflight { owner_epoch; session_id; turn_id; previous_settlement })
     | [ "detail", `String detail; "failure", `String failure
       ; "kind", `String "recovery_required"
       ; "observed_session_id", observed_session_json
       ; "observed_turn_id", observed_turn_json
       ; "owner_epoch", `String owner_epoch
       ; "previous_settlement", previous_json
       ; "recovery_id", `String recovery_id; "required_at", `Float required_at
       ] ->
       let* failure = recovery_failure_of_string failure in
       let* observed_session_id =
         string_opt_of_yojson "observed_session_id" observed_session_json
       in
       let* observed_turn_id =
         string_opt_of_yojson "observed_turn_id" observed_turn_json
       in
       let* previous_settlement = settlement_opt_of_yojson previous_json in
       let recovery =
         { recovery_id
         ; previous_settlement
         ; observed_session_id
         ; observed_turn_id
         ; owner_epoch
         ; failure
         ; detail
         ; required_at
         }
       in
       let* () = validate_recovery recovery in
       Ok (Recovery_required recovery)
     | [ "kind", `String "settled"; "session_id", `String session_id
       ; "turn_id", `String turn_id ] ->
       Ok (Settled { session_id; turn_id })
     | _ -> Error "official-client session phase fields are not exact")
  | _ -> Error "official-client session phase must be a JSON object"
;;

let to_yojson binding =
  `Assoc
    [ "client_kind", `String (client_kind_to_string binding.client_kind)
    ; ( "last_recovery_resolution"
      , recovery_resolution_record_opt_to_yojson
          binding.last_recovery_resolution )
    ; ( "last_transient_release"
      , transient_release_record_opt_to_yojson binding.last_transient_release )
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
     | [ "client_kind", `String client_kind_json
       ; "last_recovery_resolution", last_resolution_json
       ; "last_transient_release", last_transient_release_json
       ; "phase", phase_json
       ; "runtime_id", `String runtime_id
       ; "schema", `String encoded_schema
       ; "tool_surface_sha256", `String tool_surface_sha256
       ; "turn_count", `Int turn_count
       ; "updated_at", `Float updated_at
       ] ->
       if not (String.equal encoded_schema schema)
       then Error "unsupported official-client session schema"
       else
         let* client_kind = client_kind_of_string client_kind_json in
         let* phase = phase_of_yojson phase_json in
         let* last_recovery_resolution =
           recovery_resolution_record_opt_of_yojson last_resolution_json
         in
         let* last_transient_release =
           transient_release_record_opt_of_yojson last_transient_release_json
         in
         let binding =
           { client_kind
           ; runtime_id
           ; phase
           ; turn_count
           ; tool_surface_sha256
           ; last_recovery_resolution
           ; last_transient_release
           ; updated_at
           }
         in
         let* () = validate binding in
         Ok binding
     | _ -> Error "official-client session fields are not exact")
  | _ -> Error "official-client session must be a JSON object"
;;

let equal left right =
  left.client_kind = right.client_kind
  && String.equal left.runtime_id right.runtime_id
  && left.phase = right.phase
  && Int.equal left.turn_count right.turn_count
  && String.equal left.tool_surface_sha256 right.tool_surface_sha256
  && left.last_recovery_resolution = right.last_recovery_resolution
  && left.last_transient_release = right.last_transient_release
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
  | Some _ -> Error "official-client session changed after durable write"
  | None -> Error "official-client session missing after durable write"
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
    else Error "official-client session changed before durable transition")
;;

let plan_claim ~expected ~client_kind ~runtime_id =
  let* () = non_empty "runtime_id" runtime_id in
  let* previous_settlement, turn_count, required_tool_surface_sha256 =
    match expected with
    | None -> Ok (None, 1, None)
    | Some ({ phase = Ready; _ } as binding)
      when binding.client_kind <> client_kind
           || not (String.equal binding.runtime_id runtime_id) ->
      Ok (None, 1, None)
    | Some { phase = Ready; turn_count; _ } when turn_count < Int.max_int ->
      Ok (None, turn_count + 1, None)
    | Some ({ phase = Settled _; _ } as binding)
      when binding.client_kind <> client_kind
           || not (String.equal binding.runtime_id runtime_id) ->
      Ok (None, 1, None)
    | Some ({ phase = Recovery_required _; _ } as binding)
      when binding.client_kind <> client_kind
           || not (String.equal binding.runtime_id runtime_id) ->
      Ok (None, 1, None)
    (* RFC claude-code-context-overflow-bounded-restart §6.2: an input
       rejection is not auto-superseded on the same runtime. The provider
       already proved it will not admit this bootstrap episode, so a fresh
       claim would re-send the identical over-capacity request every cycle
       (observed live: two keepers replaying ~1.27M-token requests per
       heartbeat on 2026-08-23). A different client_kind/runtime_id still
       starts fresh above — that branch is operator-driven, not a heartbeat
       replay. Re-entry needs [resolve_recovery] (restart_fresh after the
       keeper context is compacted, or retry_previous). *)
    | Some
        { phase =
            Recovery_required
              { failure = Input_rejected reason; recovery_id; _ }
        ; _
        } ->
      Error
        (Printf.sprintf
           "official-client session input_rejected(%s): provider rejected the \
            bootstrap input as over capacity; automatic re-entry is blocked \
            until recovery %s is resolved by an operator"
           (match reason with
            | Bootstrap_floor_exceeded -> "bootstrap_floor_exceeded"
            | Effect_fenced -> "effect_fenced")
           recovery_id)
    | Some
        { phase = Settled settlement
        ; turn_count
        ; tool_surface_sha256
        ; _
        }
      when turn_count < Int.max_int ->
      Ok (Some settlement, turn_count + 1, Some tool_surface_sha256)
    | Some { phase = Ready | Settled _; _ } ->
      Error "settled official-client session turn count cannot be incremented"
    | Some { phase = Start _; _ } ->
      Error "official-client session has an incomplete start; refusing duplicate execution"
    | Some { phase = Active _; _ } ->
      Error "official-client session has an active unsettled attempt; refusing duplicate execution"
    | Some { phase = Turn_inflight _; _ } ->
      Error "official-client session has an in-flight turn; refusing duplicate execution"
    | Some { phase = Recovery_required _; _ } -> Ok (None, 1, None)
  in
  Ok { previous_settlement; turn_count; required_tool_surface_sha256 }
;;

(* A settled session whose tool surface has moved is not resumable, and it was
   not recoverable either: [Settled] is a healthy phase, so nothing marks it
   [Recovery_required], and the resolve endpoint has no id to act on. Every
   turn ended in config_error until an operator deleted the durable file.

   [plan_claim] already treats a changed [client_kind] or [runtime_id] as a
   fresh session rather than a refusal, on the same reasoning: what the prior
   session settled against no longer describes this execution. A changed tool
   surface is that same change, so it takes that same branch.

   Deployments move this digest. Adding a tool, or editing a descriptor, is
   enough -- which is why a refusal here strands every settled session on the
   next release (#27992). *)
let reconcile_tool_surface plan ~tool_surface_sha256 =
  match plan.required_tool_surface_sha256 with
  | None -> plan
  | Some stored when String.equal stored tool_surface_sha256 -> plan
  | Some _ ->
    { previous_settlement = None; turn_count = 1; required_tool_surface_sha256 = None }
;;

let claim ~base_path ~keeper_name ~expected ~client_kind ~owner_epoch ~runtime_id
    ~tool_surface_sha256 ~updated_at =
  let* () = validate_uuid "owner_epoch" owner_epoch in
  let* plan = plan_claim ~expected ~client_kind ~runtime_id in
  let plan = reconcile_tool_surface plan ~tool_surface_sha256 in
  let last_recovery_resolution =
    Option.bind expected (fun binding -> binding.last_recovery_resolution)
  in
  let* claimed =
    transition
      ~base_path
      ~keeper_name
      ~expected
      { client_kind
      ; runtime_id
      ; phase = Start { owner_epoch; previous_settlement = plan.previous_settlement }
      ; turn_count = plan.turn_count
      ; tool_surface_sha256
      ; last_recovery_resolution
      ; last_transient_release = Option.bind expected (fun binding -> binding.last_transient_release)
      ; updated_at
      }
  in
  (match expected with
   | Some { phase = Recovery_required recovery; _ } ->
     Log.Keeper.info
       ~keeper_name
       "auto-superseded official-client recovery=%s failure=%s with a fresh session owner_epoch=%s"
       recovery.recovery_id
       (recovery_failure_to_string recovery.failure)
       owner_epoch
   | Some _ | None -> ());
  Ok claimed
;;

let mark_active ~base_path ~keeper_name ~expected ~session_id ~updated_at =
  match expected.phase with
  | Start { owner_epoch; previous_settlement } ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = Active { owner_epoch; session_id; previous_settlement }
      ; updated_at
      }
  | Ready | Active _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
    Error "official-client session can become active only from start"
;;

let mark_turn_starting ~base_path ~keeper_name ~expected ~session_id ~updated_at =
  match expected.phase with
  | Active { owner_epoch; session_id = active_session_id; previous_settlement }
    when String.equal active_session_id session_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase =
          Turn_inflight
            { owner_epoch; session_id; turn_id = None; previous_settlement }
      ; updated_at
      }
  | Active _ -> Error "official-client session identity changed before turn start"
  | Ready | Start _ | Turn_inflight _ | Recovery_required _ | Settled _ ->
    Error "official-client turn can start only from an active session"
;;

let mark_turn_started ~base_path ~keeper_name ~expected ~session_id ~turn_id
    ~turn_count ~updated_at =
  match expected.phase with
  | Turn_inflight
      { owner_epoch
      ; session_id = inflight_session_id
      ; turn_id = None
      ; previous_settlement
      }
    when String.equal inflight_session_id session_id ->
    if turn_count < expected.turn_count
    then Error "official-client observed turn count regressed after turn start"
    else
      transition
        ~base_path
        ~keeper_name
        ~expected:(Some expected)
        { expected with
          phase =
            Turn_inflight
              { owner_epoch
              ; session_id
              ; turn_id = Some turn_id
              ; previous_settlement
              }
        ; turn_count
        ; updated_at
        }
  | Turn_inflight { turn_id = None; _ } ->
    Error "official-client in-flight session identity changed after turn start"
  | Turn_inflight { turn_id = Some _; _ } ->
    Error "official-client in-flight turn already has an identity"
  | Ready | Start _ | Active _ | Recovery_required _ | Settled _ ->
    Error "official-client turn identity can be recorded only for an in-flight turn"
;;

let settle ~base_path ~keeper_name ~expected ~session_id ~turn_id ~updated_at =
  match expected.phase with
  | Turn_inflight
      { session_id = inflight_session_id
      ; turn_id = Some inflight_turn_id
      ; previous_settlement = _
      }
    when String.equal inflight_session_id session_id
         && String.equal inflight_turn_id turn_id ->
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with phase = Settled { session_id; turn_id }; updated_at }
  | Turn_inflight _ ->
    Error "official-client terminal turn identity changed before settlement"
  | Ready | Start _ | Active _ | Recovery_required _ | Settled _ ->
    Error "official-client session can settle only from an identified in-flight turn"
;;

let require_recovery ~base_path ~keeper_name ~expected ~failure ~detail
    ~required_at =
  let* () = non_empty "recovery detail" detail in
  let* () =
    match failure_disposition failure with
    | Ambiguous | Fatal -> Ok ()
    | Transient ->
      Error "transient official-client failures must use release_transient"
  in
  let* owner_epoch, previous_settlement, observed_session_id, observed_turn_id =
    match expected.phase with
    | Start { owner_epoch; previous_settlement } ->
      Ok (owner_epoch, previous_settlement, None, None)
    | Active { owner_epoch; session_id; previous_settlement } ->
      Ok (owner_epoch, previous_settlement, Some session_id, None)
    | Turn_inflight { owner_epoch; session_id; turn_id; previous_settlement } ->
      Ok (owner_epoch, previous_settlement, Some session_id, turn_id)
    | Ready | Settled _ ->
      Error "a settled official-client session cannot require claim recovery"
    | Recovery_required _ ->
      Error "official-client session already requires recovery"
  in
  let recovery =
    { recovery_id = fresh_recovery_id ()
    ; previous_settlement
    ; observed_session_id
    ; observed_turn_id
    ; owner_epoch
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

let incomplete_claim = function
  | Start { owner_epoch; previous_settlement } ->
    Some (owner_epoch, previous_settlement)
  | Active { owner_epoch; previous_settlement; _ }
  | Turn_inflight { owner_epoch; previous_settlement; _ } ->
    Some (owner_epoch, previous_settlement)
  | Ready | Recovery_required _ | Settled _ -> None
;;

let restored_phase previous_settlement =
  match previous_settlement with
  | None -> Ready
  | Some settlement -> Settled settlement
;;

let release_transient ~base_path ~keeper_name ~expected ~failure ~released_at =
  let* () =
    match failure_disposition failure with
    | Transient -> Ok ()
    | Ambiguous | Fatal ->
      Error "only transient official-client failures may release automatically"
  in
  let* owner_epoch, previous_settlement =
    match incomplete_claim expected.phase with
    | Some claim -> Ok claim
    | None -> Error "official-client session has no incomplete claim to release"
  in
  let turn_count = max 0 (expected.turn_count - 1) in
  let* released =
    transition
      ~base_path
      ~keeper_name
      ~expected:(Some expected)
      { expected with
        phase = restored_phase previous_settlement
      ; turn_count
      ; last_transient_release = Some { failure; owner_epoch; released_at }
      ; updated_at = released_at
      }
  in
  Log.Keeper.info
    ~keeper_name
    "auto-released transient official-client claim owner_epoch=%s failure=%s"
    owner_epoch
    (recovery_failure_to_string failure);
  Ok released
;;

let reconcile_process_restart ~base_path ~keeper_name ~expected
    ~current_owner_epoch ~required_at =
  let* () = validate_uuid "current_owner_epoch" current_owner_epoch in
  match incomplete_claim expected.phase with
  | None -> Ok expected
  | Some (owner_epoch, _) when String.equal owner_epoch current_owner_epoch ->
    Error "official-client claim is still owned by the current process epoch"
  | Some (owner_epoch, _) ->
    require_recovery
      ~base_path
      ~keeper_name
      ~expected
      ~failure:Process_restarted
      ~detail:
        (Printf.sprintf
           "MASC process epoch changed while an official-client claim was incomplete: previous=%s current=%s"
           owner_epoch
           current_owner_epoch)
      ~required_at
;;

let resolve_recovery ~base_path ~keeper_name ~expected ~recovery_id ~resolution
    ~resolved_by ~resolved_at =
  let ( let* ) = Result.bind in
  let* () =
    match non_empty "resolved_by" resolved_by with
    | Ok () -> Ok ()
    | Error _ -> Error Invalid_resolved_by
  in
  let* () =
    if Float.is_finite resolved_at then Ok () else Error Invalid_resolved_at
  in
  let replay (current : t) =
    match current.last_recovery_resolution with
    | Some record when String.equal record.recovery_id recovery_id ->
      if record.resolution = resolution
      then Ok (current, Replayed)
      else Error Resolution_conflict
    | Some _ | None -> Error Recovery_not_required
  in
  let apply directory (current : t) (recovery : recovery_required) =
    let* phase, turn_count =
      match resolution with
      | Retry_previous ->
        (* The conversation is kept, so only the turn that failed is dropped and
           the next claim re-attempts the same ordinal against it. *)
        (match recovery.previous_settlement with
         | None -> Error Retry_previous_unavailable
         | Some settlement -> Ok (Settled settlement, current.turn_count - 1))
      | Restart_fresh ->
        (* Restart abandons the conversation, so the ordinal restarts with it and
           the next claim asks for ordinal 1 -- what a fresh provider conversation
           reports. This is the same reset the automatic supersede already does
           ([plan_claim]'s [Recovery_required] arm). Carrying
           [current.turn_count - 1] across the discard left the operator's
           explicit restart counting from a conversation that no longer exists,
           and since the observed provider count became authoritative it also
           made the next turn fail [mark_turn_started]'s regression guard. *)
        Ok (Ready, 0)
    in
    let resolved =
      { current with
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
    let* () =
      match save_path ~state_dir:directory resolved with
      | Ok () -> Ok ()
      | Error detail -> Error (Store_unavailable detail)
    in
    Log.Keeper.info
      ~keeper_name
      "resolved official-client session recovery=%s actor=%s decision=%s"
      recovery_id
      resolved_by
      (match resolution with
       | Retry_previous -> "retry_previous"
       | Restart_fresh -> "restart_fresh");
    Ok (resolved, Applied)
  in
  match prepare_state_dir ~base_path ~keeper_name with
  | Error detail -> Error (Store_unavailable detail)
  | Ok directory ->
    (match
       File_lock_eio.with_durable_lock
         ~lock_path:(Filename.concat directory lock_filename)
         (fun () ->
      let* current =
        match load_path (Filename.concat directory filename) with
        | Ok current -> Ok current
        | Error detail -> Error (Store_unavailable detail)
      in
      match current with
      | None -> Error Session_missing
      | Some current when not (equal current expected) ->
        (match replay current with
         | Ok replayed -> Ok replayed
         | Error Recovery_not_required -> Error Session_changed
         | Error error -> Error error)
      | Some current ->
        (match current.phase with
         | Recovery_required recovery
           when String.equal recovery.recovery_id recovery_id ->
           apply directory current recovery
         | Recovery_required _ -> Error Recovery_id_changed
         | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ -> replay current))
     with
     | Ok result -> result
     | Error detail ->
       Error
         (Store_unavailable
            (File_lock_eio.durable_lock_error_to_string detail)))
;;
