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
let schema = "masc.dashboard.codex-session.v1"

let error kind code message = Error { kind; code; message }

let failure_to_string = function
  | Keeper_codex_session_store.Transport_interrupted -> "transport_interrupted"
  | Protocol_failed -> "protocol_failed"
  | Provider_rejected -> "provider_rejected"
  | Host_hook_failed -> "host_hook_failed"
  | State_persistence_failed -> "state_persistence_failed"
;;

let settlement_json (settlement : Keeper_codex_session_store.settlement) =
  `Assoc
    [ "thread_id", `String settlement.thread_id
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
  | Keeper_codex_session_store.Retry_previous ->
    `Assoc [ "kind", `String "retry_previous" ]
  | Restart_fresh -> `Assoc [ "kind", `String "restart_fresh" ]
  | Adopt_verified settlement ->
    `Assoc
      [ "kind", `String "adopt_verified"
      ; "settlement", settlement_json settlement
      ]
;;

let resolution_record_json
    (record : Keeper_codex_session_store.recovery_resolution_record) =
  `Assoc
    [ "failure", `String (failure_to_string record.failure)
    ; "recovery_id", `String record.recovery_id
    ; "resolution", resolution_json record.resolution
    ; "resolved_at", `Float record.resolved_at
    ; "resolved_by", `String record.resolved_by
    ]
;;

let phase_json = function
  | Keeper_codex_session_store.Ready -> `Assoc [ "kind", `String "ready" ]
  | Start { previous_settlement } ->
    `Assoc
      [ "kind", `String "start"
      ; "previous_settlement", settlement_opt_json previous_settlement
      ]
  | Active { thread_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "active"
      ; "thread_id", `String thread_id
      ; "previous_settlement", settlement_opt_json previous_settlement
      ]
  | Turn_inflight { thread_id; turn_id; previous_settlement } ->
    `Assoc
      [ "kind", `String "turn_inflight"
      ; "thread_id", `String thread_id
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
      ; "observed_thread_id", string_opt_json recovery.observed_thread_id
      ; "observed_turn_id", string_opt_json recovery.observed_turn_id
      ; ( "previous_settlement"
        , settlement_opt_json recovery.previous_settlement )
      ]
  | Settled settlement ->
    `Assoc
      [ "kind", `String "settled"
      ; "thread_id", `String settlement.thread_id
      ; "turn_id", `String settlement.turn_id
      ]
;;

let binding_json (binding : Keeper_codex_session_store.t) =
  `Assoc
    [ "runtime_id", `String binding.runtime_id
    ; "phase", phase_json binding.phase
    ; "turn_count", `Int binding.turn_count
    ; "tool_surface_sha256", `String binding.tool_surface_sha256
    ; ( "last_recovery_resolution"
      , Option.fold
          ~none:`Null
          ~some:resolution_record_json
          binding.last_recovery_resolution )
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
  match Keeper_codex_session_store.load ~base_path ~keeper_name with
  | Ok session -> Ok session
  | Error message ->
    error
      Service_unavailable
      "codex_session_load_failed"
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
  ; resolution : Keeper_codex_session_store.recovery_resolution
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
         then Keeper_codex_session_store.Retry_previous
         else Restart_fresh
       in
       Ok { keeper_name; recovery_id; resolution }
     | [ "keeper_name", `String keeper_name
       ; "recovery_id", `String recovery_id
       ; "resolution", `String "adopt_verified"
       ; "thread_id", `String thread_id; "turn_id", `String turn_id ] ->
       let* keeper_name = validate_keeper_name keeper_name in
       let* recovery_id = non_empty "recovery_id" recovery_id in
       let* thread_id = non_empty "thread_id" thread_id in
       let* turn_id = non_empty "turn_id" turn_id in
       Ok
         { keeper_name
         ; recovery_id
         ; resolution =
             Keeper_codex_session_store.Adopt_verified
               { thread_id; turn_id }
         }
     | _ ->
       error
         Bad_request
         "request_fields_invalid"
         "expected exact keeper_name, recovery_id, resolution fields; adopt_verified also requires thread_id and turn_id")
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
        "codex_session_missing"
        "Keeper has no durable Codex session"
    | Some current -> Ok current
  in
  let* () =
    match current.phase with
    | Keeper_codex_session_store.Recovery_required recovery
      when String.equal recovery.recovery_id request.recovery_id ->
      Ok ()
    | Recovery_required _ ->
      conflict
        "recovery_id_changed"
        "Codex recovery identity changed before resolution"
    | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
      conflict
        "recovery_not_required"
        "Codex session is not awaiting recovery"
  in
  match
    Keeper_codex_session_store.resolve_recovery
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
         "codex_session_changed"
         "Codex session changed before recovery resolution"
     | Ok None ->
       conflict
         "codex_session_disappeared"
         "Codex session disappeared before recovery resolution"
     | Ok (Some _) | Error _ ->
       error
         Service_unavailable
         "codex_session_resolution_failed"
         message)
;;
