type error_kind =
  | Bad_request
  | Not_found
  | Service_unavailable

type error =
  { kind : error_kind
  ; code : string
  ; message : string
  }

let ( let* ) = Result.bind
let schema = "masc.dashboard.official-client-probe.v1"
let max_probe_timeout_s = 10.0

let error kind code message = Error { kind; code; message }

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
  | `Assoc [ "runtime_id", `String runtime_id ] -> non_empty "runtime_id" runtime_id
  | `Assoc _ ->
    error
      Bad_request
      "request_fields_invalid"
      "expected the exact runtime_id field"
  | _ -> error Bad_request "request_not_object" "request body must be a JSON object"
;;

let execution_not_measured_json =
  `Assoc
    [ "status", `String "not_measured"
    ; "reason", `String "login_probe_does_not_submit_model_turn"
    ]
;;

let response_json ~runtime_id ~client_kind ~model ~login ~client =
  `Assoc
    [ "schema", `String schema
    ; "ok", `Bool true
    ; "runtime_id", `String runtime_id
    ; "client_kind", `String client_kind
    ; "configured_model", Json_util.string_opt_to_json model
    ; "measured_at", `Float (Time_compat.now ())
    ; "login", login
    ; "client", client
    ; "execution", execution_not_measured_json
    ]
;;

let failed_login_json ~status ~detail =
  `Assoc
    [ "status", `String status
    ; "authenticated", `Bool false
    ; "evidence_source", `String "configured_executable_self_report"
    ; "identity_verified", `Bool false
    ; "detail", `String detail
    ]
;;

let empty_client_json = `Assoc [ "user_agent", `Null ]

let codex_failure_status = function
  | Runtime_codex_app_server.Invalid_config _ -> "invalid_config"
  | Spawn_failed _ | Process_exited _ -> "cli_unavailable"
  | Subscription_required _ -> "login_required"
  | Timeout _ -> "timeout"
  | Protocol_error _ | Rpc_error _ | Unsupported_server_request _ ->
    "protocol_error"
  | Context_window_exceeded _ | Turn_failed _ | Turn_interrupted
  | Runtime_shutting_down
  (* The host raises [Stopped_by_host] to abort a repeated tool loop mid-turn,
     and this probe measures [initialize] plus login only — see "The probe
     never starts a turn" at runtime_codex_app_server.ml. It joins the other
     turn-shaped outcomes the probe's no-turn contract already rules out; it
     is matched because [error] is the one sum type [run_turn] also returns. *)
  | Stopped_by_host _ ->
    "probe_contract_error"
;;

let claude_failure_status = function
  | Runtime_claude_code.Invalid_config _ -> "invalid_config"
  | Spawn_failed _ | Process_exited _ -> "cli_unavailable"
  | Subscription_required _ -> "login_required"
  | Timeout _ -> "timeout"
  | Protocol_error _ | Unsupported_control_request _ -> "protocol_error"
  | Turn_transport_interrupted _
  | Context_window_exceeded _
  | Turn_failed _
  | Turn_failed_with_observation _
  | Quota_blocked _
  (* Same reading as [codex_failure_status]: [probe_subscription] measures
     "the official CLI login without submitting a model turn"
     (runtime_claude_code.mli), so a mid-turn host abort cannot reach here. *)
  | Stopped_by_host _ ->
    "probe_contract_error"
;;

let probe_codex ~mgr ~clock ~process_cwd ~runtime_id ~model
    (config : Runtime_execution.codex_app_server) =
  let probe_config : Runtime_codex_app_server.config =
    { cli_path = config.cli_path
    ; model = config.model
    ; native = Runtime_native_tools.codex_default
    ; developer_instructions = None
    ; admission_timeout_s = Float.min max_probe_timeout_s config.timeout_s
    ; (* A probe stays bounded even where the turn is not: it answers "can this
         client log in", and an unbounded answer to that is no answer. An
         undeclared turn bound therefore falls back to the probe ceiling rather
         than to no ceiling. *)
      timeout_s = Some (Float.min max_probe_timeout_s config.timeout_s)
      ; wall_clock_ceiling_s = None
    }
  in
  match
    Runtime_codex_app_server.probe_subscription
      ~mgr
      ~clock
      ~cwd:process_cwd
      probe_config
  with
  | Ok measured ->
    response_json
      ~runtime_id
      ~client_kind:"codex"
      ~model
      ~login:
        (`Assoc
           [ "status", `String "ready"
           ; "authenticated", `Bool true
           ; "evidence_source", `String "configured_executable_self_report"
           ; "identity_verified", `Bool false
           ; "auth_method", `String "chatgpt"
           ; "subscription_type", `String measured.subscription.plan_type
           ; "api_provider", `Null
           ])
      ~client:
        (`Assoc
           [ "user_agent", Json_util.string_opt_to_json measured.user_agent ])
  | Error probe_error ->
    response_json
      ~runtime_id
      ~client_kind:"codex"
      ~model
      ~login:
        (failed_login_json
           ~status:(codex_failure_status probe_error)
           ~detail:(Runtime_codex_app_server.error_to_string probe_error))
      ~client:empty_client_json
;;

let probe_claude ~mgr ~clock ~cwd ~process_cwd ~runtime_id ~model
    (config : Runtime_execution.claude_code) =
  let probe_config : Runtime_claude_code.config =
    { cli_path = config.cli_path
    ; cwd
    ; model = config.model
    ; native = Runtime_native_tools.claude_code_default
    ; setting_sources = []
    ; system_prompt = None
    ; admission_timeout_s = Float.min max_probe_timeout_s config.timeout_s
    ; (* A probe stays bounded even where the turn is not: it answers "can this
         client log in", and an unbounded answer to that is no answer. An
         undeclared turn bound therefore falls back to the probe ceiling rather
         than to no ceiling. *)
      timeout_s = Some (Float.min max_probe_timeout_s config.timeout_s)
      ; wall_clock_ceiling_s = None
      (* A subscription probe asks whether the client answers at all; it has no
         domain schema to hold the answer to. *)
      ; output_schema = None
    }
  in
  match
    Runtime_claude_code.probe_subscription
      ~mgr
      ~clock
      ~cwd:process_cwd
      probe_config
  with
  | Ok measured ->
    response_json
      ~runtime_id
      ~client_kind:"claude_code"
      ~model
      ~login:
        (`Assoc
           [ "status", `String "ready"
           ; "authenticated", `Bool true
           ; "evidence_source", `String "configured_executable_self_report"
           ; "identity_verified", `Bool false
           ; "auth_method", `String measured.auth_method
           ; "subscription_type", `String measured.subscription_type
           ; "api_provider", `String measured.api_provider
           ])
      ~client:empty_client_json
  | Error probe_error ->
    response_json
      ~runtime_id
      ~client_kind:"claude_code"
      ~model
      ~login:
        (failed_login_json
           ~status:(claude_failure_status probe_error)
           ~detail:(Runtime_claude_code.error_to_string probe_error))
      ~client:empty_client_json
;;

let probe_body ~base_path ~body =
  let* runtime_id = parse_body body in
  let* runtime =
    match Runtime.get_runtime_by_id runtime_id with
    | Some runtime -> Ok runtime
    | None ->
      error
        Not_found
        "runtime_not_found"
        (Printf.sprintf "runtime %S is not configured" runtime_id)
  in
  let* env, clock =
    match Eio_context.get_env_opt (), Eio_context.get_clock_opt () with
    | Some env, Some clock -> Ok (env, clock)
    | None, _ | _, None ->
      error
        Service_unavailable
        "eio_context_unavailable"
        "official-client probe requires the initialized Eio runtime"
  in
  let mgr = Eio.Stdenv.process_mgr env in
  let process_cwd = Eio.Path.(Eio.Stdenv.fs env / base_path) in
  let model = Runtime_execution.model_id runtime.execution in
  match runtime.execution with
  | Runtime_execution.Codex_app_server config ->
    Ok
      (probe_codex
         ~mgr
         ~clock
         ~process_cwd
         ~runtime_id
         ~model
         config)
  | Runtime_execution.Claude_code config ->
    Ok
      (probe_claude
         ~mgr
         ~clock
         ~cwd:base_path
         ~process_cwd
         ~runtime_id
         ~model
         config)
  | Runtime_execution.Antigravity_cli _ ->
    error
      Bad_request
      "login_probe_unsupported"
      (Printf.sprintf
         "official-client runtime %S does not expose a login probe"
         runtime_id)
  | Runtime_execution.Agent_core _ ->
    error
      Bad_request
      "runtime_not_official_client"
      (Printf.sprintf "runtime %S is not an official-client runtime" runtime_id)
;;
