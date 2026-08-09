type error_kind =
  | Bad_request
  | Conflict
  | Service_unavailable

type error =
  { kind : error_kind
  ; code : string
  ; message : string
  }

let ( let* ) = Result.bind
let schema = "masc.dashboard.official-client-session.v1"

let error kind code message = Error { kind; code; message }

let client_kind_to_string = function
  | Keeper_official_client_session_store.Codex -> "codex"
  | Claude_code -> "claude_code"
  | Antigravity -> "antigravity"
;;

let failure_to_string = function
  | Keeper_official_client_session_store.Transient_spawn_failed ->
    "transient_spawn_failed"
  | Transport_interrupted -> "transport_interrupted"
  | Protocol_failed -> "protocol_failed"
  | Provider_rejected -> "provider_rejected"
  | Host_hook_failed -> "host_hook_failed"
  | State_persistence_failed -> "state_persistence_failed"
  | Process_restarted -> "process_restarted"
;;

let settlement_json (settlement : Keeper_official_client_session_store.settlement) =
  `Assoc
    [ "session_id", `String settlement.session_id
    ; "turn_id", `String settlement.turn_id
    ]
;;

let settlement_opt_json = function
  | None -> `Null
  | Some settlement -> settlement_json settlement
;;

let string_opt_json = function
  | None -> `Null
  | Some value -> `String value
;;

let resolution_json = function
  | Keeper_official_client_session_store.Retry_previous ->
    `Assoc [ "kind", `String "retry_previous" ]
  | Restart_fresh -> `Assoc [ "kind", `String "restart_fresh" ]
;;

let resolution_record_json
    (record : Keeper_official_client_session_store.recovery_resolution_record) =
  `Assoc
    [ "failure", `String (failure_to_string record.failure)
    ; "recovery_id", `String record.recovery_id
    ; "resolution", resolution_json record.resolution
    ; "resolved_at", `Float record.resolved_at
    ; "resolved_by", `String record.resolved_by
    ]
;;

let transient_release_record_json
    (record : Keeper_official_client_session_store.transient_release_record) =
  `Assoc
    [ "failure", `String (failure_to_string record.failure)
    ; "owner_epoch", `String record.owner_epoch
    ; "released_at", `Float record.released_at
    ]
;;

let phase_json = function
  | Keeper_official_client_session_store.Ready -> `Assoc [ "kind", `String "ready" ]
  | Start { owner_epoch; previous_settlement } ->
    `Assoc
      [ "kind", `String "start"
      ; "owner_epoch", `String owner_epoch
      ; "previous_settlement", settlement_opt_json previous_settlement
      ]
  | Active { owner_epoch; session_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "active"
      ; "owner_epoch", `String owner_epoch
      ; "session_id", `String session_id
      ; "previous_settlement", settlement_opt_json previous_settlement
      ]
  | Turn_inflight { owner_epoch; session_id; turn_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "turn_inflight"
      ; "owner_epoch", `String owner_epoch
      ; "session_id", `String session_id
      ; "turn_id", string_opt_json turn_id
      ; "previous_settlement", settlement_opt_json previous_settlement
      ]
  | Recovery_required recovery ->
    `Assoc
      [ "kind", `String "recovery_required"
      ; "recovery_id", `String recovery.recovery_id
      ; "failure", `String (failure_to_string recovery.failure)
      ; "detail", `String recovery.detail
      ; "required_at", `Float recovery.required_at
      ; "owner_epoch", `String recovery.owner_epoch
      ; "observed_session_id", string_opt_json recovery.observed_session_id
      ; "observed_turn_id", string_opt_json recovery.observed_turn_id
      ; ( "previous_settlement"
        , settlement_opt_json recovery.previous_settlement )
      ]
  | Settled settlement ->
    `Assoc
      [ "kind", `String "settled"
      ; "session_id", `String settlement.session_id
      ; "turn_id", `String settlement.turn_id
      ]
;;

let binding_json (binding : Keeper_official_client_session_store.t) =
  `Assoc
    [ "client_kind", `String (client_kind_to_string binding.client_kind)
    ; "runtime_id", `String binding.runtime_id
    ; "phase", phase_json binding.phase
    ; "turn_count", `Int binding.turn_count
    ; "tool_surface_sha256", `String binding.tool_surface_sha256
    ; ( "last_recovery_resolution"
      , Option.fold
          ~none:`Null
          ~some:resolution_record_json
          binding.last_recovery_resolution )
    ; ( "last_transient_release"
      , Option.fold
          ~none:`Null
          ~some:transient_release_record_json
          binding.last_transient_release )
    ; "updated_at", `Float binding.updated_at
    ]
;;

let response_json ~keeper_name session =
  `Assoc
    [ "schema", `String schema
    ; "ok", `Bool true
    ; "keeper_name", `String keeper_name
    ; "session", Option.fold ~none:`Null ~some:binding_json session
    ]
;;

let validate_keeper_name keeper_name =
  let keeper_name = String.trim keeper_name in
  if keeper_name = ""
  then error Bad_request "keeper_name_required" "keeper_name is required"
  else if not (Keeper_config.validate_name keeper_name)
  then
    error
      Bad_request
      "keeper_name_invalid"
      (Printf.sprintf "invalid keeper_name %S" keeper_name)
  else Ok keeper_name
;;

let load ~base_path ~keeper_name =
  match Keeper_official_client_session_store.load ~base_path ~keeper_name with
  | Ok session -> Ok session
  | Error message ->
    error
      Service_unavailable
      "official_client_session_load_failed"
      message
;;

let snapshot ~base_path ~keeper_name =
  let* keeper_name = validate_keeper_name keeper_name in
  let* session = load ~base_path ~keeper_name in
  Ok (response_json ~keeper_name session)
;;

type request =
  { keeper_name : string
  ; recovery_id : string
  ; resolution : Keeper_official_client_session_store.recovery_resolution
  }

let non_empty field value =
  let value = String.trim value in
  if value = ""
  then error Bad_request (field ^ "_required") (field ^ " is required")
  else Ok value
;;

let parse_body body =
  let* json =
    try Ok (Yojson.Safe.from_string body) with
    | Yojson.Json_error message ->
      error Bad_request "invalid_json" ("invalid JSON: " ^ message)
  in
  match json with
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "keeper_name", `String keeper_name
       ; "recovery_id", `String recovery_id
       ; "resolution", `String ("retry_previous" as resolution) ]
     | [ "keeper_name", `String keeper_name
       ; "recovery_id", `String recovery_id
       ; "resolution", `String ("restart_fresh" as resolution) ] ->
       let* keeper_name = validate_keeper_name keeper_name in
       let* recovery_id = non_empty "recovery_id" recovery_id in
       let resolution =
         if String.equal resolution "retry_previous"
         then Keeper_official_client_session_store.Retry_previous
         else Restart_fresh
       in
       Ok { keeper_name; recovery_id; resolution }
     | _ ->
       error
         Bad_request
         "request_fields_invalid"
         "expected exact keeper_name, recovery_id, resolution fields")
  | _ -> error Bad_request "request_not_object" "request body must be a JSON object"
;;

let conflict code message = error Conflict code message

let resolve_body ~base_path ~actor ~body =
  let* request = parse_body body in
  let* actor = non_empty "actor" actor in
  let* current = load ~base_path ~keeper_name:request.keeper_name in
  let* current =
    match current with
    | None ->
      conflict
        "official_client_session_missing"
        "Keeper has no durable official-client session"
    | Some current -> Ok current
  in
  let* recovery =
    match current.phase with
    | Keeper_official_client_session_store.Recovery_required recovery
      when String.equal recovery.recovery_id request.recovery_id ->
      Ok recovery
    | Recovery_required _ ->
      conflict
        "recovery_id_changed"
        "official-client recovery identity changed before resolution"
    | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
      conflict
        "recovery_not_required"
        "official-client session is not awaiting recovery"
  in
  let* () =
    match request.resolution, recovery.previous_settlement with
    | Keeper_official_client_session_store.Retry_previous, None ->
      conflict
        "retry_previous_unavailable"
        "official-client recovery has no exact previous settlement to retry"
    | Retry_previous, Some _ | Restart_fresh, _ -> Ok ()
  in
  match
    Keeper_official_client_session_store.resolve_recovery
      ~base_path
      ~keeper_name:request.keeper_name
      ~expected:current
      ~recovery_id:request.recovery_id
      ~resolution:request.resolution
      ~resolved_by:actor
      ~resolved_at:(Time_compat.now ())
  with
  | Ok resolved ->
    Ok (response_json ~keeper_name:request.keeper_name (Some resolved))
  | Error message ->
    (match load ~base_path ~keeper_name:request.keeper_name with
     | Ok (Some observed) when observed <> current ->
       conflict
         "official_client_session_changed"
         "official-client session changed before recovery resolution"
     | Ok None ->
       conflict
         "official_client_session_disappeared"
         "official-client session disappeared before recovery resolution"
     | Ok (Some _) | Error _ ->
       error
         Service_unavailable
         "official_client_session_resolution_failed"
         message)
;;
