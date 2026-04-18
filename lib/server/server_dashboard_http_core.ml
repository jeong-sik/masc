
open Types
open Server_utils
open Server_auth

(* Re-export cache types and helpers from sub-module *)
include Server_dashboard_http_cache

type dashboard_compute_mode =
  Server_dashboard_http_runtime_support.dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

let runtime_support = Server_dashboard_http_runtime_support.default ()

(** Executor pool for CPU-heavy dashboard compute.
    Pool reference is shared via [Executor_pool_ref] in masc_core. *)
let set_executor_pool = Server_dashboard_http_runtime_support.set_executor_pool

let dashboard_runtime ?net ?mono_clock (config : Coord.config) :
    Server_dashboard_http_runtime_support.runtime option =
  let _ = config in
  match net, mono_clock with
  | Some net, Some mono_clock -> Some { net; mono_clock }
  | _ -> None

let run_dashboard_compute ?(mode = Offloaded_readonly) ?net ?mono_clock ~sw ~clock
    ~(config : Coord.config) compute =
  let runtime = dashboard_runtime ?net ?mono_clock config in
  Server_dashboard_http_runtime_support.run_dashboard_compute runtime_support
    ~mode ?runtime ~sw ~clock ~config compute

let state_dashboard_runtime_caps (state : Mcp_server.server_state) =
  (state.Mcp_server.net, state.Mcp_server.mono_clock)

(* ================================================================ *)
(* Dashboard Data (Batch API)                                       *)
(* ================================================================ *)

include Dashboard_http_helpers
include Dashboard_http_monitoring
include Dashboard_http_keeper

let dashboard_request_timeout_s = 30.0

(** Track whether shell cache has been populated at least once.
    Atomic.t for cross-domain visibility: read from executor pool
    worker domains via namespace-truth and warmup helpers. *)
let _shell_warmed : bool Atomic.t = Atomic.make false

(** Track whether the startup shell pre-warm fiber is still building the
    first payload. Cold HTTP requests use this to serve a bootstrap payload
    instead of blocking on the same expensive shell projection. *)
let _shell_warming : bool Atomic.t = Atomic.make false

(** Last-known-good shell result for graceful degradation on timeout. *)
let _last_good_shell : Yojson.Safe.t Atomic.t = Atomic.make (`Assoc [])

(** Wrap a dashboard computation with a configurable timeout.
    Returns a partial-response JSON on timeout instead of hanging. *)
let with_dashboard_timeout ~clock compute =
  match Eio.Time.with_timeout clock dashboard_request_timeout_s (fun () -> Ok (compute ())) with
  | Ok v -> v
  | Error `Timeout ->
      `Assoc [
        ("error", `String "timeout");
        ("partial", `Bool true);
        ("message", `String (Printf.sprintf "Dashboard computation timed out after %.0fs." dashboard_request_timeout_s));
        ("generated_at", `String (Types.now_iso ()));
      ]

let room_scope_cache_segment (_config : Coord.config) = "default"

let room_scoped_cache_key (config : Coord.config) prefix suffix =
  Printf.sprintf "%s:%s:%s:%s" prefix config.base_path
    (room_scope_cache_segment config) suffix

let dashboard_mission_timeout_s = 25.0

let attach_projection_diagnostics json diagnostics =
  match json with
  | `Assoc fields -> `Assoc (("projection_diagnostics", diagnostics) :: fields)
  | other -> other

let projection_diagnostics_json ~surface ~started_at ~extra json =
  let build_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
  let payload_bytes = String.length (Yojson.Safe.to_string json) in
  `Assoc
    ([
       ("surface", `String surface);
       ("build_ms", `Int build_ms);
       ("payload_bytes", `Int payload_bytes);
       ("generated_at", `String (Types.now_iso ()));
     ]
    @ extra)

let with_projection_diagnostics ~surface ~started_at ~extra json =
  attach_projection_diagnostics json
    (projection_diagnostics_json ~surface ~started_at ~extra json)

let initialized_json_opt ?(allow_initializing = false) = function
  | `Assoc fields as json -> (
      match List.assoc_opt "status" fields with
      | Some (`String "initializing") when not allow_initializing -> None
      | _ -> Some json)
  | _ -> None

let dashboard_batch_json ?(compact = false) (config : Coord.config) : Yojson.Safe.t =
  let room_state = Coord.read_state config in
  let tempo = Tempo.get_tempo config in
  (* M-17 fix: single-namespace, queries scoped by basepath *)
  let tasks = Coord.get_tasks_safe config in
  let agents = Coord.get_active_agents config in
  let msgs = Coord.get_messages_raw config ~since_seq:0 ~limit:20 in
  let now_ts = Time_compat.now () in
  let (board_monitor_json, board_contract_ok) = board_monitoring_json ~now_ts in
  let (governance_monitor_json, governance_feed_ok) =
    governance_monitoring_json ~now_ts ~base_path:config.base_path
  in

  let proactive_fallback_warn = 0.20 in
  let proactive_fallback_bad = 0.40 in
  let proactive_similarity_warn = 0.90 in
  let proactive_similarity_bad = 0.97 in
  let alert_toast_cooldown_sec = 300 in
  let cluster = Env_config_core.cluster_name () in
  let status_json =
    `Assoc [
      ("cluster", `String cluster);
      ("base_path", `String config.base_path);
      ("coordination_root", `String config.base_path);
      ("workspace_path", `String config.workspace_path);
      ("workspace_differs", `Bool (config.workspace_path <> config.base_path));
      ("cluster", `String (Env_config_core.cluster_name ()));
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("tool_call_health", tool_call_health_json config);
      ("alert_thresholds", `Assoc [
        ("proactive_fallback_warn", `Float proactive_fallback_warn);
        ("proactive_fallback_bad", `Float (max proactive_fallback_warn proactive_fallback_bad));
        ("proactive_similarity_warn", `Float proactive_similarity_warn);
        ("proactive_similarity_bad", `Float (max proactive_similarity_warn proactive_similarity_bad));
        ("toast_cooldown_sec", `Int alert_toast_cooldown_sec);
      ]);
      ("monitoring", `Assoc [
        ("board", board_monitor_json);
        ("governance", governance_monitor_json);
        ("room_state", Coord_eio.state_health_counters ());
        ("executor", executor_outcomes_json config);
        ("slots", slot_monitoring_json ());
      ]);
      ("data_quality", `Assoc [
        ("board_contract_ok", `Bool board_contract_ok);
        ("governance_feed_ok", `Bool governance_feed_ok);
        ("last_sync_at", `String (Types.now_iso ()));
      ]);
    ]
  in
  let tasks_json =
    List.map (fun (t : Types.task) ->
      let base_fields =
        [
          ("id", `String t.id);
          ("title", `String t.title);
          ("description", `String t.description);
          ("status", `String (Types.string_of_task_status t.task_status));
          ("priority", `Int t.priority);
          ( "assignee",
            match t.task_status with
            | Claimed { assignee; _ }
            | InProgress { assignee; _ }
            | Done { assignee; _ } ->
                `String assignee
            | _ -> `Null );
          ("created_at", `String t.created_at);
        ]
      in
      let projection_fields =
        match (fun _t -> ignore config; `Assoc []) t with
        | `Assoc fields -> fields
        | _ -> []
      in
      `Assoc (base_fields @ projection_fields))
      (List.filter
         (fun (t : Types.task) ->
           match t.task_status with
           | Types.Cancelled _ -> false
           | Types.Done _ -> not compact
           | _ -> true)
         tasks)
  in
  let agents_json =
    List.map (fun (a : Types.agent) ->
      let profile = Dashboard_execution_helpers.get_agent_profile a.name in
      `Assoc [
        ("name", `String a.name);
        ("status", `String (Types.string_of_agent_status a.status));
        ("current_task", Json_util.string_opt_to_json a.current_task);
        ("last_seen", `String a.last_seen);
        ("emoji", `String profile.emoji);
        ("koreanName", `String profile.korean_name);
        ("model", Json_util.string_opt_to_json profile.model);
        ("traits", `List (List.map (fun t -> `String t) profile.traits));
        ("interests", `List (List.map (fun i -> `String i) profile.interests));
        ("activityLevel", Json_util.float_opt_to_json profile.activity_level);
        ("primaryValue", Json_util.string_opt_to_json profile.primary_value);
        ("generation", `Null);
        ("context_ratio", `Null);
        ("turn_count", `Null);
      ]
    ) agents
  in
  let msgs_json =
    List.map
      (fun (m : Types.message) ->
        `Assoc [
          ("from", `String m.from_agent);
          ("content", `String m.content);
          ("timestamp", `String m.timestamp);
          ("seq", `Int m.seq);
        ])
      (List.filteri (fun idx _ -> idx < 20) msgs)
  in
  `Assoc [
    ("status", status_json);
    ("tasks", `Assoc [ ("tasks", `List tasks_json); ("total", `Int (List.length tasks_json)) ]);
    ("agents", `Assoc [ ("agents", `List agents_json); ("total", `Int (List.length agents_json)) ]);
    ("messages", `Assoc [ ("messages", `List msgs_json); ("total", `Int (List.length msgs_json)) ]);
    ("keepers", keepers_dashboard_json ~compact config);
  ]

(** Strip non-ASCII characters from actor string.
    Prevents IME artifacts (e.g. Korean ㅊ) from polluting cache keys. *)
let sanitize_actor s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> Buffer.add_char buf c
    | _ -> ()
  ) s;
  Buffer.contents buf

let operator_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let sanitized = sanitize_actor (String.trim raw) in
      if sanitized = "" then None else Some sanitized
  | None -> None

(* --- Operator proactive refresh ---
   Default (no-param) requests are served from a background-refreshed ref.
   Parameterized requests fall back to on-demand compute with SWR cache.

   Using Proactive_refresh gives circuit breaker + exponential backoff on
   repeated failures, matching the pattern used by execution and mission loops.

   Interval: 10s (was 120s). Even if compute takes ~8s, the ref is updated
   every ~18s worst-case, which is acceptable for dashboard SSE polling. *)

(* Late-bound broadcast refs — set by server_dashboard_http.ml after
   Sse module is in scope.  Same pattern as _broadcast_room_truth_ref. *)
let _operator_snapshot_broadcast_ref : (Yojson.Safe.t -> unit) ref =
  ref (fun (_json : Yojson.Safe.t) -> ())

let _operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref =
  ref (fun (_json : Yojson.Safe.t) -> ())

let _operator_snapshot_cache =
  create_cached_surface
    (`Assoc [ ("status", `String "initializing"); ("generated_at", `String (Types.now_iso ())) ])

let _operator_digest_cache =
  create_cached_surface
    (`Assoc [ ("health", `String "initializing"); ("generated_at", `String (Types.now_iso ())) ])

let _operator_refresh_interval_s =
  float_of_env_default
    "MASC_OPERATOR_REFRESH_INTERVAL_S"
    ~default:60.0
    ~min_v:10.0
    ~max_v:600.0

let operator_snapshot_extra () =
  [
    ("readonly_pool", Coord_utils.domain_local_pg_backend_diagnostics_json ());
  ]

let start_operator_snapshot_refresh_loop ~state ~sw ~clock =
  let config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = state_dashboard_runtime_caps state in
  let compute () =
    mark_cached_surface_attempt _operator_snapshot_cache;
    let started_at = Unix.gettimeofday () in
    try
      run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
        ~clock ~config
        (fun ~config ~sw ->
          let ctx : _ Operator_control.context =
            {
              config;
              agent_name = "dashboard";
              sw;
              clock;
              proc_mgr;
              net = None;
              mcp_session_id = None;
            }
          in
          let t_snapshot = Unix.gettimeofday () in
          let json =
            Operator_control.snapshot_json ~actor:"dashboard" ~view:"summary"
              ~include_messages:true ~include_keepers:true
              ~include_summary_fields:false
              ~lightweight_summary:true
              ctx
          in
          let dt_snapshot = Unix.gettimeofday () -. t_snapshot in
          let dt_total = Unix.gettimeofday () -. started_at in
          if dt_total >= 5.0 then
            Log.Dashboard.warn
              "[operator_snapshot profile] total=%.1fs snapshot=%.1fs"
              dt_total dt_snapshot;
          json
          |> with_projection_diagnostics ~surface:"operator_snapshot" ~started_at
               ~extra:(operator_snapshot_extra ()))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error _operator_snapshot_cache exn;
      raise exn
  in
  Proactive_refresh.start ~sw ~clock
    ~config:{ (Proactive_refresh.default_config
                 ~label:"operator_snapshot"
                 ~interval_s:_operator_refresh_interval_s)
              with timeout_s = _operator_refresh_interval_s *. 0.8;
                   warm_delay_s = 120.0 }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success _operator_snapshot_cache json;
      !_operator_snapshot_broadcast_ref json)

let start_operator_digest_refresh_loop ~state ~sw ~clock =
  let config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = state_dashboard_runtime_caps state in
  let compute () =
    mark_cached_surface_attempt _operator_digest_cache;
    let started_at = Unix.gettimeofday () in
    try
      run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
        ~clock ~config
        (fun ~config ~sw ->
          let ctx : _ Operator_control.context =
            {
              config;
              agent_name = "dashboard";
              sw;
              clock;
              proc_mgr;
              net = None;
              mcp_session_id = None;
            }
          in
          match
            Operator_control.digest_json ~actor:"dashboard" ~target_type:"root"
              ctx
          with
          | Ok json ->
              with_projection_diagnostics ~surface:"operator_digest" ~started_at
                ~extra:(operator_snapshot_extra ()) json
          | Error err -> raise (Failure err))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error _operator_digest_cache exn;
      raise exn
  in
  Proactive_refresh.start ~sw ~clock
    ~config:{ (Proactive_refresh.default_config
                 ~label:"operator_digest"
                 ~interval_s:_operator_refresh_interval_s)
              with timeout_s = _operator_refresh_interval_s *. 0.8;
                   warm_delay_s = 150.0 }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success _operator_digest_cache json;
      !_operator_digest_broadcast_ref json)

let operator_snapshot_http_json ~state ~sw ~clock request =
  let net, mono_clock = state_dashboard_runtime_caps state in
  let actor = operator_actor_hint request in
  let view = query_param request "view" in
  let default_summary_request =
    actor = None
    && query_param request "include_messages" = None
    && query_param request "include_keepers" = None
    &&
    match view with
    | None -> true
    | Some raw -> String.equal (String.lowercase_ascii (String.trim raw)) "summary"
  in
  if default_summary_request then
    cached_surface_json _operator_snapshot_cache
  else begin
    let started_at = Unix.gettimeofday () in
    let include_messages =
      match query_param request "include_messages" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    let include_keepers =
      match query_param request "include_keepers" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    let lightweight_summary =
      match view with
      | Some raw -> String.equal (String.lowercase_ascii (String.trim raw)) "summary"
      | None -> false
    in
    let mode =
      if lightweight_summary then Inline_shared else Offloaded_readonly
    in
    match Eio.Time.with_timeout clock dashboard_request_timeout_s (fun () ->
      Ok
        (run_dashboard_compute ~mode ?net ?mono_clock ~sw ~clock
           ~config:state.Mcp_server.room_config
           (fun ~config ~sw ->
             let ctx : _ Operator_control.context =
               {
                 config;
                 agent_name = Option.value ~default:"dashboard" actor;
                 sw;
                 clock;
                 proc_mgr = state.Mcp_server.proc_mgr;
                 net = state.Mcp_server.net;
                 mcp_session_id = None;
               }
             in
            Operator_control.snapshot_json ?actor ?view
               ~include_messages ~include_keepers
               ~include_summary_fields:(not lightweight_summary)
               ~lightweight_summary
               ctx))
    ) with
    | Ok json ->
        with_projection_diagnostics ~surface:"operator_snapshot" ~started_at
          ~extra:
            [
              ("readonly_pool", Coord_utils.domain_local_pg_backend_diagnostics_json ());
            ]
          json
    | Error `Timeout ->
        `Assoc [
          ("error", `String "timeout");
          ("message", `String "Operator snapshot timed out after 30s");
          ("generated_at", `String (Types.now_iso ()));
        ]
  end

let operator_digest_http_json ~state ~sw ~clock request =
  let net, mono_clock = state_dashboard_runtime_caps state in
  let actor = operator_actor_hint request in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let include_workers =
    match query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | _ -> None
  in
  let namespace_target_type value =
    match Option.map (fun raw -> String.lowercase_ascii (String.trim raw)) value with
    | None -> true
    | Some "root" | Some "namespace" | Some "room" -> true
    | Some _ -> false
  in
  let default_namespace_request =
    actor = None
    && target_id = None
    && include_workers = None
    && namespace_target_type target_type
  in
  if default_namespace_request then
    Ok (cached_surface_json _operator_digest_cache)
  else
    let started_at = Unix.gettimeofday () in
    let effective_target_type =
      Option.value ~default:"root" target_type
    in
    match Eio.Time.with_timeout clock dashboard_request_timeout_s (fun () ->
      Ok
        (run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
           ~clock
           ~config:state.Mcp_server.room_config
           (fun ~config ~sw ->
             let ctx : _ Operator_control.context =
               {
                 config;
                 agent_name = Option.value ~default:"dashboard" actor;
                 sw;
                 clock;
                 proc_mgr = state.Mcp_server.proc_mgr;
                 net = state.Mcp_server.net;
                 mcp_session_id = None;
               }
             in
             match
               Operator_control.digest_json ?actor ~target_type:effective_target_type
                 ?target_id ?include_workers
                 ctx
             with
             | Ok json -> json
             | Error err ->
                 `Assoc
                   [
                     ("error", `String "validation_error");
                     ("message", `String err);
                     ("generated_at", `String (Types.now_iso ()));
                   ]))
    ) with
    | Ok json ->
        Ok
          (with_projection_diagnostics ~surface:"operator_digest" ~started_at
             ~extra:
               [
                 ("readonly_pool", Coord_utils.domain_local_pg_backend_diagnostics_json ());
               ]
             json)
    | Error `Timeout ->
        Ok
          (`Assoc
            [
              ("error", `String "timeout");
              ("message", `String "Operator digest timed out after 30s");
              ("generated_at", `String (Types.now_iso ()));
            ])

(* --- Mission proactive refresh ----------------------------------------
   A background fiber recomputes the mission snapshot periodically.
   The HTTP handler returns the cached ref immediately (0ms).
   Actor-parameterized requests fall back to on-demand compute with
   SWR cache. *)

let _mission_cache =
  create_cached_surface
    (`Assoc
      [
        ("generated_at", `String (Types.now_iso ()));
        ("summary", `Assoc [("room_health", `String "initializing")]);
        ("incidents", `List []);
        ("recommended_actions", `List []);
        ("command_focus", `Assoc []);
        ("operator_targets", `Assoc []);
        ("attention_queue", `List []);
        ("agent_briefs", `List []);
        ("keeper_briefs", `List []);
        ("internal_signals", `List []);
      ])

let start_mission_refresh_loop ~state ~sw ~clock =
  let room_config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  let net, mono_clock = state_dashboard_runtime_caps state in
  let mission_refresh_timeout_s = 60.0 in
  let compute () =
    mark_cached_surface_attempt _mission_cache;
    let t0_mission = Unix.gettimeofday () in
    try
      run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
        ~clock ~config:room_config
        |> fun run_compute ->
        let result =
          run_compute
          (fun ~config ~sw ->
            Dashboard_mission.json ~config ~sw
              ~clock ~proc_mgr ())
        in
      let dt_total = Unix.gettimeofday () -. t0_mission in
      if dt_total >= 5.0 then
        Log.Dashboard.warn
          "[mission profile] total=%.1fs"
          dt_total;
      result
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      mark_cached_surface_error _mission_cache exn;
      raise exn
  in
  Proactive_refresh.start ~sw ~clock
    ~config:{ (Proactive_refresh.default_config ~label:"mission" ~interval_s:120.0)
              with timeout_s = mission_refresh_timeout_s;
                   warm_delay_s = 90.0 }
    ~compute
    ~on_result:(mark_cached_surface_success _mission_cache)

let dashboard_mission_http_json ~state ~sw ~clock request =
  let net, mono_clock = state_dashboard_runtime_caps state in
  let actor = operator_actor_hint request in
  let compute ?actor () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
      ~clock
      ~config:state.Mcp_server.room_config
      (fun ~config ~sw ->
        Dashboard_mission.json ?actor
          ~config ~sw ~clock
          ~proc_mgr:state.Mcp_server.proc_mgr ())
    |> with_projection_diagnostics ~surface:"mission" ~started_at
         ~extra:[]
  in
  let full_json =
    match actor with
    | None ->
        (* Mirror execution surface behavior: serve cached mission instantly
           after the first success, but let the very first default read
           bootstrap that success instead of staying "initializing" forever
           when proactive warm-up misses its first build window. *)
        cached_surface_or_first_success_json _mission_cache
          ~cache_key:"mission:default" ~ttl:120.0 ~clock ~timeout_sec:dashboard_mission_timeout_s
          (fun () -> compute ())
    | Some _ ->
      (* Actor-parameterized: on-demand with SWR cache. *)
      let cache_key =
        room_scoped_cache_key state.Mcp_server.room_config "mission"
          (Option.value ~default:"" actor)
      in
      Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:120.0
        ~clock ~timeout_sec:dashboard_mission_timeout_s (compute ?actor)
  in
  full_json

let dashboard_session_http_json ~state ~sw ~clock request =
  match query_param request "session_id" with
  | Some session_id when String.trim session_id <> "" ->
      Dashboard_mission.session_json ?actor:(operator_actor_hint request)
        ~session_id:(String.trim session_id)
        ~config:state.Mcp_server.room_config ~sw ~clock
        ~proc_mgr:state.Mcp_server.proc_mgr ()
  | _ ->
      `Assoc
        [
          ("generated_at", `String (Types.now_iso ()));
          ("session_id", `Null);
          ("session", `Null);
          ("timeline", `List []);
          ("participants", `List []);
          ("operations", `List []);
          ("keepers", `List []);
          ("error", `String "session_id is required");
        ]

let dashboard_mission_briefing_http_json ~state ~sw ~clock request =
  let actor = operator_actor_hint request in
  let force = bool_query_param request "force" ~default:false in
  let compute () =
    Dashboard_mission_briefing.json ?actor ~force
      ~config:state.Mcp_server.room_config ~sw ~clock
      ~proc_mgr:state.Mcp_server.proc_mgr ()
  in
  if force then with_dashboard_timeout ~clock compute
  else
    let cache_key =
      room_scoped_cache_key state.Mcp_server.room_config "mission_briefing"
        (Option.value ~default:"" actor)
    in
    Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:5.0
      ~clock ~timeout_sec:dashboard_mission_timeout_s compute

let dashboard_shell_status_json (config : Coord.config) : Yojson.Safe.t =
  let room_state = Coord.read_state config in
  let cluster = Env_config_core.cluster_name () in
  let tempo = Tempo.get_tempo config in
  let build = Build_identity.current () in
  `Assoc
    [
      ("cluster", `String cluster);
      ("base_path", `String config.base_path);
      ("coordination_root", `String config.base_path);
      ("workspace_path", `String config.workspace_path);
      ("workspace_differs", `Bool (config.workspace_path <> config.base_path));
      ("cluster", `String (Env_config_core.cluster_name ()));
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ }
  | AwaitingVerification { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json config (task : Types.task) =
  let base_fields =
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", Json_util.string_opt_to_json (dashboard_task_assignee task));
      ("created_at", `String task.created_at);
    ]
  in
  let projection_fields =
    match (fun _t -> ignore config; `Assoc []) task with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (base_fields @ projection_fields)

let dashboard_agent_json (agent : Types.agent) =
  let profile = Dashboard_execution_helpers.get_agent_profile agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", Json_util.string_opt_to_json agent.current_task);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) agent.capabilities));
      ("emoji", `String profile.emoji);
      ("koreanName", `String profile.korean_name);
      ("model", Json_util.string_opt_to_json profile.model);
      ("traits", `List (List.map (fun t -> `String t) profile.traits));
      ("interests", `List (List.map (fun i -> `String i) profile.interests));
      ("activityLevel", Json_util.float_opt_to_json profile.activity_level);
      ("primaryValue", Json_util.string_opt_to_json profile.primary_value);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

(* dashboard_current_room_id removed — namespace retired (#unify-namespace). *)

let dashboard_tasks_safe config =
  Coord.get_tasks_safe config

let dashboard_agents_safe config =
  Coord.get_active_agents config

let dashboard_messages_safe config ~since_seq ~limit =
  Coord.get_messages_raw config ~since_seq ~limit

let is_keeper_agent (agent : Types.agent) =
  String.equal (String.lowercase_ascii (String.trim agent.agent_type)) "keeper"

let dashboard_general_agent_count agents =
  agents
  |> List.fold_left
       (fun count agent -> if is_keeper_agent agent then count else count + 1)
       0

let provider_capacity_json () : Yojson.Safe.t =
  `Assoc []

let dashboard_shell_timeout_s = 16.0

(* Meta_cognition.summary_json does a full board_posts.jsonl scan +
   belief/tension/desire rule evaluation. On a room with 450+ posts this
   regularly exceeds 8s, which was the previous shell timeout and caused
   repeat "cache compute timeout: shell:..." + "cache bg-revalidate failed"
   noise in the log. Give it its own cache with a longer TTL so the shell
   path does not block on it every refresh cycle. *)
let meta_cognition_summary_ttl = 120.0

let meta_cognition_summary_cached (config : Coord.config) : Yojson.Safe.t =
  let key = Printf.sprintf "meta_cognition_summary:%s" config.base_path in
  Dashboard_cache.get_or_compute key ~ttl:meta_cognition_summary_ttl (fun () ->
    Meta_cognition.summary_json config)

let dashboard_shell_paths_json (config : Coord.config) : Yojson.Safe.t =
  Server_base_path_diagnostics.detect
    ?input_base_path:(Env_config_core.base_path_raw_opt ())
    ?env_masc_base_path:(Env_config_core.base_path_raw_opt ())
    ~effective_base_path:config.base_path
    ~effective_masc_root:(Coord.masc_root_dir config)
    ()
  |> Server_base_path_diagnostics.to_yojson

let dashboard_shell_bootstrap_json (config : Coord.config) : Yojson.Safe.t =
  let generated_at = Types.now_iso () in
  let started_at = Unix.gettimeofday () in
  `Assoc
    [
      ("generated_at", `String generated_at);
      ( "status",
        `Assoc
          [
            ("project", `String "initializing");
            ("generated_at", `String generated_at);
          ] );
      ("paths", dashboard_shell_paths_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int 0);
            ("tasks", `Int 0);
            ("keepers", `Int 0);
            ("total_runtimes", `Int 0);
          ] );
      ("configured_keepers", `Int 0);
      ("providers", `Assoc []);
      ("meta_cognition", `Null);
      ("config_resolution", `Null);
      ("runtime_resolution", `Null);
    ]
  |> with_projection_diagnostics ~surface:"shell" ~started_at
       ~extra:
         [
           ("cache_state", `String "initializing");
           ("bootstrap_source", `String "shell_prewarm");
         ]

let dashboard_shell_last_good_opt () =
  match Atomic.get _last_good_shell with
  | `Assoc [] -> None
  | json -> Some json

let is_dashboard_cache_timeout_json = function
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`String "Compute timeout") -> true
      | _ -> false)
  | _ -> false

let dashboard_shell_payload_json (config : Coord.config) : Yojson.Safe.t =
  let cluster = Env_config_core.cluster_name () in
  let started_at = Unix.gettimeofday () in
  let measure_ms f =
    let t0 = Unix.gettimeofday () in
    let value = f () in
    let elapsed_ms = int_of_float ((Unix.gettimeofday () -. t0) *. 1000.0) in
    (value, elapsed_ms)
  in
  let measure_json_projection label f =
    measure_ms (fun () ->
        try f () with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Server.warn "dashboard shell %s projection failed: %s" label
              (Printexc.to_string exn);
            `Null)
  in
  (* Cold workspaces lazily materialize room/keeper state on first access.
     Keep those stateful reads sequential so one failing init path does not
     cancel sibling fibers and poison shared Eio mutexes. Retain parallelism
     only for projection-style reads that are safe to drop to `Null`. *)
  let status_json, status_ms = measure_ms (fun () -> dashboard_shell_status_json config) in
  let agents, agents_ms = measure_ms (fun () -> dashboard_agents_safe config) in
  let general_agents = dashboard_general_agent_count agents in
  let tasks, tasks_ms = measure_ms (fun () -> dashboard_tasks_safe config) in
  let active_keepers, keepers_ms = measure_ms (fun () -> running_keeper_count config) in
  let configured_keepers, configured_keepers_ms =
    measure_ms (fun () -> keeper_count config)
  in
  let meta_cognition_r = ref (`Null, 0) in
  let config_resolution_r = ref (`Null, 0) in
  let runtime_resolution_r = ref (`Null, 0) in
  Eio.Fiber.all
    [
      (fun () ->
        meta_cognition_r :=
          measure_json_projection "meta_cognition" (fun () ->
              meta_cognition_summary_cached config));
      (fun () ->
        config_resolution_r :=
          measure_json_projection "config_resolution" (fun () ->
              Config_dir_resolver.(resolve () |> to_json)));
      (fun () ->
        runtime_resolution_r :=
          measure_json_projection "runtime_resolution" (fun () ->
              Server_dashboard_http_runtime_info.runtime_resolution_json config));
    ];
  let meta_cognition_json, meta_cognition_ms = !meta_cognition_r in
  let config_resolution_json, config_resolution_ms = !config_resolution_r in
  let runtime_resolution_json, runtime_resolution_ms = !runtime_resolution_r in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", status_json);
      ("paths", dashboard_shell_paths_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int general_agents);
            ("tasks", `Int (List.length tasks));
            ("keepers", `Int active_keepers);
            ("total_runtimes", `Int (general_agents + active_keepers));
          ] );
      ("configured_keepers", `Int configured_keepers);
      ("providers", provider_capacity_json ());
      ("meta_cognition", meta_cognition_json);
      ("config_resolution", config_resolution_json);
      ("runtime_resolution", runtime_resolution_json);
    ]
  |> with_projection_diagnostics ~surface:"shell" ~started_at
       ~extra:
         [
           ("cluster", `String cluster);
           ("coordination_root", `String config.base_path);
           ("workspace_path", `String config.workspace_path);
           ("keeper_count_source", `String "runtime_keepalive");
           ("configured_keeper_count_source", `String "keeper_meta");
           ("status_ms", `Int status_ms);
           ("agents_ms", `Int agents_ms);
           ("tasks_ms", `Int tasks_ms);
           ("keepers_ms", `Int keepers_ms);
           ("configured_keepers_ms", `Int configured_keepers_ms);
           ("meta_cognition_ms", `Int meta_cognition_ms);
           ("config_resolution_ms", `Int config_resolution_ms);
           ("runtime_resolution_ms", `Int runtime_resolution_ms);
         ]

let dashboard_shell_auth_json ~(request : Httpun.Request.t) (config : Coord.config) :
    Yojson.Safe.t =
  let auth_cfg = Auth.load_auth_config config.base_path in
  let token = auth_token_from_request request in
  let requested_agent =
    match agent_from_request request with
    | Some raw ->
        let value = String.trim raw in
        if String.equal value "" then None else Some value
    | None -> None
  in
  let token_present = Option.is_some token in
  let resolved_agent_result =
    resolve_agent_name_for_auth ~base_path:config.base_path request ~token
  in
  let resolved_agent_name_result =
    match resolved_agent_result with
    | Error err -> Error err
    | Ok agent_name_opt ->
        if auth_cfg.enabled && auth_cfg.require_token && token_present
           && Option.is_none agent_name_opt
        then
          Error
            (Types.Unauthorized
               "Agent name required (X-Gate-Agent / X-MASC-Agent or token-bound credential)")
        else
          Ok (Option.value ~default:"dashboard" agent_name_opt)
  in
  let effective_agent =
    match resolved_agent_name_result with
    | Ok agent_name -> Some agent_name
    | Error _ -> requested_agent
  in
  let effective_role_result =
    match resolved_agent_name_result with
    | Error err -> Error err
    | Ok agent_name ->
        Auth.resolve_role_with_auth_config config.base_path ~auth_cfg
          ~agent_name ~token
  in
  let endpoint_gate_result =
    match
      if token_present then Ok ()
      else ensure_same_origin_browser_request request
    with
    | Error err -> Error err
    | Ok () -> (
        match
          ensure_strict_http_token_auth
            ~endpoint:"HTTP tool access for masc_keeper_msg" auth_cfg
        with
        | Ok _ -> Ok ()
        | Error msg -> Error (Types.Unauthorized msg))
  in
  let can_keeper_msg, keeper_msg_error =
    match endpoint_gate_result with
    | Error err -> (false, Some (Types.masc_error_to_string err))
    | Ok () -> (
        match resolved_agent_name_result, effective_role_result with
        | Error err, _ | _, Error err ->
            (false, Some (Types.masc_error_to_string err))
        | Ok agent_name, Ok role -> (
            match
              Auth.authorize_tool_for_role ~agent_name ~role
                ~tool_name:"masc_keeper_msg"
            with
            | Ok () -> (true, None)
            | Error err -> (false, Some (Types.masc_error_to_string err))))
  in
  let effective_role =
    match effective_role_result with
    | Ok role -> Some (Types.agent_role_to_string role)
    | Error _ -> None
  in
  `Assoc
    [
      ("enabled", `Bool auth_cfg.enabled);
      ("require_token", `Bool auth_cfg.require_token);
      ("default_role", `String (Types.agent_role_to_string auth_cfg.default_role));
      ("token_present", `Bool token_present);
      ("requested_agent", Json_util.string_opt_to_json requested_agent);
      ("effective_agent", Json_util.string_opt_to_json effective_agent);
      ("effective_role", Json_util.string_opt_to_json effective_role);
      ("can_keeper_msg", `Bool can_keeper_msg);
      ("keeper_msg_error", Json_util.string_opt_to_json keeper_msg_error);
    ]

let dashboard_shell_http_json ?clock ?request (config : Coord.config) : Yojson.Safe.t =
  let cache_key =
    Printf.sprintf "shell:coord=%s:workspace=%s"
      config.base_path config.workspace_path
  in
  let compute () =
    (* Shell endpoint is read-only; use config directly without isolation
       since state is not available in this context. *)
    dashboard_shell_payload_json config
  in
  let clock_opt =
    match clock with
    | Some clock -> Some clock
    | None -> Eio_context.get_clock_opt ()
  in
  let fallback_payload () =
    match dashboard_shell_last_good_opt () with
    | Some json -> json
    | None -> dashboard_shell_bootstrap_json config
  in
  let startup_shell_bootstrap_pending =
    let current = Server_startup_state.(!state) in
    (not (Atomic.get _shell_warmed))
    && current.state_ready
    && Server_startup_state.elapsed_since_start ()
       < (dashboard_shell_timeout_s +. 10.0)
  in
  let apply_startup_prewarm_guard = Option.is_some request in
  let startup_prewarm_pending =
    apply_startup_prewarm_guard
    && (Atomic.get _shell_warming || startup_shell_bootstrap_pending)
    && not (Atomic.get _shell_warmed)
  in
  let payload =
    if startup_prewarm_pending then
      fallback_payload ()
    else
      let computed =
        match clock_opt with
        | Some clock ->
            Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:15.0
              ~clock ~timeout_sec:dashboard_shell_timeout_s compute
        | None ->
            Dashboard_cache.get_or_compute cache_key ~ttl:15.0 compute
      in
      if is_dashboard_cache_timeout_json computed then
        fallback_payload ()
      else
        computed
  in
  match request with
  | None -> payload
  | Some request -> (
      match payload with
      | `Assoc fields ->
          `Assoc
            (("auth", dashboard_shell_auth_json ~request config)
            :: List.remove_assoc "auth" fields)
      | other -> other)
