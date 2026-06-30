(** HTTP routes for sidecar lifecycle.

    Provides [/api/v1/sidecar/{start,stop,status}] endpoints that dispatch
    [sidecars/<id>-bot/run.sh]. The wrapper is the single source of truth for
    how a sidecar is started, signalled, and inspected — this module only
    thin-wraps it for HTTP consumers (i.e. the dashboard's connectors
    surface).

    Design baseline: docs/SIDECAR-LIFECYCLE-API-RFC.md.

    Uses query-string [?name=<id>] (matching the existing channel_gate
    routes such as [/api/v1/gate/connector/bind?name=<connector>])
    rather than path params, so we don't introduce a second routing
    convention.

    @since v0.10.0 *)

open Server_auth
module Http = Http_server_eio

include Server_routes_http_sidecar_paths

type sidecar_start_plan =
  { argv : string list
  ; env : string array
  }

let env_with_base_path ~base_path =
  let key = Env_config_core.base_path_env_key in
  let prefix = key ^ "=" in
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun entry -> not (String.starts_with ~prefix entry))
  |> fun rest -> Array.of_list ((prefix ^ base_path) :: rest)
;;

let sidecar_start_plan ~base_path ~script =
  { argv = [ script; "start" ]; env = env_with_base_path ~base_path }
;;

let start_sidecar_process ~base_path ~script =
  let plan = sidecar_start_plan ~base_path ~script in
  match Process_eio.spawn_detached_devnull ~argv:plan.argv ~env:plan.env ~cwd:"" with
  | Ok _ -> Ok ()
  | Error msg -> Error msg
;;

type desired_state = Server_routes_http_routes_sidecar_state.desired_state =
  | Desired_running
  | Desired_stopped

type desired_record =
  { connector_id : string
  ; desired_state : desired_state
  ; generation : int
  ; updated_by : string
  ; updated_at : string
  }

type observed_state = Server_routes_http_routes_sidecar_state.observed_state =
  | Observed_available
  | Observed_unavailable

type reconcile_result = Server_routes_http_routes_sidecar_state.reconcile_result =
  | Reconcile_started
  | Reconcile_noop of string

module Attempt = Attempt_state

type attempt_record =
  { connector_id : string
  ; attempt : Attempt.t
  ; operator_next_action : string
  }

type attempt_record_decode_error =
  | Attempt_record_not_object of string
  | Attempt_record_invalid_field of
      { field : string
      ; expected : string
      ; actual : string
      }
  | Attempt_record_unknown_result of string
  | Attempt_record_invalid_timestamp of
      { field : string
      ; value : string
      }

let attempt_record_decode_error_to_string = function
  | Attempt_record_not_object actual ->
    Printf.sprintf "attempt record must be an object, got %s" actual
  | Attempt_record_invalid_field { field; expected; actual } ->
    Printf.sprintf "field %S must be %s, got %s" field expected actual
  | Attempt_record_unknown_result value ->
    Printf.sprintf "field %S has unknown result %S" "last_attempt_result" value
  | Attempt_record_invalid_timestamp { field; value } ->
    Printf.sprintf "field %S has invalid ISO-8601 timestamp %S" field value
;;

let sidecar_operator_next_action =
  "wait for observed status, or open logs if the sidecar remains offline after \
   backoff"
;;

let iso_of_unix_opt = Option.map Masc_domain.iso8601_of_unix_seconds
let next_retry_at record = iso_of_unix_opt record.attempt.next_retry_unix
let updated_at record = Masc_domain.iso8601_of_unix_seconds record.attempt.updated_unix

let desired_state_to_string =
  Server_routes_http_routes_sidecar_state.desired_state_to_string
let desired_state_of_string =
  Server_routes_http_routes_sidecar_state.desired_state_of_string
let observed_state_to_string =
  Server_routes_http_routes_sidecar_state.observed_state_to_string
let reconcile_result_to_string =
  Server_routes_http_routes_sidecar_state.reconcile_result_to_string

let attempt_record_json (record : attempt_record) =
  let attempt = record.attempt in
  `Assoc
    [ "connector_id", `String record.connector_id
    ; "generation", `Int attempt.generation
    ; "attempt_id", `String attempt.attempt_id
    ; "attempt_number", `Int attempt.attempt_number
    ; "last_attempt_result", `String (Attempt.result_to_string attempt.last_result)
    ; ( "next_retry_at", Json_util.string_opt_to_json (next_retry_at record) )
    ; "operator_next_action", `String record.operator_next_action
    ; "updated_at", `String (updated_at record)
    ]
;;

let invalid_attempt_field ~field ~expected actual =
  Error
    (Attempt_record_invalid_field
       { field; expected; actual = Json_util.kind_name actual })
;;

let required_string_field fields field =
  match List.assoc_opt field fields with
  | Some (`String value) -> Ok value
  | Some actual -> invalid_attempt_field ~field ~expected:"string" actual
  | None ->
    Error
      (Attempt_record_invalid_field { field; expected = "string"; actual = "missing" })
;;

let required_int_field fields field =
  match List.assoc_opt field fields with
  | Some (`Int value) -> Ok value
  | Some actual -> invalid_attempt_field ~field ~expected:"integer" actual
  | None ->
    Error
      (Attempt_record_invalid_field
         { field; expected = "integer"; actual = "missing" })
;;

let parse_timestamp_field ~field value =
  match Types_core.parse_iso8601_opt value with
  | Some unix -> Ok unix
  | None -> Error (Attempt_record_invalid_timestamp { field; value })
;;

let optional_next_retry_unix fields =
  match List.assoc_opt "next_retry_at" fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    (match parse_timestamp_field ~field:"next_retry_at" value with
     | Ok unix -> Ok (Some unix)
     | Error _ as error -> error)
  | Some actual -> invalid_attempt_field ~field:"next_retry_at" ~expected:"string or null" actual
;;

let attempt_record_of_json_result = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* connector_id = required_string_field fields "connector_id" in
    let* generation = required_int_field fields "generation" in
    let* attempt_id = required_string_field fields "attempt_id" in
    let* attempt_number = required_int_field fields "attempt_number" in
    let* last_attempt_result = required_string_field fields "last_attempt_result" in
    let* last_result =
      match Attempt.result_of_string_opt last_attempt_result with
      | Some result -> Ok result
      | None -> Error (Attempt_record_unknown_result last_attempt_result)
    in
    let* next_retry_unix = optional_next_retry_unix fields in
    let* operator_next_action = required_string_field fields "operator_next_action" in
    let* updated_at = required_string_field fields "updated_at" in
    let* updated_unix = parse_timestamp_field ~field:"updated_at" updated_at in
    Ok
      { connector_id
      ; attempt =
          { generation
          ; attempt_id
          ; attempt_number
          ; last_result
          ; next_retry_unix
          ; updated_unix
          }
      ; operator_next_action
      }
  | other -> Error (Attempt_record_not_object (Json_util.kind_name other))
;;

let attempt_record_of_json json =
  match attempt_record_of_json_result json with
  | Ok record -> Some record
  | Error _ -> None
;;

let desired_record_json (record : desired_record) =
  `Assoc
    [ "connector_id", `String record.connector_id
    ; "desired_state", `String (desired_state_to_string record.desired_state)
    ; "generation", `Int record.generation
    ; "updated_by", `String record.updated_by
    ; "updated_at", `String record.updated_at
    ]
;;

let desired_record_of_json = function
  | `Assoc fields ->
    (match
       ( List.assoc_opt "connector_id" fields
       , List.assoc_opt "desired_state" fields
       , List.assoc_opt "generation" fields
       , List.assoc_opt "updated_by" fields
       , List.assoc_opt "updated_at" fields )
     with
     | ( Some (`String connector_id)
       , Some (`String desired_state)
       , Some (`Int generation)
       , Some (`String updated_by)
       , Some (`String updated_at) ) ->
       desired_state_of_string desired_state
       |> Option.map (fun desired_state ->
         { connector_id; desired_state; generation; updated_by; updated_at })
     | _ -> None)
  | _ -> None
;;

let sidecar_desired_path ~base_path id =
  Filename.concat
    base_path
    (Printf.sprintf ".gate/runtime/%s/sidecar_lifecycle_desired.json" id)
;;

let sidecar_attempt_path ~base_path id =
  Filename.concat
    base_path
    (Printf.sprintf ".gate/runtime/%s/sidecar_lifecycle_attempt.json" id)
;;

(* Silent [Sys_error _ | Yojson.Json_error _ -> None] previously collapsed
   distinct failure modes into "no record":
   (1) file existed at [Sys.file_exists] check but read failed (TOCTOU
       race, permission change, partial write mid-rename),
   (2) file read OK but JSON was malformed,
   (3) JSON was syntactically valid but semantically invalid.
   Desired-state reads remain log-only for compatibility. Attempt-state reads
   use [read_attempt_record_result] so reconcile/status callers can fail closed
   or surface corruption instead of treating it as absence. *)
let read_desired_record ~base_path id =
  let path = sidecar_desired_path ~base_path id in
  if not (Sys.file_exists path)
  then None
  else (
    try read_file path |> Yojson.Safe.from_string |> desired_record_of_json with
    | Sys_error msg ->
      Log.Server.warn
        "[sidecar/desired] file_exists OK but read failed at %s: %s"
        path
        msg;
      None
    | Yojson.Json_error msg ->
      Log.Server.warn "[sidecar/desired] malformed JSON at %s: %s" path msg;
      None)
;;

let read_attempt_record_result ~base_path id =
  let path = sidecar_attempt_path ~base_path id in
  if not (Sys.file_exists path)
  then Ok None
  else (
    try
      let json = read_file path |> Yojson.Safe.from_string in
      match attempt_record_of_json_result json with
      | Ok record -> Ok (Some record)
      | Error error ->
        let detail = attempt_record_decode_error_to_string error in
        Log.Server.warn "[sidecar/attempt] invalid persisted state at %s: %s" path detail;
        Error (Printf.sprintf "invalid persisted attempt state at %s: %s" path detail)
    with
    | Sys_error msg ->
      Log.Server.warn
        "[sidecar/attempt] file_exists OK but read failed at %s: %s"
        path
        msg;
      Error (Printf.sprintf "attempt state read failed at %s: %s" path msg)
    | Yojson.Json_error msg ->
      Log.Server.warn "[sidecar/attempt] malformed JSON at %s: %s" path msg;
      Error (Printf.sprintf "malformed attempt state JSON at %s: %s" path msg))
;;

let read_attempt_record ~base_path id =
  match read_attempt_record_result ~base_path id with
  | Ok record -> record
  | Error _ -> None
;;

(** Make sure [.gate/runtime/<id>/] exists before atomic_write_file
    tries to rename into it. *)
let ensure_parent_dir path =
  let dir = Filename.dirname path in
  let rec mk d =
    if Sys.file_exists d
    then ()
    else (
      mk (Filename.dirname d);
      try Unix.mkdir d 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mk dir
;;

(** Atomic write: tmp file + rename. POSIX rename is atomic so a
    concurrent reader sees either the old file or the new one, never a
    half-written one. Inlined here rather than reaching into
    Keeper_toml_loader (which keeps it as a private helper). *)
let atomic_write_file ~(path : string) (content : string) : (unit, string) result =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    Eio_guard.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Sys.rename tmp path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (try Sys.remove tmp with
     | Sys_error _ -> ());
    Error (Printf.sprintf "atomic write failed: %s" (Printexc.to_string exn))
;;

let write_desired_record ?updated_at ~base_path ~id ~updated_by desired_state =
  let previous = read_desired_record ~base_path id in
  let generation =
    match previous with
    | Some record -> record.generation + 1
    | None -> 1
  in
  let record =
    { connector_id = id
    ; desired_state
    ; generation
    ; updated_by
    ; updated_at = Option.value updated_at ~default:(Masc_domain.now_iso ())
    }
  in
  let path = sidecar_desired_path ~base_path id in
  ensure_parent_dir path;
  match
    atomic_write_file ~path (Yojson.Safe.to_string (desired_record_json record) ^ "\n")
  with
  | Ok () -> Ok record
  | Error _ as error -> error
;;

let write_attempt_record ~base_path ~id record =
  let path = sidecar_attempt_path ~base_path id in
  ensure_parent_dir path;
  atomic_write_file ~path (Yojson.Safe.to_string (attempt_record_json record) ^ "\n")
;;

let observed_state_of_status_json = function
  | `Assoc fields ->
    (match List.assoc_opt "available" fields with
     | Some (`Bool true) -> Observed_available
     | _ -> Observed_unavailable)
  | _ -> Observed_unavailable
;;

(** Backoff window between repeated same-generation reconcile start
    dispatches. Default 30s, overridable via [MASC_SIDECAR_RECONCILE_BACKOFF_SEC]
    (#8930 consolidation). *)
let retry_backoff_seconds () = Env_config_runtime.Sidecar.reconcile_backoff_sec

(** Compare backoff deadline against [now] in unix-epoch seconds. Parses both
    [now] via [Types_core.parse_iso8601_opt], then delegates the deadline
    comparison to [Attempt_state.is_backoff_active].  Persisted
    [next_retry_at] strings are parsed once at the JSON boundary into
    [Attempt_state.t], so runtime backoff no longer compares wire strings.
    Malformed [now] keeps backoff inactive so reconcile retries instead of
    stalling (#8930 phase 3); malformed persisted deadlines fail at the
    attempt-record read boundary. *)
let retry_backoff_active ~now attempt =
  match Types_core.parse_iso8601_opt now with
  | Some now_unix -> Attempt.is_backoff_active ~now:now_unix attempt.attempt
  | None -> false
;;

let unix_of_iso_result ~field value =
  match Types_core.parse_iso8601_opt value with
  | Some unix -> Ok unix
  | None -> Error (Printf.sprintf "invalid %s: %s" field value)
;;

let next_attempt_record_result ~now ~next_retry_at previous (record : desired_record) =
  let ( let* ) = Result.bind in
  let* now_unix = unix_of_iso_result ~field:"now" now in
  let* next_retry_unix = unix_of_iso_result ~field:"next_retry_at" next_retry_at in
  let previous = Option.map (fun record -> record.attempt) previous in
  Ok
    { connector_id = record.connector_id
    ; attempt =
        Attempt.make_next
          ~now:now_unix
          ~backoff_seconds:(next_retry_unix -. now_unix)
          ~generation:record.generation
          ~last_result:Attempt.Start_dispatched
          ~previous
    ; operator_next_action = sidecar_operator_next_action
    }
;;

let next_attempt_record ~now ~next_retry_at previous record =
  match next_attempt_record_result ~now ~next_retry_at previous record with
  | Ok record -> record
  | Error msg -> invalid_arg msg
;;

let reconcile_desired_once
      ?(now = Masc_domain.now_iso ())
      ?(next_retry_at = Masc_domain.iso8601_of_unix_seconds (Unix.time () +. retry_backoff_seconds ()))
      ?previous_attempt
      ?(write_attempt = fun (_ : attempt_record) -> Ok ())
      ~current_generation
      ~observed_state
      ~start_process
      (record : desired_record)
  =
  if record.generation <> current_generation
  then Reconcile_noop "stale_generation"
  else (
    match record.desired_state, observed_state with
    | Desired_running, Observed_unavailable ->
      (match previous_attempt with
       | Some attempt
         when attempt.attempt.generation = record.generation
              && retry_backoff_active ~now attempt ->
         Reconcile_noop "backoff_active"
       | _ ->
         (match next_attempt_record_result ~now ~next_retry_at previous_attempt record with
          | Error msg ->
            Log.Server.warn
              "[sidecar/reconcile] invalid attempt timestamp for %s generation %d: %s"
              record.connector_id
              record.generation
              msg;
            Reconcile_noop "attempt_time_invalid"
          | Ok attempt ->
            (match write_attempt attempt with
             | Ok () ->
               start_process ();
               Reconcile_started
             | Error _ -> Reconcile_noop "attempt_write_failed")))
    | Desired_running, Observed_available -> Reconcile_noop "already_available"
    | Desired_stopped, _ -> Reconcile_noop "desired_stopped")
;;

let reconcile_preview ?now ?previous_attempt (record : desired_record) observed_state =
  match record.desired_state, observed_state with
  | Desired_running, Observed_unavailable ->
    let now = Option.value now ~default:(Masc_domain.now_iso ()) in
    (match previous_attempt with
     | Some attempt
       when attempt.attempt.generation = record.generation
            && retry_backoff_active ~now attempt ->
       "noop:backoff_active"
     | _ -> "would_start")
  | Desired_running, Observed_available -> "noop:already_available"
  | Desired_stopped, _ -> "noop:desired_stopped"
;;

let attempt_fields = function
  | None ->
    [ "last_attempt_result", `Null
    ; "next_retry_at", `Null
    ; "operator_next_action", `Null
    ]
  | Some attempt ->
    [ ( "last_attempt_result"
      , `String (Attempt.result_to_string attempt.attempt.last_result) )
    ; ( "next_retry_at", Json_util.string_opt_to_json (next_retry_at attempt) )
    ; "operator_next_action", `String attempt.operator_next_action
    ; "attempt_id", `String attempt.attempt.attempt_id
    ]
;;

let lifecycle_json ~base_path id status_json =
  let observed_state = observed_state_of_status_json status_json in
  let previous_attempt, attempt_error_fields =
    match read_attempt_record_result ~base_path id with
    | Ok previous_attempt -> previous_attempt, []
    | Error msg -> None, [ "attempt_read_error", `String msg ]
  in
  match read_desired_record ~base_path id with
  | None ->
    `Assoc
      ([ "desired_state", `Null
       ; "desired_generation", `Null
       ; "observed_state", `String (observed_state_to_string observed_state)
       ; "reconcile_result", `String "none"
       ]
       @ attempt_fields previous_attempt
       @ attempt_error_fields)
  | Some record ->
    `Assoc
      ([ "desired_state", `String (desired_state_to_string record.desired_state)
       ; "desired_generation", `Int record.generation
       ; "desired_updated_by", `String record.updated_by
       ; "desired_updated_at", `String record.updated_at
       ; "observed_state", `String (observed_state_to_string observed_state)
       ; ( "reconcile_result"
         , `String (reconcile_preview ?previous_attempt record observed_state) )
       ]
       @ attempt_fields previous_attempt
       @ attempt_error_fields)
;;

let append_assoc key value = function
  | `Assoc fields -> `Assoc (fields @ [ key, value ])
  | json -> json
;;

let prepend_assoc fields = function
  | `Assoc existing -> `Assoc (fields @ existing)
  | json -> `Assoc (fields @ [ "payload", json ])
;;

let sidecar_status_dashboard_surface = "/api/v1/sidecar/status"
let sidecar_status_source = "sidecar_status_file"

let sidecar_status_retention_json ~base_path ~id ~status_path =
  `Assoc
    [ "scope", `String "runtime_sidecar_status"
    ; "status_path", `String status_path
    ; "default_status_path"
      , `String (Filename.concat base_path (Printf.sprintf ".gate/runtime/%s/status.json" id))
    ; "legacy_status_path", `String (Filename.concat base_path (legacy_status_rel id))
    ; "lifecycle_desired_path", `String (sidecar_desired_path ~base_path id)
    ; "lifecycle_attempt_path", `String (sidecar_attempt_path ~base_path id)
    ; "binding_store_path"
      , `String (Filename.concat base_path (Printf.sprintf ".gate/runtime/%s/bindings.json" id))
    ; "binding_audit_store_path"
      , `String
          (Filename.concat
             base_path
             (Printf.sprintf ".gate/runtime/%s/binding_audit.jsonl" id))
    ]
;;

let sidecar_status_metadata_fields ~base_path ~id ~status_path =
  [ "dashboard_surface", `String sidecar_status_dashboard_surface
  ; "source", `String sidecar_status_source
  ; "retention", sidecar_status_retention_json ~base_path ~id ~status_path
  ; "generated_at_iso", `String (Masc_domain.now_iso ())
  ]
;;

(** Clamp the [?lines=N] query param to [1, 1000]. Pure so unit tests
    can pin the upper bound without a request mock. *)
let clamp_lines = function
  | None -> 200
  | Some n -> max 1 (min 1000 n)
;;

let respond_json request reqd ~status body =
  respond_json_value_with_cors ~status request reqd body
;;

let bad_request request reqd msg =
  respond_json
    request
    reqd
    ~status:`Bad_request
    (`Assoc [ "ok", `Bool false; "error", `String msg ])
;;

let read_status_json ~base_path id =
  let configured_sidecar_root = sidecar_root () in
  let project_root = project_root_from_executable () in
  let sidecar_dir =
    resolve_existing_sidecar_dir
      ?sidecar_root:configured_sidecar_root
      ?project_root
      ~base_path
      id
  in
  let path =
    status_file
      ?sidecar_root:configured_sidecar_root
      ?project_root
      ?sidecar_dir
      ~base_path
      id
  in
  let status =
    if Sys.file_exists path
    then (
      let body = read_file path in
      let parsed =
        (* Mirror read_desired_record/read_attempt_record: surface
           malformed JSON instead of silently collapsing to [`Null] in
           the response payload. *)
        try Some (Yojson.Safe.from_string body) with
        | Yojson.Json_error msg ->
          Log.Server.warn
            "[sidecar/status] malformed JSON at %s: %s"
            path
            msg;
          None
      in
      `Assoc
        [ "ok", `Bool true
        ; "available", `Bool true
        ; "status_path", `String path
        ; "status", Option.value parsed ~default:`Null
        ])
    else
      `Assoc [ "ok", `Bool true; "available", `Bool false; "status_path", `String path ]
  in
  status
  |> append_assoc "sidecar_lifecycle" (lifecycle_json ~base_path id status)
  |> prepend_assoc (sidecar_status_metadata_fields ~base_path ~id ~status_path:path)
;;

let handle_status state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    let base_path = request_base_path state in
    respond_json request reqd ~status:`OK (read_status_json ~base_path id)
;;

let handle_stop state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    let base_path = request_base_path state in
    (match runtime_sidecar_script_result ~base_path id with
     | Error msg ->
       respond_json
         request
         reqd
         ~status:`Service_unavailable
         (`Assoc [ "ok", `Bool false; "error", `String msg ])
     | Ok script ->
       (match
          write_desired_record ~base_path ~id ~updated_by:"http:stop" Desired_stopped
        with
        | Error msg ->
          respond_json
            request
            reqd
            ~status:`Internal_server_error
            (`Assoc [ "ok", `Bool false; "error", `String msg ])
        | Ok desired ->
          let _status, stdout =
            Masc_exec.Exec_gate.run_argv_with_status
              ~actor:`System_spawn
              ~raw_source:(script ^ " stop")
              ~summary:"sidecar stop script"
              ~timeout_sec:Env_config_runtime.Sidecar.control_command_timeout_sec
              [ script; "stop" ]
          in
          let trimmed = String.trim stdout in
          let signaled_marker = Printf.sprintf "Sent SIGTERM to %s-bot processes." id in
          let signaled =
            let needle_len = String.length signaled_marker in
            let rec contains i =
              if i + needle_len > String.length trimmed
              then false
              else if String.equal (String.sub trimmed i needle_len) signaled_marker
              then true
              else contains (i + 1)
            in
            contains 0
          in
          respond_json
            request
            reqd
            ~status:`OK
            (`Assoc
                [ "ok", `Bool true
                ; "signaled", `Bool signaled
                ; "note", `String trimmed
                ; "desired_state", `String (desired_state_to_string desired.desired_state)
                ; "desired_generation", `Int desired.generation
                ; "stop_semantics", `String "synchronous_stop_with_desired_fence"
                ])))
;;

let handle_logs state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    let base_path = request_base_path state in
    let configured_sidecar_root = sidecar_root () in
    let project_root = project_root_from_executable () in
    let lines =
      clamp_lines
        (Server_utils.query_param request "lines"
         |> Option.map int_of_string_opt
         |> Option.join)
    in
    let path =
      today_log_file ?sidecar_root:configured_sidecar_root ?project_root ~base_path id
    in
    if not (Sys.file_exists path)
    then
      respond_json
        request
        reqd
        ~status:`OK
        (`Assoc
            [ "ok", `Bool true
            ; "log_path", `String path
            ; "available", `Bool false
            ; "lines", `List []
            ])
    else (
      let _status, stdout =
        Masc_exec.Exec_gate.run_argv_with_status
          ~actor:`System_runtime_info
          ~raw_source:("tail -n " ^ string_of_int lines ^ " " ^ path)
          ~summary:"tail sidecar logs"
          ~timeout_sec:Env_config_runtime.Sidecar.control_command_timeout_sec
          [ "tail"; "-n"; string_of_int lines; path ]
      in
      let line_list =
        String.split_on_char '\n' stdout
        |> List.filter (fun l -> not (String.equal l ""))
        |> List.map (fun l -> `String l)
      in
      respond_json
        request
        reqd
        ~status:`OK
        (`Assoc
            [ "ok", `Bool true
            ; "log_path", `String path
            ; "available", `Bool true
            ; "lines", `List line_list
            ]))
;;

include Server_routes_sidecar_config_schema

(** GET /api/v1/sidecar/config?name=<id>

    Reads the current runtime TOML and returns the values as a flat map
    so the dashboard form can prefill instead of showing only schema
    defaults. Empty file or missing file → [exists: false] envelope so
    the form falls back to defaults gracefully.

    All values are stringified for transport — the dashboard is the
    one rendering the form, and the form already knows the type from
    the schema response. Keeps the wire format simple. *)
let handle_get_config _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    let path = config_toml_path ~base_path:(request_base_path _state) id in
    if not (Sys.file_exists path)
    then
      respond_json
        request
        reqd
        ~status:`OK
        (`Assoc
            [ "ok", `Bool true
            ; "id", `String id
            ; "path", `String path
            ; "exists", `Bool false
            ; "values", `Assoc []
            ])
    else (
      let content =
        try Fs_compat.load_file path with
        | Sys_error _ -> ""
      in
      match Keeper_toml_loader.parse_toml content with
      | Error msg ->
        respond_json
          request
          reqd
          ~status:`Internal_server_error
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String (Printf.sprintf "TOML parse failed: %s" msg)
              ])
      | Ok doc ->
        let pairs =
          List.filter_map
            (fun (k, v) ->
               match v with
               | Keeper_toml_loader.Toml_string s -> Some (k, `String s)
               | Keeper_toml_loader.Toml_int n -> Some (k, `String (string_of_int n))
               | Keeper_toml_loader.Toml_float f ->
                 Some (k, `String (Printf.sprintf "%g" f))
               | Keeper_toml_loader.Toml_bool b ->
                 Some (k, `String (if b then "true" else "false"))
               | Keeper_toml_loader.Toml_string_array _ -> None)
            doc
        in
        respond_json
          request
          reqd
          ~status:`OK
          (`Assoc
              [ "ok", `Bool true
              ; "id", `String id
              ; "path", `String path
              ; "exists", `Bool true
              ; "values", `Assoc pairs
              ]))
;;

let handle_put_config _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    Http.Request.read_body_async reqd (fun body_str ->
      match parse_body_pairs body_str with
      | Error msg -> bad_request request reqd msg
      | Ok pairs ->
        let base_path = request_base_path _state in
        let types = schema_field_types ~base_path id in
        if types = []
        then
          respond_json
            request
            reqd
            ~status:`Service_unavailable
            (`Assoc
                [ "ok", `Bool false
                ; ( "error"
                  , `String
                      "schema unavailable; run `./run.sh start` once so the form knows \
                       which fields exist" )
                ])
        else (
          let type_of k = List.assoc_opt k types in
          let rec collect acc rejected = function
            | [] -> Ok (List.rev acc, List.rev rejected)
            | (k, v) :: rest ->
              (match type_of k with
               | None -> collect acc (k :: rejected) rest
               | Some typ ->
                 (match coerce_value typ v with
                  | Ok tv -> collect ((k, tv) :: acc) rejected rest
                  | Error msg -> Error (Printf.sprintf "%s: %s" k msg)))
          in
          match collect [] [] pairs with
          | Error msg -> bad_request request reqd msg
          | Ok (accepted, rejected) ->
            let path = config_toml_path ~base_path id in
            ensure_parent_dir path;
            let toml_str = render_toml accepted in
            (match atomic_write_file ~path toml_str with
             | Error e ->
               respond_json
                 request
                 reqd
                 ~status:`Internal_server_error
                 (`Assoc [ "ok", `Bool false; "error", `String e ])
             | Ok () ->
               respond_json
                 request
                 reqd
                 ~status:`OK
                 (`Assoc
                     [ "ok", `Bool true
                     ; "id", `String id
                     ; "path", `String path
                     ; "written_fields", `Int (List.length accepted)
                     ; "rejected_fields", `List (List.map (fun s -> `String s) rejected)
                     ]))))
;;

let handle_schema _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    (match fetch_schema ~base_path:(request_base_path _state) id with
     | Error msg ->
       respond_json
         request
         reqd
         ~status:`Service_unavailable
         (`Assoc [ "ok", `Bool false; "error", `String msg ])
     | Ok json_str ->
       (match Yojson.Safe.from_string json_str with
        | parsed ->
          respond_json
            request
            reqd
            ~status:`OK
            (`Assoc [ "ok", `Bool true; "id", `String id; "schema", parsed ])
        (* RFC-0145 — narrow to the only exception
           [Yojson.Safe.from_string] raises on malformed JSON. *)
        | exception Yojson.Json_error _ ->
          respond_json
            request
            reqd
            ~status:`Internal_server_error
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "schema_dump returned invalid JSON"
                ])))
;;

let handle_start state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
    let base_path = request_base_path state in
    (match runtime_sidecar_script_result ~base_path id with
     | Error msg ->
       respond_json
         request
         reqd
         ~status:`Service_unavailable
         (`Assoc [ "ok", `Bool false; "error", `String msg ])
     | Ok script ->
       (match read_attempt_record_result ~base_path id with
        | Error msg ->
          respond_json
            request
            reqd
            ~status:`Internal_server_error
            (`Assoc
                [ "ok", `Bool false
                ; "id", `String id
                ; "error", `String "sidecar attempt state invalid"
                ; "detail", `String msg
                ])
        | Ok previous_attempt ->
          (match
             write_desired_record ~base_path ~id ~updated_by:"http:start" Desired_running
           with
           | Error msg ->
             respond_json
               request
               reqd
               ~status:`Internal_server_error
               (`Assoc [ "ok", `Bool false; "error", `String msg ])
           | Ok desired ->
          (* Detach without a shell: [Process_eio] gives the child its own
             session and redirects stdio to [/dev/null], so the sidecar
             survives backend restart without retaining server FDs. *)
             let status_json = read_status_json ~base_path id in
             let observed_state = observed_state_of_status_json status_json in
             let reconcile_result =
               reconcile_desired_once
                 ~current_generation:desired.generation
                 ?previous_attempt
                 ~observed_state
                 ~write_attempt:(write_attempt_record ~base_path ~id)
                 ~start_process:(fun () ->
                   match start_sidecar_process ~base_path ~script with
                   | Ok () -> ()
                   | Error msg ->
                     Log.Misc.warn "[Sidecar] detached start failed: %s" msg)
                 desired
             in
             respond_json
               request
               reqd
               ~status:`Accepted
               (`Assoc
                   [ "ok", `Bool true
                   ; "id", `String id
                   ; ( "desired_state"
                     , `String (desired_state_to_string desired.desired_state) )
                   ; "desired_generation", `Int desired.generation
                   ; "observed_state", `String (observed_state_to_string observed_state)
                   ; ( "reconcile_result"
                     , `String (reconcile_result_to_string reconcile_result) )
                   ; ( "note"
                     , `String
                         "sidecar desired state updated; poll \
                          /api/v1/sidecar/status?name=..." )
                   ]))))
;;

(** Register sidecar lifecycle routes on the router. *)
let add_routes ~sw:_ ~clock:_ router =
  router
  |> Http.Router.get "/api/v1/sidecar/status" (fun request reqd ->
    with_public_read
      (fun state _req reqd -> handle_status state request reqd)
      request
      reqd)
  |> Http.Router.get "/api/v1/sidecar/logs" (fun request reqd ->
    with_tool_auth
      ~tool_name:"sidecar"
      (fun state _req reqd -> handle_logs state request reqd)
      request
      reqd)
  (* Schema is field-shape metadata, not values, so it's safe under
     public_read — the dashboard form needs it during cold-start
     onboarding (before any auth tokens are configured). *)
  |> Http.Router.get "/api/v1/sidecar/schema" (fun request reqd ->
    with_public_read
      (fun state _req reqd -> handle_schema state request reqd)
      request
      reqd)
  |> Http.Router.post "/api/v1/sidecar/start" (fun request reqd ->
    with_tool_auth
      ~tool_name:"sidecar"
      (fun state _req reqd -> handle_start state request reqd)
      request
      reqd)
  |> Http.Router.post "/api/v1/sidecar/stop" (fun request reqd ->
    with_tool_auth
      ~tool_name:"sidecar"
      (fun state _req reqd -> handle_stop state request reqd)
      request
      reqd)
  (* Writes user-supplied values (potentially containing tokens) to disk,
     so [tool_auth] not [public_read]. Whitelisting + type coercion runs
     inside the handler — the auth gate just keeps unauth'd writers out. *)
  |> Http.Router.post "/api/v1/sidecar/config" (fun request reqd ->
    with_tool_auth
      ~tool_name:"sidecar"
      (fun state _req reqd -> handle_put_config state request reqd)
      request
      reqd)
  (* Read current runtime TOML so the dashboard form prefills with what's
     actually on disk. Tokens may surface in the response, so [tool_auth]. *)
  |> Http.Router.get "/api/v1/sidecar/config" (fun request reqd ->
    with_tool_auth
      ~tool_name:"sidecar"
      (fun state _req reqd -> handle_get_config state request reqd)
      request
      reqd)
;;
