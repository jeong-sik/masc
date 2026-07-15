open Masc_domain
open Server_utils
open Server_auth

(* Re-export cache types and helpers from sub-module *)
include Server_dashboard_http_cache

let deep_surface_cache_ttl_s = Server_dashboard_http_core_cache.deep_surface_cache_ttl_s
let shell_surface_cache_ttl_s = Server_dashboard_http_core_cache.shell_surface_cache_ttl_s

type dashboard_compute_mode =
      Server_dashboard_http_runtime_support.dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

(* Dashboard runtime helpers extracted to
   [Server_dashboard_http_core_runtime] (godfile decomp). *)
let set_executor_pool = Server_dashboard_http_core_runtime.set_executor_pool
let dashboard_runtime = Server_dashboard_http_core_runtime.dashboard_runtime
let run_dashboard_compute = Server_dashboard_http_core_runtime.run_dashboard_compute
let state_dashboard_runtime_caps = Server_dashboard_http_core_runtime.state_dashboard_runtime_caps

(* ================================================================ *)
(* Dashboard Data (Batch API)                                       *)
(* ================================================================ *)

include Dashboard_http_helpers
include Dashboard_http_monitoring
include Dashboard_http_keeper

let dashboard_request_timeout_s = Server_dashboard_http_core_cache.dashboard_request_timeout_s
let shell_warmed = Server_dashboard_http_core_cache.shell_warmed
let shell_warming = Server_dashboard_http_core_cache.shell_warming
let last_good_shell = Server_dashboard_http_core_cache.last_good_shell
let last_good_shell_light = Server_dashboard_http_core_cache.last_good_shell_light
let with_dashboard_timeout = Server_dashboard_http_core_cache.with_dashboard_timeout
let cache_partition_segment = Server_dashboard_http_core_cache.cache_partition_segment
let dashboard_cache_key = Server_dashboard_http_core_cache.dashboard_cache_key
let dashboard_briefing_timeout_s = Server_dashboard_http_core_cache.dashboard_briefing_timeout_s
let attach_projection_diagnostics = Server_dashboard_http_core_cache.attach_projection_diagnostics
let projection_diagnostics_json = Server_dashboard_http_core_cache.projection_diagnostics_json
let with_projection_diagnostics = Server_dashboard_http_core_cache.with_projection_diagnostics
let initialized_json_opt = Server_dashboard_http_core_cache.initialized_json_opt


let operator_snapshot_broadcast_ref = Server_dashboard_http_core_operator.operator_snapshot_broadcast_ref
let operator_digest_broadcast_ref = Server_dashboard_http_core_operator.operator_digest_broadcast_ref
let operator_snapshot_cache = Server_dashboard_http_core_operator.operator_snapshot_cache
let operator_digest_cache = Server_dashboard_http_core_operator.operator_digest_cache
let operator_refresh_interval_s = Server_dashboard_http_core_operator.operator_refresh_interval_s
let operator_snapshot_extra = Server_dashboard_http_core_operator.operator_snapshot_extra
let json_assoc_int_opt = Server_dashboard_http_core_json.json_assoc_int_opt
let projection_diagnostics_fields = Server_dashboard_http_core_json.projection_diagnostics_fields
let projection_diagnostics_field = Server_dashboard_http_core_json.projection_diagnostics_field
let operator_generated_at_iso = Server_dashboard_http_core_json.operator_generated_at_iso
let operator_cache_json = Server_dashboard_http_core_json.operator_cache_json

(* Operator query-JSON + envelope metadata helpers extracted to
   [Server_dashboard_http_core_operator_query] (godfile decomp). *)
let operator_retention_json = Server_dashboard_http_core_operator_query.operator_retention_json
let operator_snapshot_query_json = Server_dashboard_http_core_operator_query.operator_snapshot_query_json
let operator_digest_query_json = Server_dashboard_http_core_operator_query.operator_digest_query_json
let with_operator_surface_metadata = Server_dashboard_http_core_operator_query.with_operator_surface_metadata
let with_operator_snapshot_metadata = Server_dashboard_http_core_operator_query.with_operator_snapshot_metadata
let with_operator_digest_metadata = Server_dashboard_http_core_operator_query.with_operator_digest_metadata
let operator_snapshot_default_query = Server_dashboard_http_core_operator_query.operator_snapshot_default_query
let operator_digest_default_query = Server_dashboard_http_core_operator_query.operator_digest_default_query

let start_operator_snapshot_refresh_loop = Server_dashboard_http_core_snapshot_refresh.start_operator_snapshot_refresh_loop

let start_operator_digest_refresh_loop = Server_dashboard_http_core_digest_refresh.start_operator_digest_refresh_loop

let operator_snapshot_http_json = Server_dashboard_http_core_operator_snapshot_http.operator_snapshot_http_json

let operator_digest_http_json = Server_dashboard_http_core_operator_digest_http.operator_digest_http_json

(* --- Mission proactive refresh ----------------------------------------
   A background fiber recomputes the mission snapshot periodically.
   The HTTP handler returns the cached ref immediately (0ms).
   Actor-parameterized requests fall back to on-demand compute with
   SWR cache. *)

let mission_cache =
  create_cached_surface
    (`Assoc
        [ "generated_at", `String (Masc_domain.now_iso ())
        ; "summary", `Assoc [ "workspace_health", `String "initializing" ]
        ; "incidents", `List []
        ; "recommended_actions", `List []
        ; "command_focus", `Assoc []
        ; "operator_targets", `Assoc []
        ; "attention_queue", `List []
        ; "agent_briefs", `List []
        ; "keeper_briefs", `List []
        ; "internal_signals", `List []
        ])
;;

let start_mission_refresh_loop ~state ~sw ~clock =
  let workspace_config = (Mcp_server.workspace_config state) in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = state_dashboard_runtime_caps state in
  let mission_refresh_timeout_s = 60.0 in
  let compute () =
    mark_cached_surface_attempt mission_cache;
    let t0_mission = Unix.gettimeofday () in
    try
      run_dashboard_compute
        ~mode:Offloaded_readonly
        ?net
        ?mono_clock
        ~sw
        ~clock
        ~config:workspace_config
      |> fun run_compute ->
      let result =
        run_compute (fun ~config ~sw ->
          Dashboard_briefing.json ~config ~sw ~clock ~proc_mgr ())
      in
      let dt_total = Unix.gettimeofday () -. t0_mission in
      if dt_total >= 5.0 then Log.Dashboard.warn "[mission profile] total=%.1fs" dt_total;
      result
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error mission_cache exn;
      raise exn
  in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      { (Proactive_refresh.default_config ~label:"mission" ~interval_s:120.0) with
        timeout_s = mission_refresh_timeout_s
      ; on_error = Some (mark_cached_surface_error mission_cache)
      ; warm_delay_s = 90.0
      }
    ~compute
    ~on_result:(mark_cached_surface_success mission_cache)
;;

let dashboard_briefing_http_json ~state ~sw ~clock request =
  let net, mono_clock = state_dashboard_runtime_caps state in
  let actor =
    dashboard_actor_for_request ~base_path:(Mcp_server.workspace_config state).base_path request
  in
  let compute ?actor () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute
      ~mode:Offloaded_readonly
      ?net
      ?mono_clock
      ~sw
      ~clock
      ~config:(Mcp_server.workspace_config state)
      (fun ~config ~sw ->
         Dashboard_briefing.json
           ?actor
           ~config
           ~sw
           ~clock
           ~proc_mgr:state.Mcp_server.proc_mgr
           ())
    |> with_projection_diagnostics ~surface:"mission" ~started_at ~extra:[]
  in
  let full_json =
    match actor with
    | None ->
      (* Mirror execution surface behavior: serve cached mission instantly
           after the first success, but let the very first default read
           bootstrap that success instead of staying "initializing" forever
           when proactive warm-up misses its first build window. *)
      cached_surface_or_first_success_json
        mission_cache
        ~cache_key:"briefing:default"
        ~ttl:deep_surface_cache_ttl_s
        ~clock
        ~timeout_sec:dashboard_briefing_timeout_s
        (fun () -> compute ())
    | Some _ ->
      (* Actor-parameterized: on-demand with SWR cache. *)
      let cache_key =
        dashboard_cache_key
          (Mcp_server.workspace_config state)
          "mission"
          (Option.value ~default:"" actor)
      in
      Dashboard_cache.get_or_compute_with_timeout
        cache_key
        ~ttl:deep_surface_cache_ttl_s
        ~clock
        ~timeout_sec:dashboard_briefing_timeout_s
        (compute ?actor)
  in
  full_json
;;

let dashboard_session_http_json ~state ~sw ~clock request =
  match query_param request "session_id" with
  | Some session_id ->
    (match String_util.trim_to_option session_id with
     | Some trimmed_id ->
       Dashboard_briefing.session_json
         ?actor:
           (dashboard_actor_for_request
              ~base_path:(Mcp_server.workspace_config state).base_path
              request)
         ~session_id:trimmed_id
         ~config:(Mcp_server.workspace_config state)
         ~sw
         ~clock
         ~proc_mgr:state.Mcp_server.proc_mgr
         ()
     | None ->
       `Assoc
         [ "generated_at", `String (Masc_domain.now_iso ())
         ; "session_id", `Null
         ; "session", `Null
         ; "timeline", `List []
         ; "participants", `List []
         ; "operations", `List []
         ; "keepers", `List []
         ; "error", `String "session_id is required"
         ])
  | None ->
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "session_id", `Null
      ; "session", `Null
      ; "timeline", `List []
      ; "participants", `List []
      ; "operations", `List []
      ; "keepers", `List []
      ; "error", `String "session_id is required"
      ]
;;

let dashboard_briefing_sections_http_json ~state ~sw ~clock request =
  let actor =
    dashboard_actor_for_request ~base_path:(Mcp_server.workspace_config state).base_path request
  in
  let force = bool_query_param request "force" ~default:false in
  let compute () =
    Dashboard_briefing_sections.json
      ?actor
      ~force
      ~config:(Mcp_server.workspace_config state)
      ~sw
      ~clock
      ~proc_mgr:state.Mcp_server.proc_mgr
      ()
  in
  if force
  then with_dashboard_timeout ~clock compute
  else (
    let cache_key =
      dashboard_cache_key
        (Mcp_server.workspace_config state)
        "mission_briefing"
        (Option.value ~default:"" actor)
    in
    Dashboard_cache.get_or_compute_with_timeout
      cache_key
      ~ttl:deep_surface_cache_ttl_s
      ~clock
      ~timeout_sec:dashboard_briefing_timeout_s
      compute)
;;

let dashboard_shell_status_json =
  Server_dashboard_http_core_entities.dashboard_shell_status_json
;;

let dashboard_task_json = Server_dashboard_http_core_entities.dashboard_task_json
let dashboard_agent_json = Server_dashboard_http_core_entities.dashboard_agent_json
let dashboard_message_json = Server_dashboard_http_core_entities.dashboard_message_json

(* dashboard_current_workspace_id removed — namespace retired (#unify-namespace). *)

let dashboard_tasks_safe = Server_dashboard_http_core_entities.dashboard_tasks_safe
let dashboard_agents_safe = Server_dashboard_http_core_entities.dashboard_agents_safe

let dashboard_messages_safe config ~since_seq ~limit =
  Server_dashboard_http_core_entities.dashboard_messages_safe config ~since_seq ~limit
;;

let dashboard_general_agent_count =
  Server_dashboard_http_core_entities.dashboard_general_agent_count
;;

let dashboard_general_agent_count_light =
  Server_dashboard_http_core_entities.dashboard_general_agent_count_light
;;

let provider_capacity_json = Server_dashboard_http_core_entities.provider_capacity_json

(* #10544: light mode skips the full board scan, so it should also have a smaller wall-clock
   budget. Pre-fix both modes shared the 16s timeout (post-#9766 8→16
   bump for the full path), which masked any "light isn't really light"
   regression — the operator cannot tell from log noise alone whether
   light is genuinely under-scoped or has accidentally taken on full's
   work. Splitting the budget makes that distinction visible: a light
   timeout means "light path is doing too much"; a full timeout means
   "the full path needs more headroom or a real perf fix". *)
let dashboard_shell_timeout_s = Env_config_runtime.Dashboard.shell_timeout_sec
let dashboard_shell_light_timeout_s = Env_config_runtime.Dashboard.shell_light_timeout_sec

(* Grace period after shell timeout during startup — allows the first
   snapshot to arrive before the dashboard reports "not ready". *)
let startup_grace_period_s = 10.0

let dashboard_shell_timeout_for ~light =
  if light then dashboard_shell_light_timeout_s else dashboard_shell_timeout_s
;;

let dashboard_shell_cache_prefix (config : Workspace.config) =
  Printf.sprintf "shell:workspace=%s:" config.base_path
;;

let dashboard_shell_cache_key ?(light = false) (config : Workspace.config) =
  Printf.sprintf
    "%sworkspace=%s:mode=%s"
    (dashboard_shell_cache_prefix config)
    config.workspace_path
    (if light then "light" else "full")
;;

let dashboard_shell_paths_json = Server_dashboard_http_core_shell_bootstrap.dashboard_shell_paths_json
let dashboard_shell_bootstrap_json = Server_dashboard_http_core_shell_bootstrap.dashboard_shell_bootstrap_json

let dashboard_shell_last_good_with_source ~light () =
  let full_last_good () =
    match Atomic.get last_good_shell with
    | `Assoc [] -> None
    | json -> Some (json, "last_good")
  in
  if light
  then (
    match Atomic.get last_good_shell_light with
    | `Assoc [] -> full_last_good ()
    | json -> Some (json, "last_good_light"))
  else full_last_good ()
;;

let remember_dashboard_shell_last_good ~light json =
  if light
  then Atomic.set last_good_shell_light json
  else Atomic.set last_good_shell json
;;

let is_dashboard_cache_timeout_json = function
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String ("Compute timeout" | "computation_timeout")) -> true
     | _ -> false)
  | _ -> false
;;

module Shell_projection_trace = Server_dashboard_shell_projection_trace

type shell_projection_timing = Shell_projection_trace.shell_projection_timing =
  { projection_label : string
  ; projection_ms : int
  }

type shell_projection_trace_status =
  Shell_projection_trace.shell_projection_trace_status =
  | Shell_trace_running
  | Shell_trace_finished
  | Shell_trace_failed

type shell_projection_trace = Shell_projection_trace.shell_projection_trace =
  { trace_light : bool
  ; trace_started_at : float
  ; mutable trace_status : shell_projection_trace_status
  ; mutable trace_active : string list
  ; mutable trace_completed : shell_projection_timing list
  ; mutable trace_finished_at : float option
  }

type shell_projection_trace_snapshot =
  Shell_projection_trace.shell_projection_trace_snapshot =
  { snapshot_status : shell_projection_trace_status
  ; snapshot_light : bool
  ; snapshot_elapsed_ms : int
  ; snapshot_active : string list
  ; snapshot_completed : shell_projection_timing list
  ; snapshot_finished_at : float option
  }

let shell_trace_status_string = Shell_projection_trace.status_string
let shell_projection_timing_top = Shell_projection_trace.timing_top
let shell_projection_timing_json = Shell_projection_trace.timing_json
let shell_projection_timing_log = Shell_projection_trace.timing_log
let shell_projection_trace_start = Shell_projection_trace.start
let shell_projection_trace_start_projection = Shell_projection_trace.start_projection
let shell_projection_trace_finish_projection = Shell_projection_trace.finish_projection
let shell_projection_trace_finish = Shell_projection_trace.finish
let shell_projection_trace_snapshot = Shell_projection_trace.snapshot
let shell_projection_trace_diagnostics = Shell_projection_trace.diagnostics
let shell_projection_trace_log = Shell_projection_trace.log

(* Closed mapping from internal projection labels to Server_timing phases.
   Total over the label set actually emitted by [dashboard_shell_payload_json];
   any label outside that set is recorded as [Custom label] so an unintended
   typo surfaces in the response header rather than vanishing silently. *)
let shell_projection_label_to_phase : string -> Server_timing.phase = function
  | "status" -> Projection_status
  | "agents" -> Projection_agents
  | "tasks" -> Projection_tasks
  | "keepers" -> Projection_keepers
  | "configured_keepers" -> Projection_configured_keepers
  | "config_resolution" -> Projection_config_resolution
  | "runtime_resolution" -> Projection_runtime_resolution
  | other -> Custom other
;;

let dashboard_shell_payload_json
      ?timing
      ?(light = false)
      (config : Workspace.config)
  : Yojson.Safe.t
  =
  let cluster = Env_config_core.cluster_name () in
  let cache_key = dashboard_shell_cache_key ~light config in
  let trace = shell_projection_trace_start ~cache_key ~light in
  let started_at = Unix.gettimeofday () in
  let record_timing label elapsed_ms =
    match timing with
    | None -> ()
    | Some t ->
      Server_timing.record_ms t (shell_projection_label_to_phase label)
        (float_of_int elapsed_ms)
  in
  let measure_ms label f =
    shell_projection_trace_start_projection trace label;
    let t0 = Unix.gettimeofday () in
    match f () with
    | value ->
      let elapsed_ms = int_of_float ((Unix.gettimeofday () -. t0) *. 1000.0) in
      shell_projection_trace_finish_projection trace label elapsed_ms;
      record_timing label elapsed_ms;
      value, elapsed_ms
    | exception (Eio.Cancel.Cancelled _ as exn) ->
      (* Keep the active projection marker for timeout fallback diagnostics. *)
      raise exn
    | exception exn ->
      let elapsed_ms = int_of_float ((Unix.gettimeofday () -. t0) *. 1000.0) in
      shell_projection_trace_finish_projection trace label elapsed_ms;
      record_timing label elapsed_ms;
      raise exn
  in
  let measure_json_projection label f =
    measure_ms label (fun () ->
      try f () with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.warn
          "dashboard shell %s projection failed: %s"
          label
          (Printexc.to_string exn);
        `Null)
  in
  match
    (* Cold workspaces lazily materialize workspace/keeper state on first access.
       Keep those stateful reads sequential so one failing init path does not
       cancel sibling fibers and poison shared Eio mutexes. Retain parallelism
       only for projection-style reads that are safe to drop to `Null`. *)
    let status_json, status_ms =
      measure_ms "status" (fun () -> dashboard_shell_status_json config)
    in
    let general_agents, agents_ms =
      if light
      then measure_ms "agents" (fun () -> dashboard_general_agent_count_light config)
      else (
        let agents, agents_ms =
          measure_ms "agents" (fun () -> dashboard_agents_safe config)
        in
        dashboard_general_agent_count agents, agents_ms)
    in
    let tasks, tasks_ms = measure_ms "tasks" (fun () -> dashboard_tasks_safe config) in
    let persisted_keepers, persisted_keepers_ms =
      measure_ms "persisted_keepers" (fun () -> keeper_count config)
    in
    let configured_keepers, configured_keepers_ms =
      measure_ms "configured_keepers" (fun () -> configured_keeper_count config)
    in
    let config_resolution_r = ref (`Null, 0) in
    let runtime_resolution_r = ref (`Null, 0) in
    let active_keepers, keepers_ms =
      if light
      then (
        let runtime_resolution_json, runtime_resolution_ms =
          measure_json_projection "runtime_resolution" (fun () ->
            Server_dashboard_http_runtime_info.light_runtime_resolution_json config)
        in
        runtime_resolution_r := (runtime_resolution_json, runtime_resolution_ms);
        ( Option.value
            ~default:0
            (json_assoc_int_opt "keeper_fibers" runtime_resolution_json)
        , 0 ))
      else measure_ms "keepers" (fun () -> running_keeper_count config)
    in
    if not light
    then
      (* Isolate each parallel section: in [Eio.Fiber.all] a single fiber's
         exception cancels its siblings and fails the whole payload. Route each
         through [Cancel_safe.observe] (RFC-0106 SSOT) so an unexpected section
         failure logs and lets the other sections complete; the section's ref
         keeps its [(`Null, 0)] default, so the payload renders that one section
         as null instead of returning a 500. [Eio.Cancel.Cancelled] is re-raised
         by [Cancel_safe.observe] so fiber-tree unwind is preserved. *)
      Eio.Fiber.all
        [ (fun () ->
            Cancel_safe.observe
              ~on_exn:(fun exn ->
                Log.Dashboard.error
                  "dashboard config_resolution section failed: %s"
                  (Printexc.to_string exn))
              (fun () ->
                config_resolution_r
                := measure_json_projection "config_resolution" (fun () ->
                     Config_dir_resolver.(resolve () |> to_json))))
        ; (fun () ->
            Cancel_safe.observe
              ~on_exn:(fun exn ->
                Log.Dashboard.error
                  "dashboard runtime_resolution section failed: %s"
                  (Printexc.to_string exn))
              (fun () ->
                runtime_resolution_r
                := measure_json_projection "runtime_resolution" (fun () ->
                     Server_dashboard_http_runtime_info.runtime_resolution_json config)))
        ];
    let config_resolution_json, config_resolution_ms = !config_resolution_r in
    let runtime_resolution_json, runtime_resolution_ms = !runtime_resolution_r in
    shell_projection_trace_finish trace Shell_trace_finished;
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "status", status_json
      ; "paths", dashboard_shell_paths_json config
      ; ( "counts"
        , `Assoc
            [ "agents", `Int general_agents
            ; "tasks", `Int (List.length tasks)
            ; "keepers", `Int active_keepers
            ; "persisted_keepers", `Int persisted_keepers
            ; "total_runtimes", `Int (general_agents + active_keepers)
            ] )
      ; "persisted_keepers", `Int persisted_keepers
      ; "configured_keepers", `Int configured_keepers
      ; "providers", provider_capacity_json ()
      ; "config_resolution", config_resolution_json
      ; "runtime_resolution", runtime_resolution_json
      ]
    |> with_projection_diagnostics
         ~surface:"shell"
         ~started_at
         ~extra:
           ([ "cluster", `String cluster
            ; "workspace_root", `String config.base_path
            ; "workspace_path", `String config.workspace_path
            ; "keeper_count_source", `String "runtime_keepalive"
            ; "configured_keeper_count_source", `String "keeper_toml"
            ; "persisted_keeper_count_source", `String "keeper_meta"
            ; "status_ms", `Int status_ms
            ; "agents_ms", `Int agents_ms
            ; "tasks_ms", `Int tasks_ms
            ; "keepers_ms", `Int keepers_ms
            ; "persisted_keepers_ms", `Int persisted_keepers_ms
            ; "configured_keepers_ms", `Int configured_keepers_ms
            ; "config_resolution_ms", `Int config_resolution_ms
            ; "runtime_resolution_ms", `Int runtime_resolution_ms
            ; "light", `Bool light
            ]
            @ shell_projection_trace_diagnostics cache_key)
  with
  | payload -> payload
  | exception (Eio.Cancel.Cancelled _ as e) ->
    shell_projection_trace_finish ~clear_active:false trace Shell_trace_failed;
    raise e
  | exception exn ->
    shell_projection_trace_finish trace Shell_trace_failed;
    raise exn
;;

let dashboard_shell_auth_json ~(request : Httpun.Request.t) (config : Workspace.config)
  : Yojson.Safe.t
  =
  (* SSOT: typed-error → dashboard auth code lives in
     [Masc_domain.dashboard_auth_error_code] so this shell summary and
     the HTTP 401 error body ([Server_auth.auth_error_json]) emit the
     same code. *)
  let dashboard_auth_error_code = Masc_domain.dashboard_auth_error_code in
  let auth_cfg = Auth.load_auth_config config.base_path in
  let token = auth_token_from_request request in
  let token_credential_result =
    match token with
    | None -> None
    | Some raw_token ->
      Some (Auth.find_credential_by_token config.base_path ~token:raw_token)
  in
  let requested_agent = request_actor_hint request in
  let token_present = Option.is_some token in
  let token_valid =
    match token_credential_result with
    | Some (Ok _) -> true
    | _ -> false
  in
  let token_agent =
    match token_credential_result with
    | Some (Ok cred) -> Some cred.Masc_domain.agent_name
    | _ -> None
  in
  let resolved_agent_name_result =
    match token_credential_result with
    (* Keep stale bearer tokens visible as auth failures in shell summaries instead of
       recovering a request actor hint as the effective actor. *)
    | Some (Error err) -> Error err
    | _ ->
    (match dashboard_actor_for_request ~base_path:config.base_path request with
    | Some agent_name -> Ok agent_name
    | None ->
      if auth_cfg.enabled && auth_cfg.require_token && token_present
      then
        Error
          (Masc_domain.Auth
             (Masc_domain.Auth_error.Unauthorized
                { reason = Missing_token
                ; message = "Agent name required (X-Gate-Agent / X-MASC-Agent or token-bound \
                             credential)"
                }))
      else Ok "dashboard")
  in
  let effective_agent =
    match resolved_agent_name_result with
    | Ok agent_name -> Some agent_name
    | Error _ -> None
  in
  let effective_role_result =
    match resolved_agent_name_result with
    | Error err -> Error err
    | Ok agent_name ->
      Auth.resolve_role_with_auth_config config.base_path ~auth_cfg ~agent_name ~token
  in
  let endpoint_gate_result =
    match
      if token_present
      then Ok ()
      else
        ensure_same_origin_browser_request
          ~request_authority:(Server_request_authority.current_exn ())
          request
    with
    | Error err -> Error err
    | Ok () ->
      (match
         ensure_strict_http_token_auth
           ~endpoint:"HTTP tool access for masc_keeper_delegate"
           auth_cfg
       with
       | Ok _ -> Ok ()
       | Error msg -> Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
           { reason = Generic; message = msg })))
  in
  let keeper_authorization_result =
    match endpoint_gate_result with
    | Error err -> Error err
    | Ok () ->
      (match resolved_agent_name_result, effective_role_result with
       | Error err, _ | _, Error err -> Error err
       | Ok agent_name, Ok role ->
         Auth.authorize_tool_for_role ~agent_name ~role ~tool_name:"masc_keeper_delegate")
  in
  let can_keeper_msg, keeper_msg_error =
    match keeper_authorization_result with
    | Ok () -> true, None
    | Error err -> false, Some (Masc_domain.masc_error_to_string err)
  in
  let effective_admin =
    match effective_role_result with
    | Ok role -> Some (role = Masc_domain.Admin)
    | Error _ -> None
  in
  let effective_role =
    match effective_role_result with
    | Ok role -> Some (Masc_domain.agent_role_to_string role)
    | Error _ -> None
  in
  let auth_error =
    match token_credential_result with
    | Some (Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _) as err)) ->
      Some err
    | Some (Error (Masc_domain.Auth (Masc_domain.Auth_error.TokenExpired _) as err)) ->
      Some err
    | Some (Error err) -> Some err
    | _ ->
      (match keeper_authorization_result with
       | Error err -> Some err
       | Ok () -> None)
  in
  `Assoc
    [ "enabled", `Bool auth_cfg.enabled
    ; "require_token", `Bool auth_cfg.require_token
    ; "token_present", `Bool token_present
    ; "token_valid", `Bool token_valid
    ; "token_agent", Json_util.string_opt_to_json token_agent
    ; "requested_agent", Json_util.string_opt_to_json requested_agent
    ; "effective_agent", Json_util.string_opt_to_json effective_agent
    ; "effective_role", Json_util.string_opt_to_json effective_role
    ; ( "auth_error_code"
      , Json_util.string_opt_to_json (Option.bind auth_error dashboard_auth_error_code) )
    ; ( "auth_error_detail"
      , match auth_error with
        | Some err -> `String (Masc_domain.masc_error_to_string err)
        | None -> `Null )
    ; "effective_admin", Json_util.bool_opt_to_json effective_admin
    ; "can_keeper_msg", `Bool can_keeper_msg
    ; "keeper_msg_error", Json_util.string_opt_to_json keeper_msg_error
    ]
;;

let dashboard_shell_with_request_auth_json ~request (config : Workspace.config) payload =
  match payload with
  | `Assoc fields ->
    `Assoc
      (("auth", dashboard_shell_auth_json ~request config)
       :: List.remove_assoc "auth" fields)
  | other -> other
;;

let dashboard_shell_http_json
      ?clock
      ?request
      ?timing
      ?(light = false)
      (config : Workspace.config)
  : Yojson.Safe.t
  =
  let cache_key = dashboard_shell_cache_key ~light config in
  let compute () =
    (* Shell endpoint is read-only; use config directly without isolation
       since state is not available in this context.

       The payload compute runs status / agents / tasks / keepers and
       configuration/runtime-resolution projections. Under cache miss this
       used to run inline on the calling
       fiber's Eio main domain, blocking every other HTTP fiber for the
       duration — the same Eio cooperative scheduling violation that
       PRs #18991 / #18993 / #18994 / #19007 / #19015 / #19023 / #19024 /
       #19025 / #19031 fixed for the other dashboard projections.

       [Domain_pool_ref.submit_io_or_inline] runs the compute on a
       worker domain when the pool is wired, so the main HTTP domain
       keeps serving requests during the cold-shell refresh. *)
    Domain_pool_ref.submit_io_or_inline (fun () ->
      dashboard_shell_payload_json ?timing ~light config)
  in
  let clock_opt =
    match clock with
    | Some clock -> Some clock
    | None -> Eio_context.get_clock_opt ()
  in
  let fallback_payload_with_source () =
    match dashboard_shell_last_good_with_source ~light () with
    | Some (json, source) -> json, source
    | None -> dashboard_shell_bootstrap_json config, "bootstrap"
  in
  let fallback_payload () =
    let payload, _source = fallback_payload_with_source () in
    payload
  in
  let timeout_fallback_payload timeout_sec =
    let fallback, fallback_source = fallback_payload_with_source () in
    let trace_status, active, top, elapsed_ms = shell_projection_trace_log cache_key in
    Log.Dashboard.warn
      "dashboard shell timeout fallback: key=%s timeout=%.0fs source=%s trace=%s \
       elapsed=%dms active=[%s] top=[%s]"
      cache_key
      timeout_sec
      fallback_source
      trace_status
      elapsed_ms
      active
      top;
    extend_projection_diagnostics
      fallback
      ([ "cache_state", `String "timeout_fallback"
       ; "fallback_source", `String fallback_source
       ; "timeout_cache_key", `String cache_key
       ; "timeout_sec", `Float timeout_sec
       ; "timeout_light", `Bool light
       ]
       @ shell_projection_trace_diagnostics cache_key)
  in
  let startup_shell_bootstrap_pending =
    let current = Server_startup_state.(!state) in
    (not (Atomic.get shell_warmed))
    && current.state_ready
    && Server_startup_state.elapsed_since_start () < dashboard_shell_timeout_s +. startup_grace_period_s
  in
  let apply_startup_prewarm_guard = Option.is_some request in
  let startup_prewarm_pending =
    apply_startup_prewarm_guard
    && (Atomic.get shell_warming || startup_shell_bootstrap_pending)
    && not (Atomic.get shell_warmed)
  in
  let cache_load () =
    match clock_opt with
    | Some clock ->
      Dashboard_cache.get_or_compute_with_timeout
        cache_key
        ~ttl:shell_surface_cache_ttl_s
        ~clock
        ~timeout_sec:(dashboard_shell_timeout_for ~light)
        compute
    | None -> Dashboard_cache.get_or_compute cache_key ~ttl:shell_surface_cache_ttl_s compute
  in
  let payload =
    if startup_prewarm_pending
    then fallback_payload ()
    else (
      let computed =
        match timing with
        | None -> cache_load ()
        | Some t -> Server_timing.measure t Cache_lookup cache_load
      in
      if is_dashboard_cache_timeout_json computed
      then timeout_fallback_payload (dashboard_shell_timeout_for ~light)
      else (
        remember_dashboard_shell_last_good ~light computed;
        computed))
  in
  match request with
  | None -> payload
  | Some request -> dashboard_shell_with_request_auth_json ~request config payload
;;

let () =
  Dashboard_snapshot.register_dashboard_shell_payload_json (fun ?light config ->
      dashboard_shell_payload_json ?light config)
;;
