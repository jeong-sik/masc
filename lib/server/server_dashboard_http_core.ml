[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth

(* ================================================================ *)
(* Dashboard Data (Batch API)                                       *)
(* ================================================================ *)

include Dashboard_http_helpers
include Dashboard_http_monitoring
include Dashboard_http_keeper
include Dashboard_http_mdal

(** Wrap a dashboard computation with a 30-second timeout.
    Returns a partial-response JSON on timeout instead of hanging. *)
let with_dashboard_timeout ~clock compute =
  match Eio.Time.with_timeout clock 30.0 (fun () -> Ok (compute ())) with
  | Ok v -> v
  | Error `Timeout ->
      `Assoc [
        ("error", `String "timeout");
        ("partial", `Bool true);
        ("message", `String "Dashboard computation timed out after 30s. First request may be slow due to filesystem scan.");
        ("generated_at", `String (Types.now_iso ()));
      ]

let dashboard_semantics_http_json () =
  Dashboard_semantics.json ()

let dashboard_batch_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  (* M-17 fix: use room-scoped queries consistent with compact/shell dashboard *)
  let room_id = Room.current_room_id config in
  let tasks = Room.get_tasks_raw_in_room config room_id in
  let agents = Room.get_agents_raw_in_room config room_id in
  let msgs = Room.get_messages_raw_in_room config ~room_id ~since_seq:0 ~limit:20 in
  let lodge_json = `Assoc [("status", `String "deprecated")] in
  let social_runtime_json = Social_runtime.status_json ~config in
  let now_ts = Time_compat.now () in
  let (board_monitor_json, board_contract_ok) = board_monitoring_json ~now_ts in
  let (governance_monitor_json, governance_feed_ok) =
    governance_monitoring_json ~now_ts ~base_path:config.base_path
  in

  let proactive_fallback_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_WARN"
      ~default:0.20
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_fallback_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_BAD"
      ~default:0.40
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN"
      ~default:0.90
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_BAD"
      ~default:0.97
      ~min_v:0.0
      ~max_v:1.0
  in
  let alert_toast_cooldown_sec =
    int_of_env_default
      "MASC_DASHBOARD_ALERT_TOAST_COOLDOWN_SEC"
      ~default:300
      ~min_v:10
      ~max_v:86400
  in
  let status_json =
    `Assoc [
      ( "room",
        `String
          (if Room.is_initialized config then Room.current_room_id config
           else Filename.basename config.base_path) );
      ("room_base_path", `String config.base_path);
      ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
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
      ]);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("data_quality", `Assoc [
        ("board_contract_ok", `Bool board_contract_ok);
        ("governance_feed_ok", `Bool governance_feed_ok);
        ("last_sync_at", `String (Types.now_iso ()));
      ]);
    ]
  in
  let tasks_json =
    List.map (fun (t : Types.task) ->
      `Assoc [
        ("id", `String t.id);
        ("title", `String t.title);
        ("status", `String (Types.string_of_task_status t.task_status));
        ("priority", `Int t.priority);
        ("assignee",
         match t.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
             `String assignee
         | _ -> `Null);
      ]
    )
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
        ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
        ("last_seen", `String a.last_seen);
        ("emoji", `String profile.emoji);
        ("koreanName", `String profile.korean_name);
        ("model", match profile.model with Some m -> `String m | None -> `Null);
        ("traits", `List (List.map (fun t -> `String t) profile.traits));
        ("interests", `List (List.map (fun i -> `String i) profile.interests));
        ("activityLevel", match profile.activity_level with Some v -> `Float v | None -> `Null);
        ("primaryValue", match profile.primary_value with Some v -> `String v | None -> `Null);
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
    ("perpetual", perpetual_dashboard_json ());
  ]

let operator_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

(* --- Operator proactive refresh ---
   Default (no-param) requests are served from a background-refreshed ref.
   Parameterized requests fall back to on-demand compute with SWR cache. *)

let _operator_snapshot_ref : Yojson.Safe.t ref =
  ref (`Assoc [("status", `String "initializing"); ("generated_at", `String (Types.now_iso ()))])

let _operator_digest_ref : Yojson.Safe.t ref =
  ref (`Assoc [("health", `String "initializing"); ("generated_at", `String (Types.now_iso ()))])

let _operator_refresh_interval_s = 120.0

let start_operator_refresh_loop ~state ~sw ~clock =
  let config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  Eio.Fiber.fork ~sw (fun () ->
    Log.Dashboard.info "starting operator proactive refresh loop";
    let rec loop () =
      let t0 = Time_compat.now () in
      let ctx : _ Operator_control.context =
        { config; agent_name = "dashboard"; sw; clock; proc_mgr; mcp_session_id = None }
      in
      (try
        _operator_snapshot_ref :=
          Operator_control.snapshot_json ~actor:"dashboard"
            ~include_messages:true ~include_sessions:true ~include_keepers:true ctx;
        (match Operator_control.digest_json ~actor:"dashboard" ctx with
         | Ok json -> _operator_digest_ref := json
         | Error _ -> ());
        let dt = Time_compat.now () -. t0 in
        Log.Dashboard.info "operator refreshed (%.1fs)" dt
      with exn ->
        let dt = Time_compat.now () -. t0 in
        Log.Dashboard.warn "operator refresh failed (%.1fs): %s"
          dt (Printexc.to_string exn));
      Eio.Time.sleep clock _operator_refresh_interval_s;
      loop ()
    in
    loop ())

let operator_snapshot_http_json ~state ~sw ~clock request =
  let actor = operator_actor_hint request in
  let has_params =
    actor <> None
    || query_param request "include_messages" <> None
    || query_param request "include_sessions" <> None
    || query_param request "include_keepers" <> None
  in
  if not has_params then
    !_operator_snapshot_ref
  else begin
    let ctx : _ Operator_control.context =
      {
        config = state.Mcp_server.room_config;
        agent_name = Option.value ~default:"dashboard" actor;
        sw;
        clock;
        proc_mgr = state.Mcp_server.proc_mgr;
        mcp_session_id = None;
      }
    in
    let include_messages =
      match query_param request "include_messages" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    let include_sessions =
      match query_param request "include_sessions" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    let include_keepers =
      match query_param request "include_keepers" with
      | Some ("0" | "false" | "no") -> false
      | _ -> true
    in
    Operator_control.snapshot_json ?actor
      ~include_messages ~include_sessions ~include_keepers ctx
  end

let operator_digest_http_json ~state ~sw ~clock request =
  let actor = operator_actor_hint request in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let has_params =
    actor <> None || target_type <> None || target_id <> None
    || query_param request "include_workers" <> None
  in
  if not has_params then
    Ok !_operator_digest_ref
  else
    let ctx : _ Operator_control.context =
      {
        config = state.Mcp_server.room_config;
        agent_name = Option.value ~default:"dashboard" actor;
        sw;
        clock;
        proc_mgr = state.Mcp_server.proc_mgr;
        mcp_session_id = None;
      }
    in
    let include_workers =
      match query_param request "include_workers" with
      | Some ("0" | "false" | "no") -> Some false
      | Some ("1" | "true" | "yes") -> Some true
      | _ -> None
    in
    Operator_control.digest_json ?actor ?target_type ?target_id ?include_workers ctx

(* --- Mission proactive refresh (same pattern as execution) ----------
   A background fiber recomputes the mission snapshot every
   [_mission_refresh_interval_s] seconds.  The HTTP handler returns the
   cached ref immediately (0ms).  Actor-parameterized requests fall back
   to on-demand compute with SWR cache. *)

let _mission_json_ref : Yojson.Safe.t ref =
  ref (`Assoc [
    ("generated_at", `String (Types.now_iso ()));
    ("summary", `Assoc [("room_health", `String "initializing")]);
    ("incidents", `List []);
    ("recommended_actions", `List []);
    ("command_focus", `Assoc []);
    ("operator_targets", `Assoc []);
    ("attention_queue", `List []);
    ("sessions", `List []);
    ("session_briefs", `List []);
    ("agent_briefs", `List []);
    ("keeper_briefs", `List []);
    ("internal_signals", `List []);
  ])

let _mission_refresh_interval_s = 120.0

let start_mission_refresh_loop ~state ~sw ~clock =
  let config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  (* Warm cache: compute once synchronously so the first browser request
     sees real data instead of the empty placeholder. *)
  (let t0 = Time_compat.now () in
   try
     let json =
       Dashboard_mission.json ~config ~sw ~clock ~proc_mgr ()
     in
     _mission_json_ref := json;
     let dt = Time_compat.now () -. t0 in
     Log.Dashboard.info "mission warm cache done (%.1fs)" dt
   with exn ->
     let dt = Time_compat.now () -. t0 in
     Log.Dashboard.warn "mission warm cache failed (%.1fs): %s"
       dt (Printexc.to_string exn));
  Eio.Fiber.fork ~sw (fun () ->
    Log.Dashboard.info "starting mission proactive refresh loop";
    let rec loop () =
      let t0 = Time_compat.now () in
      (try
        let json =
          Dashboard_mission.json
            ~config ~sw ~clock ~proc_mgr ()
        in
        _mission_json_ref := json;
        let dt = Time_compat.now () -. t0 in
        Log.Dashboard.info "mission refreshed (%.0fB, %.1fs)"
          (Float.of_int (String.length (Yojson.Safe.to_string json)))
          dt
      with exn ->
        let dt = Time_compat.now () -. t0 in
        Log.Dashboard.warn "mission refresh failed (%.1fs): %s"
          dt (Printexc.to_string exn));
      Eio.Time.sleep clock _mission_refresh_interval_s;
      loop ()
    in
    loop ())

(* Trim a full mission JSON to a lightweight snapshot:
   summary, session_briefs (goal/elapsed/blocker only), attention_queue (top 5), counts.
   Target: <20KB vs ~483KB full. *)
let mission_snapshot_of_full (full : Yojson.Safe.t) : Yojson.Safe.t =
  let field key = Yojson.Safe.Util.member key full in
  let briefs =
    match field "session_briefs" with
    | `List items ->
        `List
          (List.map
             (fun item ->
               let f k = Yojson.Safe.Util.member k item in
               `Assoc
                 [
                   ("session_id", f "session_id");
                   ("goal", f "goal");
                   ("status", f "status");
                   ("health", f "health");
                   ("elapsed_sec", f "elapsed_sec");
                   ("blocker_summary", f "blocker_summary");
                 ])
             items)
    | other -> other
  in
  let attention_top5 =
    match field "attention_queue" with
    | `List items -> `List (List.filteri (fun i _ -> i < 5) items)
    | other -> other
  in
  `Assoc
    [
      ("generated_at", field "generated_at");
      ("summary", field "summary");
      ("session_briefs", briefs);
      ("attention_queue", attention_top5);
      ("session_count",
       `Int
         (match field "sessions" with `List l -> List.length l | _ -> 0));
      ("agent_count",
       `Int
         (match field "agent_briefs" with
         | `List l -> List.length l
         | _ -> 0));
      ("keeper_count",
       `Int
         (match field "keeper_briefs" with
         | `List l -> List.length l
         | _ -> 0));
    ]

let dashboard_mission_http_json ~state ~sw ~clock request =
  let actor = operator_actor_hint request in
  let mode = query_param request "mode" in
  let full_json =
    match actor with
    | None ->
      (* Default: return proactively cached value immediately (0ms). *)
      !_mission_json_ref
    | Some _ ->
      (* Actor-parameterized: on-demand with SWR cache. *)
      let cache_key =
        Printf.sprintf "mission:%s" (Option.value ~default:"" actor)
      in
      Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:120.0
        ~clock ~timeout_sec:30.0 (fun () ->
        Dashboard_mission.json ?actor
          ~config:state.Mcp_server.room_config ~sw ~clock
          ~proc_mgr:state.Mcp_server.proc_mgr ())
  in
  match mode with
  | Some "snapshot" -> mission_snapshot_of_full full_json
  | _ -> full_json

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
      Printf.sprintf "mission_briefing:%s" (Option.value ~default:"" actor)
    in
    Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:5.0
      ~clock ~timeout_sec:30.0 compute

let dashboard_proof_http_json ~state request =
  let session_id = query_param request "session_id" in
  let operation_id = query_param request "operation_id" in
  Dashboard_proof.json ?actor:(operator_actor_hint request) ?session_id
    ?operation_id ~config:state.Mcp_server.room_config ()

let dashboard_shell_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let current_room =
    Room.read_current_room config |> Option.value ~default:"default"
  in
  let tempo = Tempo.get_tempo config in
  let lodge_json = `Assoc [("status", `String "deprecated")] in
  let social_runtime_json = Social_runtime.status_json ~config in
  let build = Build_identity.current () in
  `Assoc
    [
      ("room", `String current_room);
      ("current_room", `String current_room);
      ("room_base_path", `String config.base_path);
      ( "cluster",
        `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME"))
      );
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", match dashboard_task_assignee task with Some v -> `String v | None -> `Null);
      ("created_at", `String task.created_at);
    ]

let dashboard_agent_json (agent : Types.agent) =
  let profile = Dashboard_execution_helpers.get_agent_profile agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", match agent.current_task with Some task -> `String task | None -> `Null);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) agent.capabilities));
      ("emoji", `String profile.emoji);
      ("koreanName", `String profile.korean_name);
      ("model", match profile.model with Some m -> `String m | None -> `Null);
      ("traits", `List (List.map (fun t -> `String t) profile.traits));
      ("interests", `List (List.map (fun i -> `String i) profile.interests));
      ("activityLevel", match profile.activity_level with Some v -> `Float v | None -> `Null);
      ("primaryValue", match profile.primary_value with Some v -> `String v | None -> `Null);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let dashboard_current_room_id config =
  Room.current_room_id config

let dashboard_tasks_safe config =
  Room.get_tasks_raw_in_room config (dashboard_current_room_id config)

let dashboard_agents_safe config =
  Room.get_agents_raw_in_room config (dashboard_current_room_id config)

let dashboard_messages_safe config ~since_seq ~limit =
  Room.get_messages_raw_in_room config ~room_id:(dashboard_current_room_id config) ~since_seq ~limit

let provider_capacity_json () : Yojson.Safe.t =
  `Assoc []

let dashboard_shell_http_json (config : Room.config) : Yojson.Safe.t =
  Dashboard_cache.get_or_compute "shell" ~ttl:2.0 (fun () ->
    let agents = dashboard_agents_safe config in
  let tasks = dashboard_tasks_safe config in
  let keepers_json = keepers_dashboard_json ~compact:true config in
  let keepers_total = json_int_field "total" keepers_json ~default:0 in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", dashboard_shell_status_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int (List.length agents));
            ("tasks", `Int (List.length tasks));
            ("keepers", `Int keepers_total);
          ] );
      ("providers", provider_capacity_json ());
      ])

